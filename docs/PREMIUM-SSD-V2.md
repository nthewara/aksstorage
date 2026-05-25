# Premium SSD v2 — single-instance DBs with sub-ms latency

> **TL;DR**: Premium SSD v2 is the modern high-end Azure managed disk SKU.
> Same `disk.csi.azure.com` driver as Premium SSD v1, but **IOPS, throughput,
> and capacity scale independently** — no more "go bigger just to get more
> IOPS." Best fit: single-instance Postgres/MySQL/SQL Server where the disk
> SKU provides durability and you want sub-ms latency without the node-pool
> tax of local NVMe.
>
> Managed by the **AKS built-in CSI driver**, not ACS.

---

## 1. What it is + why it exists

Premium SSD v2 (`PremiumV2_LRS`) is a managed disk SKU released in 2023 GA.
The big differentiator vs Premium SSD v1 (the `P*` tiers):

| | Premium SSD v1 | **Premium SSD v2** |
|---|---|---|
| IOPS dial | tied to disk size (P30 = 5k IOPS @ 1 TiB) | **independent** — 3k–80k IOPS at any size ≥1 GiB |
| Throughput dial | tied to disk size | **independent** — 125–1200 MB/s |
| Capacity granularity | fixed tiers (P10/P20/P30…) | **1 GiB increments** |
| Provisioning model | size-driven | per-dial pricing |
| ZRS support | ✅ yes | ❌ not yet (LRS only as of 2026) |
| Latency | ~1 ms | **sub-ms** (typ. 0.5 ms read) |
| Caching | Read/None/ReadWrite | **None only** |

Translation: with v1 you'd buy a 4 TiB P50 disk just to get 7,500 IOPS even
if you only needed 200 GiB. With v2 you provision 200 GiB + 10k IOPS + 250
MB/s and pay only for what you dial in.

It's still backed by the same `disk.csi.azure.com` driver — no new CRDs, no
new extension to install. It just shows up when you point a StorageClass at
`skuName: PremiumV2_LRS`.

**This is built-in AKS CSI, not ACS.** ACS v2.1 manages NVMe and Elastic SAN.
Disk-backed PVs (v1 or v2) live on the built-in driver that ships with every
AKS cluster.

---

## 2. When to pick Premium SSD v2

- **Single-instance Postgres / MySQL / SQL Server** that needs durable block storage
- **Sub-ms latency** without the operational cost of running on Lsv3 + ACS
- **Workloads where IOPS demand is high but capacity demand is moderate** —
  the v1 "buy 4 TiB to get IOPS" anti-pattern goes away
- **Disk snapshots / Azure Backup integration** required
- **Workload should survive node loss** by re-attaching to a new node in the
  same AZ
- Apps that already replicate at app level (Patroni, CNPG) but want each
  replica's local disk to be very fast + durable

---

## 3. When NOT to pick

- **Sub-100µs latency** required (HFT, in-memory caches, Cassandra hot path)
  → use **local NVMe** on Lsv3 + ACS
- **Multi-region DR with ZRS** required → Premium SSD v2 is **LRS-only**
  today (no ZRS as of 2026). Use Premium SSD v1 ZRS, or app-level replication
  across regions
- **Hundreds of small PVs per cluster** → you'll hit VM disk-attach limits
  (64 per D8s_v5, less on smaller VMs). Use **Elastic SAN** instead
- **RWX / shared filesystem** → use **Azure Files**
- **Cluster-wide HA across zone outages** for a single PV → not possible with
  LRS v2; design for the zone-loss case (see §8)

---

## 4. The zone constraint (important!)

`PremiumV2_LRS` is **zone-pinned**. The disk physically lives in one
Availability Zone and the pod must schedule on a node in that same zone, or
the volume can't attach.

This is why the StorageClass uses **`volumeBindingMode: WaitForFirstConsumer`**
(mandatory — don't change it). Bind sequence:

1. Pod requests a PVC
2. Scheduler picks a node for the pod
3. CSI driver provisions the v2 disk in **that node's AZ**
4. Disk attaches; pod starts

If the StorageClass were `Immediate`, the disk would be created in a random
zone and the scheduler might pick a node in a different zone → attach fails,
pod stuck Pending forever.

**Failover behavior** — if the AZ hosting the disk goes down:
- LRS = no replicas in other zones
- Disk is unreachable until the AZ recovers
- Pod stays Pending. No automatic cross-zone failover.

See `FAILURE-SCENARIOS.md` §13 for the mitigation pattern (app-level
replication across separate v2 disks per zone).

---

## 5. Deploy walkthrough

```bash
# 1. Apply the StorageClass
kubectl apply -f manifests/storageclass/premium-ssd-v2.yaml

# 2. Deploy Postgres 16 + 100 GiB v2 PVC + scale-100 pgbench seed
kubectl apply -f manifests/workloads/postgres-v2-statefulset.yaml

# 3. Watch it come up
kubectl -n demo-pgv2 get pods,pvc -w
# Wait for postgres-v2-0 → Running (init container will seed pgbench data)

# 4. Verify PVC bound + zone-pinned
kubectl -n demo-pgv2 describe pvc pg-data-postgres-v2-0 | grep -E '(Status|VolumeName)'
kubectl get pv $(kubectl -n demo-pgv2 get pvc pg-data-postgres-v2-0 -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.nodeAffinity}' | jq

# 5. Smoke test
kubectl -n demo-pgv2 exec postgres-v2-0 -- psql -U demo -d demo -c "SELECT count(*) FROM pgbench_accounts;"
# Expect: 10,000,000 rows (scale=100)

# 6. Drive load with pgbench (~3 min, prints TPS every 10s)
kubectl apply -f tests/pgbench.yaml
kubectl -n demo-pgv2 logs -f job/pgbench
```

---

## 6. Expected results

Tuning: 100 GiB disk, **10,000 IOPS** + **200 MB/s** provisioned, D4s_v5
syspool node (4 vCPU, 16 GiB RAM).

| Metric | Expected |
|---|---|
| Disk avg read latency | 0.4–0.7 ms |
| Disk avg write latency | 0.4–0.8 ms |
| pgbench TPS (read/write, scale=100, 16 clients) | 4,000–6,500 TPS |
| pgbench TPS (read-only, `-S`) | 35,000–60,000 TPS |
| pgbench p95 latency | 3–6 ms |
| IOPS at saturation | ~10,000 (the dial cap) |

Numbers vary with node CPU and Postgres config (`shared_buffers`,
`effective_cache_size`). The disk itself rarely is the bottleneck at 10k IOPS
— Postgres on a 4-vCPU node usually saturates CPU first.

To prove the disk dial works, run `fio` directly against the PV with
`--direct=1 --iodepth=64` — you'll see ~10k IOPS hit the cap exactly.

---

## 7. Cost worked example (australiaeast, list price, monthly)

100 GiB at 10,000 IOPS / 200 MB/s on Premium SSD v2:

```
Capacity:    100 GiB × $0.097/GiB/mo            = $9.70
IOPS:        (10,000 - 3,000 free) × $0.0072    = $50.40
Throughput:  (200 - 125 free) × $0.084          = $6.30
─────────────────────────────────────────────────────
Premium SSD v2 total                           ≈ $66.40/mo
```

Comparable Premium SSD v1 to get the same 5k IOPS minimum:

```
P30 (1 TiB, 5,000 IOPS, 200 MB/s)               = $135.17/mo
  ← forced to buy 1 TiB just to get 5,000 IOPS
  ← still only HALF the IOPS of the v2 dial
```

To match v2's 10,000 IOPS on v1 you'd need a **P40 (2 TiB, 7,500 IOPS)** at
~$270/mo — still less IOPS, 20× more capacity, 4× the cost.

**Verdict**: v2 wins by ~50% on cost and ~30% on latency for the same
IOPS budget, *as long as* you don't need ZRS.

---

## 8. Failure scenarios

See `FAILURE-SCENARIOS.md`:
- §13 — **Zonal disk failure** (the big one — LRS, no ZRS, no automatic
  cross-zone failover)
- §3 (analogue) — pool exhaustion → IOPS throttle when you exceed the dial
- Pod kill loop — single replica, but disk survives, STS recreates pod and
  re-attaches the same v2 disk

---

## Reference

- [Premium SSD v2 announcement](https://learn.microsoft.com/azure/virtual-machines/disks-types#premium-ssd-v2)
- [AKS Azure Disk CSI driver](https://learn.microsoft.com/azure/aks/azure-disk-csi)
- `STORAGE-ARCHITECTURE.md` — mental model + decision matrix
- `SCENARIOS.md` — full storage picker
