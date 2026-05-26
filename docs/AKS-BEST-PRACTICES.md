# AKS Best Practices — Gap Analysis & Implementation

> Audited 2026-05-26 against the live `aks-acsl-3dntcpfgfndgw` cluster and
> the [AKS Automatic feature comparison](https://learn.microsoft.com/en-us/azure/aks/intro-aks-automatic)
> + [AKS operator network best practices](https://learn.microsoft.com/en-us/azure/aks/operator-best-practices-network).
>
> Changes implemented in `infra/modules/aks.bicep` + `infra/modules/network.bicep`.
> Each item below maps to a GitHub issue.

---

## Summary table

| # | Area | Was | Now | Issue |
|---|------|-----|-----|-------|
| 1 | Networking | Azure CNI subnet mode (pod IPs from VNet) | **Azure CNI Overlay** (`networkPluginMode=overlay`, podCidr `100.64.0.0/10`) | [#24](../../issues/24) |
| 2 | Upgrades | `upgradeChannel=null`, `nodeOsUpgrade=NodeImage` | `upgradeChannel=patch`, `nodeOSUpgradeChannel=NodeImage` (codified in Bicep) | [#25](../../issues/25) |
| 3 | Cluster tier | Free (no SLA) | **Standard** (99.9% API server SLA) | [#26](../../issues/26) |
| 4 | Autoscaler | Disabled, `maxPods=30` | **Enabled** syspool 2–4 / storagepool 3–6, `maxPods=110` | [#27](../../issues/27) |
| 5 | OS disk | Managed on both pools | **Ephemeral** on syspool, Managed on storagepool (ACS conflict) | [#28](../../issues/28) |
| 6 | Security | workloadIdentity only | + **nodeRestriction** + **imageCleaner** (48h interval) | [#29](../../issues/29) |
| 7 | API server access | Unrestricted (`authorizedIPRanges=null`) | Param `apiServerAuthorizedIPRanges` (default empty = unrestricted, set your IP) | [#31](../../issues/31) |
| 8 | Monitoring | Log Analytics / Container Insights | Managed Prometheus + Managed Grafana (**planned**, separate module) | [#30](../../issues/30) |
| 9 | Node OS SKU | Ubuntu | **AzureLinux** (Azure Linux 3 — AKS Automatic default, supported on Lsv3) | Included in #24/#28 |

---

## 1 · Azure CNI Overlay (`networkPluginMode=overlay`) — Issue #24

### What changed
```diff
- networkPlugin: 'azure'
+ networkPlugin: 'azure'
+ networkPluginMode: 'overlay'
+ podCidr: '100.64.0.0/10'
```
Subnet `/22` → `/24` (only node IPs live in the VNet now).

### Why
Old Azure CNI (subnet mode) allocates a real VNet IP for every pod. With 5 nodes × 30 maxPods each, that's up to 155 IPs needed from `snet-aks`. The `/22` (1022 hosts) was sized for that. With Overlay, pods get IPs from `podCidr` — an isolated address space that the VNet never sees. Nodes only need one VNet IP each, so a `/24` is plenty.

AKS Automatic uses CNI Overlay by default. `kubenet` (the other lightweight option) is being retired in March 2028 — overlay is the forward path.

**What `100.64.0.0/10` is**: the IANA "shared address space" (RFC 6598). Not routable on the public internet, not a standard private range — ideal for Kubernetes pod CIDRs. Gives ~4M pod IPs.

### Effect on storage scenarios
None. All storage operations (PV bind, CSI attach, ACS NVMe, Azure Files mount) are data-plane and don't care about pod IP allocation mode. Cross-namespace DNS (`svc.cluster.local`) works identically.

### maxPods bump (30 → 110)
With subnet mode, 30 pods/node was a hard limit driven by subnet IP exhaustion. Overlay removes that constraint — 110 pods/node is the recommended value for production and matches what AKS Automatic sets.

---

## 2 · Auto-upgrade channel — Issue #25

```bicep
autoUpgradeProfile: {
  upgradeChannel: 'patch'
  nodeOSUpgradeChannel: 'NodeImage'
}
```

`patch` channel: AKS automatically upgrades the cluster to the latest tested patch within the current minor version (e.g. 1.34.6 → 1.34.7). It will **not** jump minor versions (1.34 → 1.35). Safe for labs; prevents CVE accumulation on a stale patch.

`NodeImage`: node OS images are upgraded to the latest VHD on each release cycle (~weekly). Was already active on the live cluster but wasn't codified in Bicep.

---

## 3 · Standard tier — Issue #26

```bicep
sku: {
  name: 'Base'
  tier: 'Standard'
}
```

Free tier has no SLA, limited autoscaler support, and reduced support. Standard tier gives:
- 99.9% uptime SLA on the API server (with AZs: 99.95%)
- Required for cluster autoscaler to function reliably with zone-spread node pools
- AKS Automatic requires Standard tier minimum

Cost: ~$0.10/cluster-hour = ~$73/month. Negligible vs the $50+/day on Lsv3 nodes.

---

## 4 · Cluster autoscaler + maxPods=110 — Issue #27

```bicep
// syspool
enableAutoScaling: true
minCount: 2
maxCount: 4
maxPods: 110

// storagepool
enableAutoScaling: true
minCount: 3   // never below 3 — one per AZ for zone spread
maxCount: 6
maxPods: 110
```

`storagepool` min=3 is intentional — dropping below 3 would collapse AZ coverage and break the zone-pinning story that the storage scenarios demonstrate. Max=6 gives room for load testing.

`maxPods=110` is safe with Overlay because pod IPs come from `podCidr`, not the subnet. 110 is the recommended production value and matches AKS Automatic.

---

## 5 · Ephemeral OS disk on syspool — Issue #28

```bicep
// syspool only
osDiskType: 'Ephemeral'
osDiskSizeGB: 128
```

Ephemeral OS uses the node's local temp SSD cache as the OS disk. Benefits:
- Faster node provision (~30s vs ~90s for Managed)
- No extra managed disk cost ($5–10/node/mo gone)
- Higher IOPS for OS/kubelet operations

**storagepool stays `Managed`** — ACS v2.1 NVMe setup takes ownership of the local NVMe device on Lsv3 nodes. Mixing ephemeral OS (which also uses temp disk) with ACS NVMe causes conflicts. This is a known constraint.

---

## 6 · Node Restriction + Image Cleaner — Issue #29

```bicep
securityProfile: {
  workloadIdentity: { enabled: true }       // was already here
  #disable-next-line BCP037
  nodeRestriction: { enabled: true }        // new
  imageCleaner: {                            // new
    enabled: true
    intervalHours: 48
  }
}
```

**Node Restriction** (`NodeRestriction` admission plugin): prevents a compromised node from labelling itself with arbitrary labels or reading secrets for other nodes/pods. AKS Automatic has this preconfigured. The `#disable-next-line BCP037` suppresses a Bicep type-definition lag warning — the property is valid in the ARM API at `2025-01-01+`.

**Image Cleaner**: every 48h, scans each node and removes container images not in use by any running pod. Prevents stale/vulnerable images from accumulating. AKS Automatic default.

---

## 7 · API server authorised IP ranges — Issue #31

```bicep
apiServerAccessProfile: {
  authorizedIPRanges: apiServerAuthorizedIPRanges  // array param, default []
}
```

Default `[]` = unrestricted (keeps backward compat — existing deploys without the param set still work). Set in your `main.parameters.json`:

```json
"apiServerAuthorizedIPRanges": { "value": ["115.70.58.97/32"] }
```

AKS Automatic defaults to private cluster or restricted access. For a public-endpoint lab, IP restriction is the pragmatic middle ground.

---

## 8 · Node OS SKU: AzureLinux (Azure Linux 3)

```bicep
osSKU: 'AzureLinux'
```

Previously `Ubuntu` (implicit default). AKS Automatic defaults to Azure Linux 3 (formerly CBL-Mariner). Benefits:
- Minimal attack surface (smaller package set)
- Faster boot
- Microsoft-maintained, integrated into AKS update cadence
- Azure Linux 2.0 is retired (EOL Nov 2025) — new clusters should use 3.0

Tested and supported on both D-series and Lsv3. No effect on ACS NVMe, Azure Disk CSI, or Azure Files CSI.

---

## 9 · Managed Prometheus + Managed Grafana — Issue #30 (planned)

Not yet implemented — requires a dedicated Bicep module (`infra/modules/monitoring-prometheus.bicep`) for:
- `Microsoft.Monitor/accounts` (Azure Monitor Workspace)
- `Microsoft.Dashboard/grafana` (Managed Grafana instance)
- `azureMonitorProfile.metrics` on the AKS resource
- RBAC: Grafana → Monitor Workspace data reader

When done, pre-built dashboards will show disk IOPS, PV latency, and MM2 replication lag for all storage scenarios side-by-side.

---

## Redeployment notes

> ⚠️ **You cannot migrate an existing cluster from subnet mode to Overlay in-place.**
> The network plugin mode is immutable after cluster creation.
>
> To get the new network config:
> 1. Delete the old RG: `az group delete -n rg-acstor-lab --yes --no-wait`
> 2. Use a new RG + new suffix: `az group create -n rg-acstor-lab2 -l australiaeast`
> 3. Deploy: `az deployment group create -g rg-acstor-lab2 -f infra/main.bicep -p @infra/main.parameters.json`
>
> All the other changes (tier, autoscaler, imageCleaner, nodeRestriction, autoUpgrade, osSKU) can be applied to a running cluster via `az aks update` without recreation. The Bicep codifies them so fresh deploys get them from day 1.

### In-place update commands for the existing cluster (non-network changes only)

```bash
CLUSTER=aks-acsl-3dntcpfgfndgw
RG=rg-acstor-lab

# Standard tier
az aks update -g $RG -n $CLUSTER --tier standard

# Patch auto-upgrade
az aks update -g $RG -n $CLUSTER --auto-upgrade-channel patch

# Autoscaler — syspool
az aks nodepool update -g $RG --cluster-name $CLUSTER -n syspool \
  --enable-cluster-autoscaler --min-count 2 --max-count 4

# Autoscaler — storagepool
az aks nodepool update -g $RG --cluster-name $CLUSTER -n storagepool \
  --enable-cluster-autoscaler --min-count 3 --max-count 6

# Image Cleaner
az aks update -g $RG -n $CLUSTER --enable-image-cleaner --image-cleaner-interval-hours 48

# API server IP restriction (replace with your IP)
az aks update -g $RG -n $CLUSTER --api-server-authorized-ip-ranges 115.70.58.97/32
```

> **CNI Overlay + AzureLinux osSKU + Ephemeral OS disk** require cluster recreation (immutable or node-pool replacement). Apply on next lab redeploy via the updated Bicep.
