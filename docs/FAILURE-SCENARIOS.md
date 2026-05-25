# Failure Scenarios — Azure Container Storage

A grab-bag of "break it on purpose" exercises. Each scenario lists the setup,
the action, what you *expect* to happen, how to observe it, and the recovery.

Run **`./tests/validate.sh`** between scenarios — it's the quickest way to
spot drift.

---

## Summary table

| # | Scenario                          | Blast radius           | Recovery is automatic? |
|---|-----------------------------------|------------------------|------------------------|
| 1 | Node drain                        | one stateful pod       | yes (reschedule + reattach) |
| 2 | Disk pressure / pool exhaustion   | one PVC / pool         | no (need to free space) |
| 3 | Replica loss (replicated pool)    | one replica            | yes (resync) |
| 4 | Pod kill loop                     | one pod                | yes |
| 5 | Node pool scale-down with PV      | volumes on that node   | partial — PV stays, pod reschedules |
| 6 | Network partition between nodes   | pool quorum            | partial — degraded mode |
| 7 | Storage pool deletion mid-IO      | all PVCs on that pool  | manual restore |
| 8 | Cluster upgrade with ACStor       | brief disruption       | yes |

---

## 1. Node drain / node failure

**Setup**: Postgres running on `postgres-0`, PVC `pg-data` attached.

```bash
NODE=$(kubectl -n acstor-demo get pod postgres-0 -o jsonpath='{.spec.nodeName}')
echo "Postgres is on $NODE"

kubectl cordon  "$NODE"
kubectl drain   "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=5m
```

**Expected**:

- Pod evicted; rescheduled onto another node.
- Azure-disk-backed PV unmounted from old node, attached on new node.
- ACStor takes ~30–90s to reattach.
- After `uncordon`, original node returns; PV does **not** migrate back.

**Observe**:

```bash
kubectl -n acstor-demo describe pod postgres-0 | tail -30
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl -n acstor get pods -o wide
```

**Recovery**: `kubectl uncordon "$NODE"`.

---

## 2. Disk pressure / pool exhaustion

```bash
kubectl apply -f chaos/disk-pressure-pod.yaml
kubectl -n acstor-demo logs -f disk-filler
```

**Expected**: writes succeed up to PVC size, then `No space left on device`.
Postgres sees write failures on its own PVC if you target it. ACStor itself
remains healthy (other PVCs unaffected — pool has spare capacity).

If you instead grow a single PVC past the **pool** capacity, new PVC
provisioning fails with `ProvisioningFailed`.

**Recovery**:

```bash
kubectl -n acstor-demo delete pod disk-filler
kubectl -n acstor-demo exec postgres-0 -- sh -c 'rm -f /var/lib/postgresql/data/pgdata/fill.bin || true'
```

To expand the PVC: edit `spec.resources.requests.storage`, AKS CSI online-expands the disk.

---

## 3. Replica loss (replicated pool)

Only applies if you created a pool with `replicas > 1` (ephemeral-NVMe pool
recommends 3-way replication).

```bash
POD=$(kubectl -n acstor get pod -l app=io-engine -o name | head -1)
kubectl -n acstor delete "$POD"
```

**Expected**: ACStor marks the replica `Faulted`, picks a new node, kicks off
a `Rebuilding` → `Online` cycle. I/O continues uninterrupted on the surviving
replicas.

**Observe**:

```bash
kubectl -n acstor get replicas
kubectl -n acstor get events --sort-by=.lastTimestamp | tail -20
```

---

## 4. Pod kill / restart loop

```bash
for i in 1 2 3 4 5; do
  kubectl -n acstor-demo delete pod postgres-0 --grace-period=0 --force
  sleep 10
done
```

**Expected**: StatefulSet recreates pod each time. PVC stays bound, data survives.
`SELECT count(*) FROM t;` returns the same value across restarts.

---

## 5. Node pool scale-down with attached PV

```bash
az aks nodepool scale -g "$RG" --cluster-name "$CLUSTER" -n syspool --node-count 2
```

**Expected**: if scale-down picks the node hosting `postgres-0`, AKS drains
it first. Same flow as #1. If autoscaler picks a different node, no impact.
Azure-disk-backed PV persists regardless — only the attachment moves.

**Gotcha**: NVMe-backed ephemeral pools **lose** the data on the removed node.
Replication saves you; without it, the volume is gone.

---

## 6. Network partition between nodes

```bash
kubectl apply -f chaos/netpol-deny-all.yaml
```

**Expected**: workload pods can't reach each other; if you're running a
3-replica pool, the partition splits the cluster's view of replicas.
ACStor enters degraded mode but does not split-brain (Mayastor-style quorum).

**Recovery**:

```bash
kubectl -n acstor-demo delete netpol deny-all
```

---

## 7. Storage pool deletion mid-IO

```bash
kubectl -n acstor delete storagepool azuredisk-pool
```

**Expected**: pool deletion is blocked while PVCs reference it (finalizer).
If you force-delete by removing the finalizer, PVCs go `Lost`, pods crash on
mount. Recovery requires deleting PVCs and restoring from backup
(Velero / azure-disk snapshot).

**Lesson**: never `--grace-period=0 --force` a storage pool that has PVCs.

---

## 8. Cluster upgrade with ACStor + active workload

```bash
az aks get-upgrades -g "$RG" -n "$CLUSTER" -o table
az aks upgrade     -g "$RG" -n "$CLUSTER" --kubernetes-version <next>
```

**Preflight**:

- `kubectl -n acstor get pods` → all Running
- workload pod-disruption-budget allows ≥1 unavailable
- backup recent (Velero)

**During**: nodes go through cordon/drain one at a time; same flow as #1 per node.

**Post-check**:

```bash
./tests/validate.sh
kubectl -n acstor get pods -o wide
kubectl -n acstor get storagepool
```

---

## Observation cheatsheet

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl -n acstor logs -l app=io-engine --tail=200
az monitor log-analytics query -w <law-id> --analytics-query \
  'KubeEvents | where Namespace == "acstor" | order by TimeGenerated desc | take 50'
```
