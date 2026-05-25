# Storage Type Matrix — NVMe vs Elastic SAN vs Azure Disk vs Azure Files

Use this table to **pick** the right backing storage for your workload.
For the *why* behind the picks (ephemeral vs persistent, who owns
replication, how the CSI drivers compare), see
[`STORAGE-ARCHITECTURE.md`](STORAGE-ARCHITECTURE.md).

> **Important — what ACS v2.x actually manages**
>
> Azure Container Storage **v2.1** only manages two storage types:
> **`ephemeralDisk`** (local NVMe) and **`elasticSan`**. The `azureDisk` ACS
> storage type that existed in v1.x was **removed in v2.0** — see the
> [ACS release notes](https://learn.microsoft.com/en-us/azure/storage/container-storage/container-storage-release-notes).
> For disk-backed PVs in v2.x, the recommended path is the **AKS built-in
> Azure Disk CSI driver** (`disk.csi.azure.com`), not ACS.
>
> Two groups in this lab:
>
> - **ACS-managed (v2.1)** — Local NVMe (`ephemeralDisk`), Elastic SAN (`elasticSan`)
> - **AKS built-in CSI (not ACS-managed)** — Azure Disk v1 (`disk.csi.azure.com`),
>   Azure Disk **Premium SSD v2** (`disk.csi.azure.com`, same driver, modern SKU),
>   Azure Files (`file.csi.azure.com`)
>
> Both groups are valid and used side-by-side in this repo. The matrix below
> mixes them — the **Managed by** row makes it clear which is which.

| Attribute              | **Local NVMe** (`local-nvme`) | **Elastic SAN** (`azuresan-csi`) | **Azure Disk v1** (`azure-disk`) | **Premium SSD v1 ZRS** (`premium-ssd-zrs`) | **Premium SSD v2** (`premium-ssd-v2`) | **Azure Files** (`acstor-azurefiles-*`) |
|------------------------|-------------------------------|----------------------------------|-------------------------------|--------------------------------------------|----------------------------------------|------------------------------------------|
| **Managed by**         | ACS v2.1 (`ephemeralDisk`)    | ACS v2.1 (`elasticSan`)          | AKS built-in CSI              | AKS built-in CSI (same driver, ZRS SKU)    | AKS built-in CSI (same driver, modern SKU) | AKS built-in CSI                    |
| **Provisioner**        | `localdisk.csi.acstor.io`     | `san.csi.azure.com`              | `disk.csi.azure.com`          | `disk.csi.azure.com`                       | `disk.csi.azure.com`                   | `file.csi.azure.com`                     |
| **Backing resource**   | NVMe on Lsv3 node             | Azure Elastic SAN (iSCSI)        | Azure Managed Disk (Premium SSD v1 LRS) | Azure Managed Disk (Premium SSD v1 `Premium_ZRS`) | Azure Managed Disk (Premium SSD v2, `PremiumV2_LRS`) | Azure Files share (SMB or NFS 4.1) |
| **Typical read IOPS**  | 400k+ (direct NVMe)           | 5k–1M+ (scales with SAN TiB)     | ~20k (P30 disk)               | ~5k (P30, coupled to size)                 | **3k–80k (independent dial)**          | 400–100k (scales with share size, tier)  |
| **Typical latency**    | sub-100µs                     | ~1ms                             | ~1ms                          | ~1–2ms (cross-zone sync write tax)         | **sub-ms (~0.5ms)**                    | 1–3ms Premium / 5–10ms Standard          |
| **Throughput**         | 3+ GB/s (per node)            | 200 MB/s–40 GB/s (SAN-wide)      | ~200 MB/s (per disk)          | ~200 MB/s (P30, coupled to size)           | **125 MB/s–1.2 GB/s (independent dial)** | 100 MB/s Standard, up to 10 GB/s Premium |
| **Durability**         | ❌ Ephemeral (node-local)     | ✅ Persistent (LRS)              | ✅ Persistent (in-zone)       | ✅ Persistent (**ZRS — 3 zones**)            | ✅ Persistent (**LRS only**, ZRS not supported for v2) | ✅ Persistent (LRS/ZRS)                |
| **Survives node loss** | Only with app-level replication | ✅ Yes                         | ✅ Yes (disk reattaches in same AZ) | ✅ Yes (reattaches in **any AZ**)          | ✅ Yes (re-attach **within same AZ only**) | ✅ Yes (any node remounts the share)  |
| **Survives AZ loss**   | Only with app-level replication | LRS = no / ZRS = yes           | ❌ No (LRS, zone-pinned)      | **✅ Yes — graceful failover**              | ❌ No (LRS only)                       | LRS = no / ZRS = yes                     |
| **PVs per node**       | Unlimited (local)             | Unlimited (iSCSI, no disk limit) | Up to 64 (VM disk limit)      | Up to 64 (VM disk limit)                   | Up to 64 (VM disk limit)               | Unlimited (network mount, no disk limit) |
| **Replication**        | App-level (e.g. Cassandra RF=3) | Storage-level (LRS by default) | Storage-level (LRS)           | Storage-level (3-zone sync)                | Storage-level (**LRS only**)           | Storage-level (LRS/ZRS at share)         |
| **Zone failover**      | App-level (peers in other AZs) | LRS (zone-pinned) / ZRS opt.    | LRS pinned                    | **Transparent cross-zone**                 | **LRS only — zone-pinned, no auto failover** | LRS / ZRS                          |
| **IOPS / size coupling** | Independent (NVMe is local) | SAN-wide pool                    | **Coupled** (P-tier sets IOPS)| **Coupled** (P-tier sets IOPS)             | **Independent dial** (the key v2 feature) | Coupled (Premium = 1 IOPS/GiB)      |
| **Access mode**        | `ReadWriteOnce`               | `ReadWriteOnce`                  | `ReadWriteOnce`               | `ReadWriteOnce` (shared disk also supported) | `ReadWriteOnce`                       | **`ReadWriteMany`** ✅                   |
| **Volume expansion**   | ✅                            | ✅ (via Azure portal/CLI)        | ✅                            | ✅                                          | ✅ (capacity + IOPS + throughput live)  | ✅                                       |

---

## When to pick each

### Local NVMe → **Cassandra, Redis, ClickHouse, Kafka**  *(ACS-managed)*
- You need the absolute lowest latency storage
- Your workload implements its own replication (Cassandra RF=3, Kafka replication)
- Data loss on node failure is acceptable because the app reconstructs from peers
- Nodes are dedicated `storagepool` Lsv3 VMs
- ⚠️ **Not for**: databases where data must survive a node failure without app-level replication

### Elastic SAN → **DBaaS platforms, per-user volumes, multi-tenant apps**  *(ACS-managed)*
- You need hundreds or thousands of PVs — iSCSI bypasses VM disk-attach limits
- You want centralized IOPS/throughput management at the SAN level
- Burst scenarios where fast volume attach/detach matters
- Cost model: provision capacity once at TiB level, share across many volumes
- ⚠️ **Not for**: ultra-low latency (still ~1ms iSCSI round-trip)

### Azure Disk v1 → **Postgres, MySQL, single-instance stateful apps**  *(AKS built-in CSI)*
- You need durable block storage that survives node loss and reattaches
- Standard managed-disk semantics via the built-in `disk.csi.azure.com` driver
- PV count per node < 64 (standard VM disk limit applies)
- Easier to snapshot / backup via Azure disk snapshots
- Tier-driven (P10/P20/P30…) — IOPS coupled to size
- ℹ️ Not managed by ACS v2.x — uses the AKS built-in CSI driver shipped with every AKS cluster

### Premium SSD v1 ZRS → **Single-instance DB needing cross-AZ HA**  *(AKS built-in CSI)*
- Same `disk.csi.azure.com` driver, SKU = `Premium_ZRS`
- Disk replicated **synchronously across 3 AZs** — survives a full zone outage
- Pod can re-attach to a node in any surviving zone (zero data loss, RTO ~60–90 s)
- The **only built-in option** for AZ-tolerant block storage today (v2 has no ZRS)
- ~10–15% cost premium over `Premium_LRS`, slightly higher write latency from sync replication
- IOPS / throughput **still coupled** to disk size (P10/P30/P50…) — no v2-style dial
- ⚠️ **Not for**: high-IOPS workloads (use Premium SSD v2 if you can tolerate zone pinning, or app-replicated NVMe)
- ⚠️ **Not for**: latency-critical workloads (sync cross-zone write tax)
→ Full doc: [`PREMIUM-SSD-ZRS.md`](PREMIUM-SSD-ZRS.md)

### Premium SSD v2 → **Single-instance DBs needing sub-ms + IOPS dial**  *(AKS built-in CSI)*
- Same `disk.csi.azure.com` driver as Premium SSD v1 — just the modern SKU
- **Independent dials** for capacity, IOPS, and throughput — no more "buy 4 TiB to get IOPS"
- Sub-ms latency (typ. 0.5 ms) — closes most of the gap to local NVMe
- Durability comes from the disk SKU (`PremiumV2_LRS`, 3× in-zone replicas)
- Use `WaitForFirstConsumer` (the StorageClass enforces it) — the disk is zone-pinned and must land in the pod's AZ
- ⚠️ **No ZRS yet** — single-zone disk. Cross-AZ HA needs app-level replication
- ⚠️ **No caching** — `cachingMode: None` is the only supported value
- Cost: pay for the dials you turn — typically ~50% cheaper than the v1 equivalent at the same IOPS
- ℹ️ Same built-in CSI as v1, just a different `skuName` in the StorageClass
→ Full doc: [`PREMIUM-SSD-V2.md`](PREMIUM-SSD-V2.md)

### Azure Files → **Shared content, web farms, CI caches, ML datasets**  *(AKS built-in CSI)*
- You need **ReadWriteMany** — multiple pods on multiple nodes mounting one volume
- Shared web/static content across an nginx fleet, CMS uploads, build caches
- POSIX-light (SMB) is enough — or pick NFS 4.1 for strict POSIX (hard links, locks)
- Cost-tunable: Standard tier for dev/test, Premium for prod latency
- ⚠️ **Not for**: ultra-low latency block storage (use NVMe), single-writer DBs (use Azure Disk)
- ⚠️ **NFS variant requires** a private endpoint in the AKS VNet — see `docs/AZURE-FILES.md` §3
- ℹ️ Not managed by ACS — uses the AKS built-in `file.csi.azure.com` driver

---

## Cost shape (australiaeast, rough list price)

| Resource                              | $/day      |
|---------------------------------------|------------|
| 2× Standard_D4s_v5 (syspool)         | ~$9        |
| 3× Standard_L8s_v3 (storagepool)     | ~$38       |
| Log Analytics (light)                 | ~$1        |
| LB standard                           | ~$0.60     |
| Azure Disk (20 GiB Premium SSD / PV) | ~$0.07/PV  |
| Elastic SAN 1 TiB base               | ~$4.50     |
| **NVMe-only total (idle)**            | **~$49/day** |
| **+ ESAN 1 TiB**                      | **~$53/day** |

> Lsv3 nodes are significantly pricier than D-series. Tear down the storagepool
> when not in use: `az aks nodepool scale -g $RG --cluster-name $CLUSTER -n storagepool --node-count 0`

---

## Replication strategy cheatsheet

| Storage type | Managed by | Recommended replication strategy |
|---|---|---|
| Local NVMe | ACS v2.1 | App-level only. Use Cassandra RF=3, Kafka replication factor ≥ 2. Do NOT rely on ACS volume replication for primary durability. |
| Elastic SAN | ACS v2.1 | LRS at SAN level. App-level replication optional (adds write amplification vs. ESAN's built-in durability). |
| Azure Disk v1 | AKS built-in CSI | Storage-level (zone-redundant managed disk). For HA, combine with app-level replication or use ZRS disks. |
| Premium SSD v2 | AKS built-in CSI | Storage-level **LRS only** (3× in-zone). No ZRS as of 2026 — for cross-AZ HA, run app-level replication (Patroni, CNPG) with one v2 disk per zone. |
| Azure Files | AKS built-in CSI | LRS by default at the share level; switch to ZRS for zone redundancy. Multi-region → use share snapshots + AzCopy or Azure Backup vault. |
