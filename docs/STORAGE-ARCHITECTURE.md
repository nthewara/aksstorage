# Storage Architecture — How the Pieces Fit Together

Reference doc explaining the mental model behind the storage choices in this lab.
Covers what's ephemeral vs persistent, who owns replication, and how the CSI
drivers compare.

---

## NVMe with ACS — is it ephemeral or persistent?

Short answer: **the disks are physically ephemeral (tied to the VM), but ACS
gives you durability via replication, not via the disk itself.**

### Hardware reality
- Lsv3 NVMe is local-attached to the VM. If the node is deallocated or
  reimaged, that disk's contents are gone. Same as any local SSD.
- This is true regardless of ACS version.

### What ACS v2 actually gives you
A `localdisk.csi.acstor.io` PV is a real PVC with a lifecycle — it persists
across **pod restarts, pod rescheduling on the same node, and node reboots**.
It is not like `emptyDir`.

What it does NOT survive on its own:
- Node delete / replace / scale-down
- Cluster autoscaler removing the node
- Manual node reimage

### Durability = ACS volume replication
ACS v2 supports **replicated volumes** — you set `replication: 3` (or 2) in the
StorageClass and ACS keeps that many synchronous copies across different
nodes/zones. If a node dies, the volume stays online from the surviving
replicas. New node comes up → ACS resyncs a fresh replica onto it.

---

## Are Azure VM NVMe disks like the C: drive?

No — they're the **temp/resource disks**. Azure calls them "local temporary
storage." They sit physically inside the host server, not in Azure Storage.

| Disk type | Where it lives | Survives VM stop/dealloc? | Survives host failure? |
|---|---|---|---|
| OS disk (C:) | Azure managed disk (network-attached) | ✅ yes | ✅ yes (3× replicated in zone) |
| Data disks | Azure managed disk (network-attached) | ✅ yes | ✅ yes |
| Temp / NVMe (Lsv3) | Physical SSD in the host | ❌ no | ❌ no |

Even a **stop-deallocate** wipes the NVMe — VM moves to a different host on
next start, fresh empty NVMe. That's why ACS replication exists: it treats the
NVMe as fast scratch and makes durability a software concern.

Same pattern shows up everywhere — AWS instance store, GCP local SSD — all
the same physical model. Fast (sub-100µs), but your data lives where your app +
replica strategy puts it, not where the disk is.

---

## Replication: app-level vs storage-level

Two layers, pick one (rarely both).

### Option A — ACS handles replication (storage-layer)
- Set `replication: 2` or `replication: 3` in the StorageClass
- ACS keeps that many synchronous copies across different nodes (zone-aware
  where possible)
- Node dies → volume stays online from surviving replicas, new replica resyncs
  when a node comes back
- Transparent to the app — it just sees a normal PV
- **Use when:** the app doesn't know how to replicate itself (Postgres single
  primary, Redis single, MySQL primary, MinIO standalone, anything that expects
  a "durable disk")

### Option B — app handles replication, ACS keeps `replication: 1`
- StorageClass has 1 replica (or it's implied)
- Each pod gets its own independent NVMe PV
- Node dies → that pod's data is gone, but the app rebuilds from peers
- **Use when:** app already replicates (Cassandra RF=3, Kafka, MongoDB replica
  set, Elasticsearch with replicas, etcd)

### Why you almost never do both
Double-replicating burns IOPS and capacity for no win:
- 3 Cassandra pods × RF=3 (app) × `replication=3` (ACS) = 9× the writes for 0
  extra durability
- Pick the layer that already owns it and let the other one be 1×.

### Decision tree
- Is the workload a clustered/replicated stateful system? → app-level (Option B)
- Is it a single-instance database or legacy app? → storage-level (Option A)
- Is it a stateless cache where ephemerality is fine? → `replication: 1`, no
  recovery needed

The Cassandra lab in this repo is the textbook Option B case — see
[`FAILURE-SCENARIOS.md`](FAILURE-SCENARIOS.md) for the trade-off discussion.

---

## Azure Disk CSI vs ACS — who replicates?

**The Azure Disk CSI driver (`disk.csi.azure.com`) doesn't do replication
itself. The replication happens inside the managed disk.**

### Where durability comes from
Every managed disk you get back is already replicated by Azure Storage under
the hood, based on the SKU you pick:

| Disk SKU | Replication | Survives |
|---|---|---|
| Premium_LRS / StandardSSD_LRS / Standard_LRS | 3 copies, single zone | Disk hardware failure |
| Premium_ZRS / StandardSSD_ZRS | 3 copies across 3 zones | Full zone outage |

So when a pod with an Azure Disk PVC fails over to another node:
- Same-zone failover → trivial, disk just re-attaches
- Cross-zone failover (different AZ) → only works if the disk is ZRS,
  otherwise the disk is pinned to its zone and the pod will be stuck Pending
  until a node in that zone comes back

### What the CSI driver actually does
Thin control plane — provision, attach, detach, snapshot, resize, expand. No
cross-disk replication, no quorum, no resync logic. Single-writer (RWO) only.

### Side-by-side

|  | Azure Disk CSI | ACS NVMe (replicated) | ACS NVMe (single) |
|---|---|---|---|
| Replication owner | Azure Storage (in SKU) | ACS engine (across nodes) | None (app handles it) |
| Crosses zones | Only if ZRS | Yes, zone-aware | No |
| Survives node loss | Yes (disk re-attaches) | Yes (transparent) | No (app rebuilds) |
| Latency | ~1–2 ms (network) | sub-ms (local NVMe) | sub-ms |
| Max IOPS | Up to 80K (Ultra) | 100K+ per node | 100K+ per node |
| Multi-writer (RWX) | No (RWO only*) | No | No |

\* Disk CSI has a "shared disk" preview for RWO-multi but it's
clustered-filesystem territory, not real RWX.

### Mental model that usually clicks
- **Azure Disk CSI** — "give me a durable disk, Azure replicates it for me, I
  don't care about the storage layer." Slower (network attach), but
  bulletproof.
- **ACS NVMe replicated** — "give me a fast local disk AND keep replicas across
  nodes inside the cluster." Best of both worlds, costs the local NVMe space ×
  replica count.
- **ACS NVMe single + app replication** — "give me raw speed, my app does the
  durability." Fastest, leanest, but only works for replicated apps.

### Where Azure Disk CSI wins vs ACS
- Single-pod workloads where you can tolerate ~1 ms latency (most LOB apps,
  dev/test DBs)
- Workloads that need disk snapshots / Azure-native backup integration
- Anything that needs to survive a full cluster nuke — the disk lives
  independently of AKS

### Where it loses
- Per-VM disk attach limits (8–32 disks per VM depending on size) — this is the
  exact problem ESAN solves
- Cross-zone failover unless you're on ZRS (and not every region has ZRS for
  every SKU)
- Latency-sensitive workloads (Cassandra, Kafka, Redis-persistent) where local
  NVMe wins by 10–100×

---

## Does ACS v2 support Azure Files?

**No.** ACS v2.1 supports exactly two storage types: `ephemeralDisk` (local
NVMe) and `elasticSan`.

Azure Files in AKS is handled by the **built-in CSI driver**
(`file.csi.azure.com`) that ships with the cluster — completely separate from
ACS. Enabled with `--enable-file-csi-driver` (on by default in new clusters).

Why? Different problem domain:
- **ACS** orchestrates block storage (NVMe pools, SAN volumes) — RWO,
  high-perf, replication, pool management
- **Azure Files CSI** handles file shares over SMB/NFS — RWX-first, network
  filesystem, no pool concept

There's no public signal that Files is moving under the ACS umbrella.

### The line, summarized

| Storage | Managed by | Best for |
|---|---|---|
| NVMe (`ephemeralDisk`) | ACS v2.1 | Cassandra, Kafka, Elastic, latency-critical |
| Elastic SAN (`elasticSan`) | ACS v2.1 | Many small PVs, DBaaS, dev fleets |
| Azure Disk (`disk.csi.azure.com`) | AKS built-in CSI | Single-pod stateful, snapshots, durability via SKU |
| Azure Files (`file.csi.azure.com`) | AKS built-in CSI | RWX shared content, web farms, ML datasets |
