# Cost & Cleanup — ACS Lab

Practical guide to keeping spend predictable and tearing the lab down cleanly.
All figures are **list price, australiaeast, May 2026** — directional, not a quote.

---

## Cost shape per scenario

Steady-state, 24×7, before any reserved instances / hybrid benefit.

### Baseline (always-on, scenario-agnostic)
| Component | Qty | Hourly | Daily | Monthly |
|---|---|---|---|---|
| AKS control plane (Free tier, uptime SLO) | 1 | $0.10 | $2.40 | $73 |
| 2× Standard_D4s_v5 (syspool) | 2 | $0.392 | $9.40 | $286 |
| Log Analytics (light ingest, lab traffic) | 1 | ~$0.04 | ~$1 | ~$30 |
| Standard Load Balancer | 1 | $0.025 | $0.60 | $18 |
| Managed disks for OS (128 GiB Premium × 5 nodes) | 5 | ~$0.10 | ~$2.40 | ~$73 |
| VNet / NAT egress (light) | 1 | ~$0.05 | ~$1.20 | ~$36 |
| **Baseline subtotal** | | **~$0.71** | **~$17** | **~$516** |

### Scenario A — Cassandra on local NVMe (default lab)
| Component | Qty | Hourly | Daily | Monthly |
|---|---|---|---|---|
| 3× Standard_L8s_v3 (storagepool, zones 1/2/3) | 3 | $1.584 | $38 | $1,156 |
| Local NVMe (included with L8s_v3) | — | $0 | $0 | $0 |
| **Scenario A total (incl. baseline)** | | **~$2.30** | **~$55** | **~$1,672** |

### Scenario B — Azure Disk CSI workloads (Postgres etc.)
| Component | Qty | Hourly | Daily | Monthly |
|---|---|---|---|---|
| 3× Premium SSD P10 (128 GiB) | 3 | ~$0.07 | ~$1.68 | ~$51 |
| **Scenario B incremental** | | **~$0.07** | **~$1.68** | **~$51** |

(Add on top of baseline. No L-series needed — runs on D4s_v5.)

### Scenario C — Elastic SAN
| Component | Qty | Hourly | Daily | Monthly |
|---|---|---|---|---|
| Elastic SAN base (1 TiB premium) | 1 | ~$0.21 | ~$5 | ~$152 |
| ESAN provisioned IOPS / throughput | inc. | — | — | — |
| **Scenario C incremental** | | **~$0.21** | **~$5** | **~$152** |

(1 TiB minimum; jumps to ~$10/day at 2 TiB.)

### Scenario D — Azure Files RWX (nginx-shared)
| Component | Qty | Hourly | Daily | Monthly |
|---|---|---|---|---|
| Azure Files Premium share (100 GiB min) | 1 | ~$0.022 | ~$0.53 | ~$16 |
| Azure Files Standard (LRS, 100 GiB) | alt | ~$0.008 | ~$0.20 | ~$6 |
| **Scenario D incremental** | | **~$0.022** | **~$0.53** | **~$16** |

---

## Running everything at once

If you want all 4 scenarios live for a demo:

| | Daily | Monthly |
|---|---|---|
| Baseline | $17 | $516 |
| Cassandra NVMe | $38 | $1,156 |
| Azure Disk (Postgres) | $2 | $51 |
| ESAN 1 TiB | $5 | $152 |
| Azure Files Premium | $1 | $16 |
| **Total** | **~$63/day** | **~$1,890/month** |

---

## ACS-specific pricing nuances

1. **ACS itself is free** — no per-GiB ACS license fee. You only pay for the
   underlying Azure resources (NVMe is bundled with the L-series VM; ESAN is
   billed at the SAN level; Azure Disk at the disk SKU).
2. **Local NVMe is essentially "free storage"** — the NVMe capacity comes with
   the Lsv3 VM (1.92 TiB per L8s_v3). You're paying for the *compute*, the
   storage is included. This is why Cassandra-on-NVMe is so cost-attractive at
   scale.
3. **ESAN bills at the SAN, not the volume** — provisioning 1 TiB gets you
   5,000 IOPS / 200 MB/s no matter how many PVs you carve out of it. Each
   additional TiB adds linear capacity + throughput. **Min size 1 TiB** — even
   if your PVs total 50 GiB, you pay for 1 TiB.
4. **Replication multiplies usable IOPS, not bill** — `replication: 3` on ACS
   NVMe uses 3× the local disk space but doesn't change your VM bill (NVMe is
   bundled). Trade-off is capacity-per-node, not $.
5. **Azure Files Premium has a 100 GiB minimum** — for small RWX scenarios
   Standard LRS is much cheaper, just slower.

---

## Cleanup playbook

### Daily-end deallocate (cheap idle state)
Stops the cluster, keeps disks/PVs/config. Restart in ~2 min.
```bash
az aks stop -g rg-acstor-lab -n aks-acsl-3dntcpfgfndgw
```
Cost while stopped: ~$0.10/hr (control plane + storage) = ~$2.40/day.

Restart:
```bash
az aks start -g rg-acstor-lab -n aks-acsl-3dntcpfgfndgw
```

### Full teardown
```bash
# 1. Disable ACS to clean up the extension cleanly
az aks update -g rg-acstor-lab -n aks-acsl-3dntcpfgfndgw \
  --disable-azure-container-storage all

# 2. Delete the resource group (async, ~5–10 min)
az group delete -n rg-acstor-lab --yes --no-wait

# 3. Update the lab tracker
python3 ~/.openclaw/skills/azure-labs/scripts/labs.py update acstor-lab --status destroyed
```

⚠️ **Don't skip step 1 on long-lived clusters** — leaving the ACS extension
behind in a hard-deleted RG can leave orphaned role assignments. For a quick
single-RG nuke during lab work it's fine to go straight to step 2.

### Per-scenario teardown (keep cluster, drop the workload)

**Cassandra:**
```bash
kubectl delete -f manifests/workloads/cassandra-loadgen.yaml --ignore-not-found
kubectl delete -f manifests/workloads/nosqlbench-loadgen.yaml --ignore-not-found
kubectl delete -f manifests/workloads/cassandra-statefulset.yaml
# PVCs are kept by default — explicit delete to reclaim the NVMe space
kubectl delete pvc -l app=cassandra
```

**ESAN:**
```bash
kubectl delete -f manifests/workloads/postgres-statefulset.yaml --ignore-not-found
kubectl delete -f manifests/storageclass/elastic-san.yaml
az aks update -g rg-acstor-lab -n aks-acsl-3dntcpfgfndgw \
  --disable-azure-container-storage elasticSan
# ESAN resource itself is deployed via Bicep — set deployElasticSan=false and redeploy,
# or `az elastic-san delete -n <esan-name> -g rg-acstor-lab`
```

**Azure Files:**
```bash
kubectl delete -f manifests/workloads/nginx-shared.yaml
kubectl delete -f manifests/storageclass/azure-files-premium.yaml
# Dynamically-provisioned storage account in the MC_ RG is cleaned up automatically
```

### Cron-style auto-stop (avoid $ surprises overnight)
Local cron on your laptop, runs at 8pm Perth daily:
```bash
crontab -e
# Add:
0 20 * * * /opt/homebrew/bin/az aks stop -g rg-acstor-lab -n aks-acsl-3dntcpfgfndgw >/dev/null 2>&1
```

Or wire it through this repo's agent — ask "stop the acstor lab every day at 8pm"
and the cron tool handles it.

---

## Cost sanity checks

Before you walk away, run:
```bash
# What's actually deployed in the RG
az resource list -g rg-acstor-lab --query '[].{name:name,type:type}' -o table

# Current month-to-date by RG
az consumption usage list \
  --start-date $(date -v1d +%Y-%m-%d) \
  --end-date $(date +%Y-%m-%d) \
  --query "[?contains(instanceName, 'rg-acstor-lab')].{cost:pretaxCost, resource:instanceName}" \
  -o table 2>/dev/null | head -20
```

For the broader view across BOTH subscriptions, this repo's agent has access
to Azure Cost Management — just ask "what did the acstor lab cost yesterday?".
