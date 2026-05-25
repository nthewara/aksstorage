# Storage Type Matrix — NVMe vs Azure Disk vs Elastic SAN vs Azure Files

Use this table to pick the right backing storage for your workload.

| Attribute              | **Local NVMe** (`local-nvme`) | **Azure Disk** (`azure-disk-acstor`) | **Elastic SAN** (`azuresan-csi`) | **Azure Files** (`acstor-azurefiles-*`) |
|------------------------|-------------------------------|--------------------------------------|----------------------------------|------------------------------------------|
| **Provisioner**        | `localdisk.csi.acstor.io`     | `disk.csi.acstor.io`                 | `san.csi.azure.com`              | `file.csi.azure.com`                     |
| **Backing resource**   | NVMe on Lsv3 node             | Azure Managed Disk (Premium SSD)     | Azure Elastic SAN (iSCSI)        | Azure Files share (SMB or NFS 4.1)       |
| **Typical read IOPS**  | 400k+ (direct NVMe)           | ~20k (P30 disk)                      | 5k–1M+ (scales with SAN TiB)     | 400–100k (scales with share size, tier)  |
| **Typical latency**    | sub-100µs                     | ~1ms                                 | ~1ms                             | 1–3ms Premium / 5–10ms Standard          |
| **Throughput**         | 3+ GB/s (per node)            | ~200 MB/s (per disk)                 | 200 MB/s–40 GB/s (SAN-wide)      | 100 MB/s Standard, up to 10 GB/s Premium |
| **Durability**         | ❌ Ephemeral (node-local)     | ✅ Persistent (zone-redundant)       | ✅ Persistent (LRS)              | ✅ Persistent (LRS/ZRS)                  |
| **Survives node loss** | Only with app-level replication | ✅ Yes (disk reattaches)           | ✅ Yes                           | ✅ Yes (any node remounts the share)     |
| **PVs per node**       | Unlimited (local)             | Up to 64 (VM disk limit)             | Unlimited (iSCSI, no disk limit) | Unlimited (network mount, no disk limit) |
| **Replication**        | App-level (e.g. Cassandra RF=3) | ACStor volume replication (opt.)  | Storage-level (LRS by default)   | Storage-level (LRS/ZRS at share)         |
| **Access mode**        | `ReadWriteOnce`               | `ReadWriteOnce`                      | `ReadWriteOnce`                  | **`ReadWriteMany`** ✅                   |
| **Volume expansion**   | ✅                            | ✅                                   | ✅ (via Azure portal/CLI)        | ✅                                       |

---

## When to pick each

### Local NVMe → **Cassandra, Redis, ClickHouse, Kafka**
- You need the absolute lowest latency storage
- Your workload implements its own replication (Cassandra RF=3, Kafka replication)
- Data loss on node failure is acceptable because the app reconstructs from peers
- Nodes are dedicated `storagepool` Lsv3 VMs
- ⚠️ **Not for**: databases where data must survive a node failure without app-level replication

### Azure Disk → **Postgres, MySQL, single-instance stateful apps**
- You need durable block storage that survives node loss and reattaches
- Standard managed-disk semantics with ACStor StorageClass abstraction
- PV count per node < 64 (standard VM disk limit applies)
- Easier to snapshot / backup via Azure disk snapshots

### Elastic SAN → **DBaaS platforms, per-user volumes, multi-tenant apps**
- You need hundreds or thousands of PVs — iSCSI bypasses VM disk-attach limits
- You want centralized IOPS/throughput management at the SAN level
- Burst scenarios where fast volume attach/detach matters
- Cost model: provision capacity once at TiB level, share across many volumes
- ⚠️ **Not for**: ultra-low latency (still ~1ms iSCSI round-trip)

### Azure Files → **Shared content, web farms, CI caches, ML datasets**
- You need **ReadWriteMany** — multiple pods on multiple nodes mounting one volume
- Shared web/static content across an nginx fleet, CMS uploads, build caches
- POSIX-light (SMB) is enough — or pick NFS 4.1 for strict POSIX (hard links, locks)
- Cost-tunable: Standard tier for dev/test, Premium for prod latency
- ⚠️ **Not for**: ultra-low latency block storage (use NVMe), single-writer DBs (use Azure Disk)
- ⚠️ **NFS variant requires** a private endpoint in the AKS VNet — see `docs/AZURE-FILES.md` §3

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

| Storage type | Recommended replication strategy |
|---|---|
| Local NVMe | App-level only. Use Cassandra RF=3, Kafka replication factor ≥ 2. Do NOT rely on ACStor volume replication for primary durability. |
| Azure Disk | Storage-level (zone-redundant managed disk). Optional ACStor volume replication for extra HA. |
| Elastic SAN | LRS at SAN level. App-level replication optional (adds write amplification vs. ESAN's built-in durability). |
| Azure Files | LRS by default at the share level; switch to ZRS for zone redundancy. Multi-region → use share snapshots + AzCopy or Azure Backup vault. |
