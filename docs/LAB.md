# Lab Guide — Azure Container Storage on AKS

End-to-end deploy and exercise of an AKS cluster with Azure Container
Storage (ACStor), a sample stateful workload, and a smoke test.

## 0. Prerequisites

```bash
az version                       # az ≥ 2.61
az extension add  --name aks-preview     --upgrade
az extension add  --name k8s-extension   --upgrade
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.KubernetesConfiguration

kubectl version --client
helm version
```

Login + select subscription:

```bash
az login
az account set -s b9d87a00-a4d8-47d9-84a2-cfd7a9d745d2
```

## 1. Deploy the infra (Bicep)

```bash
RG=rg-acstor-lab
LOC=australiaeast

az group create -n "$RG" -l "$LOC"

cp infra/main.parameters.example.json infra/main.parameters.json   # gitignored
# edit if you want a different prefix or admin AAD group

az deployment group create \
  -g "$RG" \
  -f infra/main.bicep \
  -p @infra/main.parameters.json
```

Outputs you'll need:

```bash
az deployment group show -g "$RG" -n main \
  --query properties.outputs -o jsonc
```

## 2. Kubeconfig

```bash
CLUSTER=$(az aks list -g "$RG" --query '[0].name' -o tsv)
az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing
kubectl get nodes -o wide
```

## 3. Install / enable Azure Container Storage

Cleanest path today is the CLI (Bicep `storageProfile.azureContainerStorage`
is still in flux). Run **once** per cluster:

```bash
az aks update -g "$RG" -n "$CLUSTER" \
  --enable-azure-container-storage azureDisk \
  --azure-container-storage-nodepools syspool
```

This:

- installs the Azure Container Storage cluster extension into the `acstor` ns
- labels `syspool` as an ACStor io-engine pool
- creates a default `acstor-azuredisk` StorageClass

Verify:

```bash
kubectl get ns acstor
kubectl -n acstor get pods
kubectl get sc | grep acstor
```

## 4. (Optional) Custom storage pool

The defaults are fine. If you want a tighter / bigger pool:

```bash
kubectl apply -f manifests/00-storagepool-azuredisk.yaml
kubectl -n acstor get storagepool
```

For ephemeral NVMe, swap the system pool VM size to `Standard_L8s_v3` and apply
`manifests/00-storagepool-ephemeral-nvme.yaml` instead.

## 5. Deploy the sample workload

```bash
kubectl apply -f manifests/10-postgres-statefulset.yaml
kubectl apply -f manifests/20-smoke-writer.yaml

kubectl -n acstor-demo get pvc,pod -w
```

## 6. Validate

```bash
./tests/validate.sh
```

Expected:

- `acstor` pods all Running
- `acstor-azuredisk` StorageClass present
- both PVCs `Bound`
- `postgres-0` ready, write/read works

## 7. Perf smoke

```bash
kubectl apply -f tests/fio.yaml
kubectl -n acstor-demo logs -f job/fio-smoke
```

## 8. Cleanup

```bash
az group delete -n "$RG" --yes --no-wait
```

Then run `python3 ~/.openclaw/skills/azure-labs/scripts/labs.py update --status destroyed ...` to keep the tracker honest.
