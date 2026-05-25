# Premium SSD v1 ZRS — Zone-Redundant Block Storage

Premium SSD v1 with **zone-redundant storage (ZRS)** is the answer when you
need a single-instance stateful workload (single-replica DB, file server)
to **survive a full AZ failure** without designing app-level replication.

This sits in a sweet spot the lab's other options don't cover:

| Need | Best fit |
|---|---|
| Sub-ms latency, app does replication | Local NVMe + ACS |
| Sub-ms latency, single instance, AZ-pinned OK | Premium SSD v2 (LRS) |
| **Cross-zone HA, single instance, ~ms latency OK** | **Premium SSD v1 ZRS** ← this doc |
| Many small PVs, shared SAN | Elastic SAN |
| RWX shared filesystem | Azure Files |

---

## How ZRS works for managed disks

A `Premium_ZRS` managed disk synchronously replicates writes to **3 copies
across 3 availability zones** within a region. Behind the scenes Azure's
storage fabric handles the multi-zone write quorum — your VM/pod just sees
a single block device with the same semantics as LRS.

What this buys you:
- **Disk durability survives a zone outage** — the data is in the other 2 AZs
- **Pod can re-attach the disk after rescheduling to a different zone**
- **`accessModes: ReadWriteOnce` still applies** — only one pod at a time,
  but that pod can be anywhere in the region
- **Shared disks (RWX block) supported** — for active/passive clustering
  with SCSI persistent reservations (not used in this lab but worth knowing)

What it costs you:
- **Higher write latency** — synchronous cross-zone replication adds ~ms
- **IOPS/throughput coupled to disk size** (P10 = 128 GiB / 500 IOPS,
  P30 = 1 TiB / 5000 IOPS, P50 = 4 TiB / 7500 IOPS) — no v2-style independent dial
- **~10–15% price premium** over Premium_LRS at same SKU
- **`volumeBindingMode: WaitForFirstConsumer` still required** — disk
  metadata records a primary zone even though data is in 3 zones

---

## When to pick this over Premium SSD v2

Pick `premium-ssd-zrs` over `premium-ssd-v2` when:
- **AZ failure must not take the workload offline** AND you don't have
  app-level cross-zone replication
- Latency tolerance is ~ms (not microseconds)
- IOPS need is moderate (≤ 7500 IOPS — the P50 ceiling)
- You're running a single-instance DB and don't want to operate a
  HA pair (Patroni, CNPG, etc.)

Pick `premium-ssd-v2` over `premium-ssd-zrs` when:
- IOPS requirement is high (10k+) and you want to dial it independently of size
- Latency budget is sub-ms (v2 is faster than v1 even before ZRS overhead)
- Your app does its own cross-zone replication (Cassandra, CNPG with
  multi-AZ replicas)
- You're OK with the AZ-pinning gotcha

---

## When to pick this over Local NVMe + ACS

Pick `premium-ssd-zrs` over ACS NVMe when:
- App does **not** replicate itself (Postgres single, MySQL single, simple Redis)
- You want zero ops burden for failure tolerance
- Latency is not the bottleneck

Pick ACS NVMe when:
- App does its own replication (Cassandra, Kafka, ScyllaDB, etc.)
- Latency matters
- Cost per IOPS at scale matters (Lsv3 NVMe is essentially free with the VM)

---

## Cost shape (australiaeast, list price, May 2026)

| Disk | Size | IOPS | Throughput | $/month |
|---|---|---|---|---|
| Premium_LRS P10 | 128 GiB | 500 | 100 MB/s | ~$20 |
| Premium_ZRS P10 | 128 GiB | 500 | 100 MB/s | ~$23 |
| Premium_LRS P30 | 1 TiB | 5,000 | 200 MB/s | ~$135 |
| Premium_ZRS P30 | 1 TiB | 5,000 | 200 MB/s | ~$170 |
| PremiumV2_LRS | 128 GiB @ 5000 IOPS | 5,000 | 125 MB/s | ~$30 |
| PremiumV2_LRS | 1 TiB @ 5000 IOPS | 5,000 | 200 MB/s | ~$95 |

**Insight:** at large sizes (≥1 TiB) Premium SSD v2 LRS is *cheaper* than v1
ZRS at the same IOPS — but you lose cross-zone redundancy. ZRS is the price
of HA-without-app-replication.

---

## Walkthrough

### 1. Apply the StorageClass
```bash
kubectl apply -f manifests/storageclass/premium-ssd-zrs.yaml
kubectl get sc premium-ssd-zrs
```

### 2. Deploy the demo Postgres
```bash
kubectl apply -f manifests/workloads/postgres-zrs-statefulset.yaml
kubectl -n demo-pgzrs get pod,pvc -o wide
```

Wait for `postgres-zrs-0` to be `Ready 1/1`. Note the zone in the `NODE`
column — that's the **primary zone** for the disk.

### 3. Confirm the PV is ZRS
```bash
PV=$(kubectl -n demo-pgzrs get pvc data-postgres-zrs-0 -o jsonpath='{.spec.volumeName}')
DISK=$(kubectl get pv $PV -o jsonpath='{.spec.csi.volumeHandle}')
az disk show --ids $DISK --query '{sku:sku.name, location:location, zones:zones}' -o json
```
Should show `"sku": "Premium_ZRS"` and `zones` empty (ZRS disks are
region-scoped, not pinned to a single zone like LRS).

### 4. Seed data
```bash
kubectl -n demo-pgzrs exec postgres-zrs-0 -- pgbench -i -s 50 -U demo demo
kubectl -n demo-pgzrs exec postgres-zrs-0 -- psql -U demo -c "SELECT count(*) FROM pgbench_accounts"
# expect 5000000
```

### 5. AZ failover drill
Simulate losing the pod's zone:
```bash
ZONE=$(kubectl -n demo-pgzrs get pod postgres-zrs-0 -o jsonpath='{.spec.nodeName}' \
  | xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
echo "pod is in zone $ZONE — cordoning all nodes there"

kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o name | xargs -I{} kubectl cordon {}
kubectl -n demo-pgzrs delete pod postgres-zrs-0
```
Watch:
```bash
kubectl -n demo-pgzrs get pod -o wide -w
```
The pod will come up on a node in a different zone, the PVC stays Bound,
the disk gets reattached, and your row count survives:
```bash
kubectl -n demo-pgzrs exec postgres-zrs-0 -- psql -U demo -c "SELECT count(*) FROM pgbench_accounts"
```

Uncordon the original zone when done:
```bash
kubectl get nodes -l topology.kubernetes.io/zone=$ZONE -o name | xargs -I{} kubectl uncordon {}
```

> 💡 **What you just proved:** the disk survived "losing a zone" because the
> ZRS fabric still has 2/3 replicas alive in the surviving zones. With LRS
> this would have stranded the pod indefinitely.

---

## Limitations & gotchas

1. **Not all regions support ZRS for managed disks** — `australiaeast` does.
   Check with `az vm list-skus --location <region> --resource-type disks --query "[?name=='Premium_ZRS']"`.
2. **`volumeBindingMode: WaitForFirstConsumer` is still required** — the
   disk records a primary zone for the topology hint.
3. **`accessModes` is still ReadWriteOnce by default** — ZRS doesn't make a
   disk multi-attach. For RWX use Azure Files.
4. **No geo-replication** — ZRS is intra-region only. For cross-region DR
   you still need Azure Backup, ASR, or app-level replication.
5. **Higher write latency** than LRS — fine for most OLTP, may matter for
   write-heavy benchmark numbers (~10–15% slower writes is typical).

---

## Failure scenarios covered

See [`FAILURE-SCENARIOS.md`](FAILURE-SCENARIOS.md):
- §14 — **Zone failure with ZRS disk** (this scenario — graceful failover)
- §13 — Compare with Premium SSD v2 zonal failure (no failover, stuck Pending)
