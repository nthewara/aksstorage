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
| 9 | Azure Files Standard tier throttling | all SMB Standard PVCs | Partial — latency climbs, no data loss |
| 10 | SMB session drop / network blip | one pod's mount | Yes — CIFS client auto-reconnects |
| 11 | Pod eviction during write (Azure Files) | one in-flight file | Yes (SMB) / brief lock window (NFS) |
| 12 | Azure Files quota exhaustion | the shared PVC | No — expand the PVC or free space |
| 13 | **Premium SSD v2 zonal disk failure** | one v2 PV (zone-pinned) | **No** — LRS only, no automatic cross-AZ failover |

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
POD=$(kubectl -n kube-system get pod -l app=io-engine -o name | head -1)
kubectl -n kube-system delete "$POD"
```

**Expected**: ACStor marks replica `Faulted`, elects a new replica node,
begins `Rebuilding` → `Online` cycle. I/O continues on surviving replicas.

```bash
kubectl -n kube-system get pods -l app=io-engine
kubectl -n kube-system get events --sort-by=.lastTimestamp | tail -20
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
# Scenario: migrate from ACS NVMe to built-in Azure Disk CSI
# Step 1: apply the azure-disk StorageClass (no ACS enable needed —
#         disk.csi.azure.com ships with AKS by default; ACS v2.x does
#         not manage the azureDisk type any more)
kubectl apply -f manifests/storageclass/azure-disk.yaml

# Step 2: migrate data (application-level, e.g. Cassandra nodetool repair)
# Step 3: update workload manifests to use new SC
# Step 4: once no workloads reference local-nvme, disable it
az aks update -g "$RG" -n "$CLUSTER" --disable-azure-container-storage ephemeralDisk
```

**Expected**: NVMe CSI driver removed from storagepool nodes. Any remaining
PVCs referencing `local-nvme` SC enter `Pending` state → migrate before disabling.
New PVCs using the built-in `azure-disk` SC bind normally; the built-in CSI
driver is independent of ACS lifecycle.

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

## 9. Azure Files Standard tier throttling

**Setup**: `acstor-azurefiles-standard` SC, nginx-shared workload (or any RWX workload) sized small enough that you hit the per-share IOPS cap.

Standard Azure Files is throttled at the share level: **1,000 IOPS baseline**
with burst up to 10,000 IOPS for 60 minutes/day. Premium scales IOPS with share
size (1 IOPS/GiB + 400 baseline).

```bash
# Saturate IOPS from one of the nginx-shared pods
POD=$(kubectl -n demo-files get pod -l app=nginx-shared -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n demo-files "$POD" -- sh -c '
  apk add --no-cache fio 2>/dev/null || true
  fio --name=throttle --filename=/usr/share/nginx/html/throttle.bin \
      --rw=randwrite --bs=4k --iodepth=64 --numjobs=2 \
      --size=2G --time_based --runtime=120 --output-format=normal
'
```

**Expected**:
- IOPS plateaus at the tier ceiling; latency climbs from ~5ms to 50–500ms
- Other pods sharing the volume see slower reads/writes
- `tail -f /var/log/syslog` on the node shows occasional `SMB2 server returned STATUS_PENDING`
- **No data loss** — just degraded throughput

**Recovery**: switch the workload to `acstor-azurefiles-premium`, or shard the
workload across multiple shares. Migration requires a fresh PVC + `kubectl cp`
or rsync — there is no in-place tier change for dynamically-provisioned shares.

---

## 10. SMB session drop / network blip — automount recovery

Simulate a network blip between an AKS node and the storage account:

```bash
# Pick the node hosting one of the nginx-shared pods
POD=$(kubectl -n demo-files get pod -l app=nginx-shared -o jsonpath='{.items[0].metadata.name}')
NODE=$(kubectl -n demo-files get pod "$POD" -o jsonpath='{.spec.nodeName}')
echo "Targeting $NODE (hosts $POD)"

# In one terminal, start a continuous writer
kubectl exec -n demo-files "$POD" -- sh -c '
  while true; do
    echo "$(date -u +%FT%TZ) ping" >> /usr/share/nginx/html/heartbeat.txt
    sleep 1
  done'

# In another terminal, simulate a blip via NetworkPolicy on the node's pod CIDR
kubectl apply -f chaos/netpol-deny-all.yaml
sleep 20
kubectl delete -f chaos/netpol-deny-all.yaml
```

**Expected**:
- SMB session is dropped; the kernel CIFS client retries with backoff
- The heartbeat writer stalls during the outage, then resumes — **no remount required**
- Mount options `nosharesock` and `actimeo=30` keep stale handles minimal
- `dmesg | grep -i cifs` on the node shows reconnect messages

**Recovery**: automatic. If the session does not come back within ~5 minutes,
delete the pod — kubelet will remount on pod recreate.

---

## 11. Pod eviction during write — file consistency

Kill a pod mid-write and inspect the shared file:

```bash
POD=$(kubectl -n demo-files get pod -l app=nginx-shared -o jsonpath='{.items[0].metadata.name}')

# Start a slow large write in the background
kubectl exec -n demo-files "$POD" -- sh -c '
  for i in $(seq 1 100000); do
    echo "line $i from $(hostname)" >> /usr/share/nginx/html/big.txt
  done' &
WRITER=$!

sleep 2
# Evict the pod mid-write
kubectl -n demo-files delete pod "$POD" --grace-period=0 --force
wait $WRITER 2>/dev/null || true

# Inspect the file from a surviving pod
SURVIVOR=$(kubectl -n demo-files get pod -l app=nginx-shared -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n demo-files "$SURVIVOR" -- tail -5 /usr/share/nginx/html/big.txt
kubectl exec -n demo-files "$SURVIVOR" -- wc -l /usr/share/nginx/html/big.txt
```

**Expected**:
- **SMB**: in-flight buffered writes may be lost (last few KB), but the file is
  intact — SMB does not leave durable locks on session loss
- **NFS 4.1**: file locks held by the evicted pod are released on session timeout
  (~90s by default). During that window, other pods writing to the same byte
  range may see `EAGAIN`. After timeout, full access resumes.
- **No filesystem corruption** in either case

**Recovery**: automatic. New replica spins up, mounts the share, resumes writing.

---

## 12. Azure Files quota exhaustion

```bash
POD=$(kubectl -n demo-files get pod -l app=nginx-shared -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n demo-files "$POD" -- sh -c '
  dd if=/dev/zero of=/usr/share/nginx/html/fill.bin bs=1M count=200000 status=progress
'
```

**Expected**: `dd` fails with `No space left on device` once the share quota
is hit. Other pods on the same share also start failing writes — quota is
share-wide, not per-pod.

**Recovery**: expand the PVC (Azure Files supports online expansion):

```bash
kubectl -n demo-files patch pvc nginx-shared-pvc \
  --type merge -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
kubectl -n demo-files exec "$POD" -- rm /usr/share/nginx/html/fill.bin
```

No pod restart required — the share resize is transparent to mounted clients.

---

## 13. Premium SSD v2 — zonal disk failure

**Setup**: Postgres 16 single replica on `premium-ssd-v2` SC, namespace
`demo-pgv2`. The PV lives in one Availability Zone (e.g. `australiaeast-1`)
and `WaitForFirstConsumer` pinned the pod to a node in that same zone.

> **Key constraint**: Premium SSD v2 managed disks are **LRS only** — ZRS is
> explicitly not supported for v2 (or Ultra) block disks per Microsoft Learn.
> Note: `PremiumV2_ZRS` *is* a valid SKU for Azure Files SSD shares — different
> service, don't confuse the two. For managed disks there's no ZRS
> as of 2026. The disk has 3 replicas inside a single AZ, zero across zones.
> If the AZ hosting the disk fails, the volume is unreachable until the AZ
> recovers. Pod anti-affinity across zones **does not help** — the disk
> doesn't move with the pod.

### Simulate the failure

```bash
# 1. Find the AZ the v2 disk lives in
PVC=$(kubectl -n demo-pgv2 get pvc -o jsonpath='{.items[0].metadata.name}')
PV=$(kubectl -n demo-pgv2 get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
DISK_ZONE=$(kubectl get pv "$PV" \
  -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="topology.disk.csi.azure.com/zone")].values[0]}')
echo "v2 disk pinned to zone: $DISK_ZONE"

# 2. Cordon + drain every node in that zone — simulate full AZ outage
NODES=$(kubectl get nodes \
  -l topology.kubernetes.io/zone="$DISK_ZONE" \
  -o jsonpath='{.items[*].metadata.name}')
for NODE in $NODES; do
  kubectl cordon "$NODE"
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=5m
done

kubectl -n demo-pgv2 get pods -o wide -w
```

**Expected**:
- Postgres pod evicted from the drained node
- Scheduler tries to place it on another node — but every node in other AZs
  fails the volume node-affinity check (`topology.disk.csi.azure.com/zone`)
- Pod stays **Pending** indefinitely. `kubectl describe pod` shows:
  `0/N nodes available: N node(s) had volume node affinity conflict`
- The v2 disk is fine; it's just unreachable until a node comes back in its AZ

```bash
kubectl -n demo-pgv2 describe pod postgres-v2-0 | grep -A5 'Events:'
kubectl get pv "$PV" -o yaml | grep -A10 nodeAffinity
```

### Why no automatic recovery

- **No ZRS** → no zone-redundant copies to fail over to
- **CSI driver doesn't migrate disks** → it only attaches/detaches what Azure
  gave it
- **Pod anti-affinity across zones is irrelevant** → the disk pins the pod,
  not vice versa
- **Snapshots don't fail over automatically** → you'd have to manually
  restore a snapshot into a different AZ as a new disk

### Mitigation patterns

Pick one **before** you hit this scenario:

1. **App-level replication across zones** (recommended for v2)
   - Run Postgres with Patroni or CloudNativePG
   - Each replica gets its **own** `premium-ssd-v2` PV in its **own** AZ
   - On AZ loss, the surviving replicas elect a new primary
   - Each disk stays LRS; durability comes from the app, not the storage tier

2. **Fall back to Premium SSD v1 with ZRS** (if cross-AZ HA matters more than IOPS dial)
   - `skuName: Premium_ZRS` — 3 copies across 3 zones
   - Lose the v2 independent-dial pricing model
   - Gain transparent cross-AZ failover for a single PV
   - Higher latency (~1–2 ms vs v2's ~0.5 ms)

3. **Design for zone-loss explicitly** (acceptance pattern)
   - Document the RTO/RPO for AZ failure ("v2 single-disk RTO = duration of
     AZ outage; RPO = 0 since the disk persists")
   - Take regular snapshots → can restore into a different AZ manually if the
     outage is long-lived
   - Pair with Azure Backup for off-AZ copies

### Recovery (after simulated AZ comes back)

```bash
for NODE in $NODES; do kubectl uncordon "$NODE"; done
# Scheduler immediately places postgres-v2-0 back on a node in the original AZ.
# Disk re-attaches; Postgres replays WAL; pod Ready within ~60s.
```

**Lesson**: Premium SSD v2 gives you NVMe-class latency + durability inside
a zone, but the zone is the failure domain. For a true single-disk AZ-tolerant
workload, you need Premium SSD v1 ZRS today. For v2, design HA at the app
layer.

---

## 14 — Zone failure with **Premium SSD v1 ZRS disk** (graceful failover)

Contrast scenario to §13: same single-instance Postgres, but on `premium-ssd-zrs`.
The whole point of ZRS is that this scenario *works*.

### Setup
```bash
kubectl apply -f manifests/storageclass/premium-ssd-zrs.yaml
kubectl apply -f manifests/workloads/postgres-zrs-statefulset.yaml
# wait until Ready, then seed:
kubectl -n demo-pgzrs exec postgres-zrs-0 -- pgbench -i -s 50 -U demo demo
```

### Hypothesis
- PVC stays Bound during AZ outage — ZRS keeps 2/3 replicas alive in surviving AZs
- Pod reschedules to a node in a different AZ
- Disk re-attaches to the new node, Postgres replays WAL, comes back Ready
- **Zero data loss, RTO = pod reschedule + WAL replay (~60–90 s)**

### Execute
```bash
# 1. Identify pod's current zone
ZONE=$(kubectl -n demo-pgzrs get pod postgres-zrs-0 -o jsonpath='{.spec.nodeName}' \
  | xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
echo "Cordoning zone $ZONE"

# 2. Cordon every node in that zone
kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o name | xargs -I{} kubectl cordon {}

# 3. Evict the pod (simulates node loss)
kubectl -n demo-pgzrs delete pod postgres-zrs-0

# 4. Watch it come back in a different zone
kubectl -n demo-pgzrs get pod -o wide -w
```

### Verify data integrity
```bash
kubectl -n demo-pgzrs exec postgres-zrs-0 -- psql -U demo -c \
  "SELECT count(*) FROM pgbench_accounts"
# expect 5000000 — same as before the "AZ failure"
```

### Recovery (un-simulate AZ outage)
```bash
kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o name | xargs -I{} kubectl uncordon {}
```

### Comparison with §13 (v2 zonal failure)
| | v2 LRS (§13) | v1 ZRS (§14) |
|---|---|---|
| Pod state after AZ loss | Pending forever | Reschedules in ~30 s |
| PVC | Bound but inaccessible | Bound, reattaches |
| Data loss | None (disk persists) | None |
| Recovery action | Wait for AZ / restore from snapshot | Automatic |
| RTO | = AZ outage duration | ~60–90 s |

**Lesson**: ZRS pays for itself when the workload can't replicate at the app
layer. For Cassandra/Kafka the math flips — use NVMe LRS + app RF=3 instead.


---

## Observation cheatsheet

```bash
# ACStor health
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl -n kube-system logs -l app=io-engine --tail=200
kubectl -n kube-system get pods -l 'app in (io-engine,acstor-node-agent,acstor-cluster-manager)' -o wide

# Cassandra
kubectl -n cassandra exec cassandra-0 -- nodetool status
kubectl -n cassandra exec cassandra-0 -- nodetool ring
kubectl -n cassandra exec cassandra-0 -- nodetool describecluster

# Log Analytics query
az monitor log-analytics query -w <law-id> --analytics-query \
  'KubeEvents | where Namespace in ("kube-system","cassandra") and ObjectName contains "acstor" | order by TimeGenerated desc | take 50'
```
