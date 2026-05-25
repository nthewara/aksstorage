# Lab Guide — Azure Container Storage v2.1 on AKS

Primary path: **Cassandra on local NVMe** (ephemeral disk, Lsv3 storage pool).
Secondary: Postgres on Azure Disk **via the AKS built-in CSI driver** (not ACS).
Optional third: Elastic SAN (see `docs/ELASTIC-SAN.md`).

> **ACS v2.x scope reminder**: the `--enable-azure-container-storage` flag only
> accepts `ephemeralDisk` or `elasticSan` in v2.1. The v1.x `azureDisk` ACS type
> was removed in v2.0. For disk-backed PVs we use the built-in
> `disk.csi.azure.com` driver that ships with every AKS cluster — no ACS
> involvement. See the
> [ACS release notes](https://learn.microsoft.com/en-us/azure/storage/container-storage/container-storage-release-notes).

---

## 0. Prerequisites

```bash
# Azure CLI ≥ 2.83.0 (v2.1 requirement)
az version

az extension add --name k8s-extension   --upgrade
az extension add --name elastic-san     --upgrade   # ESAN scenario only
# Note: aks-preview is NOT needed for v2.1 GA features

az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ElasticSan   # ESAN only

kubectl version --client
helm version   # needed for Bitnami Cassandra path
```

Login:

```bash
az login
az account set -s b9d87a00-a4d8-47d9-84a2-cfd7a9d745d2
```

---

## 1. Deploy infra (Bicep)

Creates: VNet, Log Analytics, AKS cluster with two node pools:
- **syspool** — 2× Standard_D4s_v5 (system, no storage role)
- **storagepool** — 3× Standard_L8s_v3 across AZs 1/2/3 (NVMe nodes, tainted `storage=nvme:NoSchedule`)

```bash
RG=rg-acstor-lab
LOC=australiaeast

az group create -n "$RG" -l "$LOC"
cp infra/main.parameters.example.json infra/main.parameters.json   # gitignored — edit prefix etc.

az deployment group create \
  -g "$RG" \
  -f infra/main.bicep \
  -p @infra/main.parameters.json
```

Outputs you'll need:

```bash
az deployment group show -g "$RG" -n main --query properties.outputs -o jsonc
```

---

## 2. Kubeconfig

```bash
CLUSTER=$(az aks list -g "$RG" --query '[0].name' -o tsv)
az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing
kubectl get nodes -o wide -L kubernetes.azure.com/agentpool
```

You should see:
- `syspool` nodes (D4s_v5)
- `storagepool` nodes (L8s_v3) — one per zone

---

## 3. Enable Azure Container Storage — v2.1 modular install

### Flow A (recommended): enable + storage type upfront

```bash
# Primary path: local NVMe on the storagepool node pool
az aks update -g "$RG" -n "$CLUSTER" \
  --enable-azure-container-storage ephemeralDisk \
  --azure-container-storage-nodepools storagepool
```

> **ACS v2.1 change**: the legacy `--storage-pool-option NVMe` flag has been
> **removed** in v2.x. The storage type (`ephemeralDisk`, `elasticSan`) now
> implies the pool option — if you pass `--storage-pool-option` you'll get:
> *"The latest version of Azure Container Storage does not require or support
> a --storage-pool-option value."* Just drop the flag.
>
> `--azure-container-storage-nodepools` is still supported and pins the CSI
> driver / storage pool to a specific nodepool (the Lsv3 `storagepool` in our
> lab). Without it, ACS picks a default which may not be what you want.

This installs the ACStor installer + local NVMe CSI driver and creates a default
`local-csi` StorageClass. Wait ~5 minutes for the extension to converge.

### Flow B (lightweight): enable only, add storage type later

```bash
# Step 1: install the ACStor installer component only (no CSI driver yet)
az aks update -g "$RG" -n "$CLUSTER" --enable-azure-container-storage

# Step 2: apply the local-nvme StorageClass — this triggers CSI driver installation
kubectl apply -f manifests/storageclass/local-nvme.yaml
# CSI driver installs on storagepool nodes within ~2 minutes of SC creation.
```

### Verify installation

> **ACS v2.x runs in `kube-system`** — the old `acstor` namespace is gone
> (removed in v2.0 "simplified deployment"). All ACS pods/deployments now
> live alongside other AKS system components.

```bash
kubectl get deploy -n kube-system | grep acstor
kubectl get pod  -n kube-system | grep acstor
kubectl get sc | grep -E 'local-|acstor'
```

Expected pods (after enabling `ephemeralDisk`):
- `acstor-cluster-manager-*` (the installer/controller, 2 replicas)
- `acstor-geneva-*` (telemetry, 2 replicas)
- `acstor-local-csi-driver-*` (CSI DaemonSet on storagepool nodes)
- `acstor-node-agent-*` (DaemonSet on storage nodes)
- `acstor-otel-collector-*` (logs/metrics DaemonSet)

Also check the auto-created default StorageClass:
```bash
kubectl get sc local-csi
# PROVISIONER: localdisk.csi.acstor.io  BINDINGMODE: WaitForFirstConsumer
```

> 💡 ACS v2 **auto-creates `local-csi`** when you pass `--enable-azure-container-storage ephemeralDisk`.
> You can use it directly. Our `manifests/storageclass/local-nvme.yaml` is a
> separately-named SC for cases where you want a different name or custom params.

---

## 4. Apply the local-nvme StorageClass (node affinity)

This SC targets the `storagepool` agentpool using v2.1 node selector support:

```bash
kubectl apply -f manifests/storageclass/local-nvme.yaml
kubectl get sc local-nvme
```

Check that local CSI driver pods only run on storagepool nodes:

```bash
kubectl -n kube-system get pods -o wide | grep -E 'localdisk|local-csi'
```

---

## 5a. Deploy Cassandra — Bitnami Helm (recommended)

The upstream Azure Samples repo uses the Bitnami chart. Simplest production-like path:

```bash
helm install cassandra \
  --namespace cassandra --create-namespace \
  --set replicaCount=3 \
  --set global.storageClass=local-nvme \
  --set persistence.storageClass=local-nvme \
  --set persistence.size=50Gi \
  --set resources.limits.cpu=4 \
  --set resources.limits.memory=8Gi \
  --set resources.requests.cpu=2 \
  --set resources.requests.memory=4Gi \
  --set nodeSelector."kubernetes\.azure\.com/agentpool"=storagepool \
  --set tolerations[0].key=storage \
  --set tolerations[0].operator=Equal \
  --set tolerations[0].value=nvme \
  --set tolerations[0].effect=NoSchedule \
  oci://registry-1.docker.io/bitnamicharts/cassandra
```

## 5b. Deploy Cassandra — raw manifest

For full visibility into the StatefulSet spec:

```bash
kubectl apply -f manifests/workloads/cassandra-statefulset.yaml
kubectl -n cassandra get pods -w
```

Wait for all 3 pods to be `Running` and `1/1 Ready` (~3-5 minutes for data dirs to init).

---

## 6. Validate Cassandra

```bash
# Check cluster membership — expect 3 UN (Up/Normal) nodes
kubectl -n cassandra exec cassandra-0 -- nodetool status

# Quick CQL write + read
kubectl -n cassandra exec -it cassandra-0 -- cqlsh -e "
  CREATE KEYSPACE IF NOT EXISTS lab WITH replication = {
    'class': 'NetworkTopologyStrategy', 'australiaeast': 3
  };
  USE lab;
  CREATE TABLE IF NOT EXISTS t (id uuid PRIMARY KEY, v text);
  INSERT INTO t (id, v) VALUES (uuid(), 'hello-acstor-v2.1');
  SELECT * FROM t;
"
```

---

## 7. Run load generator

```bash
kubectl apply -f manifests/workloads/cassandra-loadgen.yaml
kubectl -n cassandra logs -f job/cassandra-loadgen
```

Runs ~100k writes + 50k reads via `cassandra-stress`, then exits.

---

## 8. Full validation script

```bash
./tests/validate.sh
```

Checks: acstor pods, expected StorageClasses, Cassandra STS Ready, nodetool UN==3, CQL roundtrip.

---

## 9. NVMe perf baseline (fio)

```bash
kubectl apply -f tests/fio-nvme.yaml
kubectl -n cassandra logs -f job/fio-nvme
```

---

## 10. Secondary scenario — Postgres on Azure Disk (built-in CSI, NOT ACS)

In ACS v2.x the `azureDisk` storage type no longer exists — it was removed in
v2.0. Disk-backed PVs use the **AKS built-in `disk.csi.azure.com` driver**,
which is enabled on every AKS cluster by default. No `az aks update --enable-
azure-container-storage` step is needed for this scenario.

```bash
# No ACS enable step — disk.csi.azure.com is already installed on the cluster.
kubectl get csidrivers | grep disk.csi.azure.com

kubectl apply -f manifests/storageclass/azure-disk.yaml
kubectl apply -f manifests/workloads/postgres-statefulset.yaml
kubectl -n acstor-demo get pvc,pod -w
```

> Included here as a side-by-side comparison with the ACS NVMe and ESAN flows —
> useful when you need durable, reattachable block storage but don't want to
> bring ACS into the picture.

---

## 11. Switching / adding storage types post-install

v2.1 supports additive enable/disable of ACS-managed types. The only valid
storage types for `--enable-azure-container-storage` in v2.x are
`ephemeralDisk` and `elasticSan` — there is no `azureDisk` option anymore.

```bash
# Add ESAN support alongside NVMe (both can coexist)
az aks update -g "$RG" -n "$CLUSTER" \
  --enable-azure-container-storage elasticSan \
  --elastic-san-resource-id "$ESAN_ID"

# Disable a storage type (removes its CSI driver)
az aks update -g "$RG" -n "$CLUSTER" \
  --disable-azure-container-storage ephemeralDisk

# Disable ACStor entirely
az aks update -g "$RG" -n "$CLUSTER" \
  --disable-azure-container-storage
```

> Azure Disk and Azure Files PVs use the AKS built-in CSI drivers
> (`disk.csi.azure.com`, `file.csi.azure.com`) and are unaffected by these
> commands — they're independent of ACS lifecycle.

---

## 12. Optional — Elastic SAN scenario

See [`docs/ELASTIC-SAN.md`](ELASTIC-SAN.md) for full walkthrough.

---

## 13. Cleanup

```bash
az group delete -n "$RG" --yes --no-wait
```
