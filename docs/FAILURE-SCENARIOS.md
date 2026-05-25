# Failure Scenarios — Azure Container Storage v2.1

Break-things-on-purpose exercises for the Cassandra on NVMe primary path.
Run **`./tests/validate.sh`** between scenarios to spot drift.

> **Key insight for NVMe + Cassandra**: local NVMe data is ephemeral per node.
> When a node is lost, the data on its NVMe is gone — but Cassandra's RF=3
> replication across zones means the other two replicas hold all the data.
> The Cassandra peer bootstraps the replacement node. This is the intended design.

---

## Summary

| # | Scenario | Blast radius | Automatic recovery? |
|---|---|---|---|
| 1 | Single node failure (Cassandra + NVMe) | 1/3 replicas | Yes — Cassandra bootstraps from peers |
| 2 | Zonal failure (drain all nodes in one AZ) | 1/3 of storagepool | Partial — RF=3 survives with 2 zones |
| 3 | NVMe pool exhaustion | one Cassandra pod | No — free space or expand |
| 4 | Pod kill loop | one Cassandra pod | Yes — StatefulSet restarts |
| 5 | Volume replication failure (NVMe replicated volumes) | single volume | Yes — resync from replicas |
| 6 | ESAN SAN throughput throttling | all ESAN PVCs | Partial — degraded, not down |
| 7 | Switching storage type post-install | all workloads using old SC | Manually migrate workloads |
| 8 | Network partition between nodes | Cassandra quorum | Partial — degraded with 2/3 zones |

---

## 1. Single node failure — Cassandra on NVMe

**Setup**: Cassandra running with RF=3 across 3 `storagepool` nodes (one per AZ).

```bash
NODE=$(kubectl -n cassandra get pod cassandra-0 -o jsonpath='{.spec.nodeName}')
echo "cassandra-0 is on $NODE"

# Simulate node failure by cordoning + draining
kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=5m
```

**Expected**:
- `cassandra-0` evicted; NVMe data on that node is **lost** (ephemeral)
- Cassandra peers (cassandra-1, cassandra-2) hold all data (RF=3)
- After pod reschedules on a new node, Cassandra streams data from peers (~minutes)
- `nodetool status` shows the rejoining node as `UJ` (joining) → `UN` (normal)

```bash
kubectl -n cassandra exec cassandra-1 -- nodetool status
kubectl -n cassandra get pods -o wide -w
```

**Recovery**:

```bash
kubectl uncordon "$NODE"
# Node rejoins pool; Cassandra redistributes tokens automatically.
```

**Lesson**: NVMe data doesn't survive node loss. RF=3 is mandatory. Single-replica
NVMe volumes → data loss on node failure. ACStor docs confirm: "let Cassandra handle
replication, use single-replica NVMe volumes."

---

## 2. Zonal failure — drain all nodes in one AZ

```bash
ZONE=1   # or whichever zone you want to take down

# List storagepool nodes in the target zone
NODES=$(kubectl get nodes -l kubernetes.azure.com/agentpool=storagepool \
  -o jsonpath='{range .items[?(@.metadata.labels.topology\.kubernetes\.io/zone=="australiaeast-'$ZONE'")]}{.metadata.name}{"\n"}{end}')

echo "Draining zone $ZONE nodes: $NODES"
for NODE in $NODES; do
  kubectl cordon "$NODE"
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=5m
done
```

**Expected**:
- Cassandra runs in degraded mode (2/3 zones)
- With RF=3 + NetworkTopologyStrategy, reads/writes still succeed at `LOCAL_QUORUM`
- `nodetool status` shows zone-1 node as `DN` (down) after drain

```bash
kubectl -n cassandra exec cassandra-1 -- nodetool status
# Try a CQL write — should succeed with 2 AZs up
kubectl -n cassandra exec cassandra-1 -- cqlsh -e "INSERT INTO lab.t (id,v) VALUES (uuid(),'zonal-test');"
```

**Recovery**:

```bash
for NODE in $NODES; do kubectl uncordon "$NODE"; done
# Cassandra rebalances automatically.
```

---

## 3. NVMe pool exhaustion

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nvme-filler
  namespace: cassandra
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.azure.com/agentpool: storagepool
  tolerations:
    - key: storage
      operator: Equal
      value: nvme
      effect: NoSchedule
  containers:
    - name: fill
      image: mcr.microsoft.com/cbl-mariner/busybox:2.0
      command: [/bin/sh, -c, "dd if=/dev/zero of=/data/fill.bin bs=1M count=60000 status=progress; sleep 600"]
      volumeMounts:
        - name: d
          mountPath: /data
  volumes:
    - name: d
      persistentVolumeClaim:
        claimName: pvc-smoke-nvme
EOF

kubectl -n cassandra logs -f nvme-filler
```

**Expected**: writes succeed until PVC fills → `No space left on device`.
Other Cassandra PVCs on other nodes are unaffected.

**Recovery**:

```bash
kubectl -n cassandra delete pod nvme-filler
# If Cassandra pod is affected, delete the pod to let it restart with clean state
# (NVMe is ephemeral — restart bootstraps from peers)
```

---

## 4. Pod kill loop — Cassandra restart resilience

```bash
for i in 1 2 3 4 5; do
  kubectl -n cassandra delete pod cassandra-0 --grace-period=0 --force
  sleep 15
done
```

**Expected**:
- StatefulSet recreates pod each time
- On each restart, Cassandra replays the commit log from NVMe storage (data survives pod restarts on the same node)
- `nodetool status` returns to UN within ~60s per restart

---

## 5. Volume replication failure (NVMe replicated volumes)

Only applies if you created a StoragePool with `replicas: 3` (e.g. legacy v1 StoragePool CRD).
For v2.1 with `local-nvme` SC, volumes are single-replica by design.
If using replicated NVMe volumes:

```bash
# Kill an io-engine pod (simulates replica loss)
POD=$(kubectl -n acstor get pod -l app=io-engine -o name | head -1)
kubectl -n acstor delete "$POD"
```

**Expected**: ACStor marks replica `Faulted`, elects a new replica node,
begins `Rebuilding` → `Online` cycle. I/O continues on surviving replicas.

```bash
kubectl -n acstor get pods -l app=io-engine
kubectl -n acstor get events --sort-by=.lastTimestamp | tail -20
```

**Recommendation**: Use single-replica NVMe volumes + Cassandra RF=3. ACStor replicated
volumes add write amplification without additional benefit when the app already replicates.

---

## 6. ESAN SAN throughput throttling (Elastic SAN scenario)

**Prerequisites**: ESAN deployed and enabled (see `docs/ELASTIC-SAN.md`).

Saturate ESAN IOPS to observe PV latency degradation:

```bash
# Run fio against an ESAN PVC
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: fio-esan-saturate
  namespace: acstor-demo
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: fio
          image: ljishen/fio
          command: [fio]
          args:
            - --name=saturate
            - --filename=/data/test.bin
            - --rw=randwrite
            - --bs=4k
            - --iodepth=128
            - --numjobs=4
            - --size=10G
            - --time_based
            - --runtime=120
            - --output-format=json
          volumeMounts:
            - name: d
              mountPath: /data
      volumes:
        - name: d
          persistentVolumeClaim:
            claimName: esan-pvc-1   # must exist from ELASTIC-SAN.md §4
EOF

kubectl -n acstor-demo logs -f job/fio-esan-saturate
```

**Expected**:
- IOPS saturates the SAN's provisioned limit (5,000 IOPS for 1 TiB ESAN)
- Other ESAN volumes on the same SAN see increased latency (shared capacity)
- Latency climbs from ~1ms to 5–20ms under saturation

**Lesson**: ESAN IOPS and throughput are shared across all volumes in the SAN.
Size base TiB according to aggregate IOPS demand, not individual volume size.

---

## 7. Switching storage type post-install

v2.1 supports additive enable/disable without cluster downtime:

```bash
# Scenario: migrate from NVMe to AzureDisk
# Step 1: enable azureDisk (additive — does not remove NVMe)
az aks update -g "$RG" -n "$CLUSTER" --enable-azure-container-storage azureDisk

# Step 2: create new PVCs using azure-disk StorageClass
kubectl apply -f manifests/storageclass/azure-disk.yaml

# Step 3: migrate data (application-level, e.g. Cassandra nodetool repair)
# Step 4: update workload manifests to use new SC
# Step 5: once no workloads reference local-nvme, disable it
az aks update -g "$RG" -n "$CLUSTER" --disable-azure-container-storage ephemeralDisk
```

**Expected**: NVMe CSI driver removed from storagepool nodes. Any remaining
PVCs referencing `local-nvme` SC enter `Pending` state → migrate before disabling.

---

## 8. Network partition between storagepool nodes

```bash
kubectl apply -f chaos/netpol-deny-all.yaml
```

**Expected**: Cassandra peers can't gossip → one node (the isolated one) detects
it can't reach others and marks itself as down. The partition splits quorum.
With RF=3 and 3 zones, a single-node partition still allows 2/3 quorum.

```bash
kubectl -n cassandra exec cassandra-1 -- nodetool status
```

**Recovery**:

```bash
kubectl -n cassandra delete netpol deny-all
# Gossip reconnects; Cassandra repairs state automatically within ~30s.
```

---

## Observation cheatsheet

```bash
# ACStor health
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl -n acstor logs -l app=io-engine --tail=200
kubectl -n acstor get pods -o wide

# Cassandra
kubectl -n cassandra exec cassandra-0 -- nodetool status
kubectl -n cassandra exec cassandra-0 -- nodetool ring
kubectl -n cassandra exec cassandra-0 -- nodetool describecluster

# Log Analytics query
az monitor log-analytics query -w <law-id> --analytics-query \
  'KubeEvents | where Namespace in ("acstor","cassandra") | order by TimeGenerated desc | take 50'
```
