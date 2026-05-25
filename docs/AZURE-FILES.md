# Azure Files on AKS — RWX shared storage

Azure Files gives you a **ReadWriteMany** PVC backed by either SMB or NFS, fully
managed by Azure. The CSI driver `file.csi.azure.com` ships on AKS by default,
and this scenario uses **Managed Identity only** — no storage account keys,
since keys are disabled tenant-wide.

---

## 1. When to pick Azure Files

Pick Azure Files when **any** of these apply:

- You need `ReadWriteMany` — multiple pods reading and writing the same volume
- Shared content: web farms (nginx fleet, static assets), CMS uploads, build
  output caches, model artefacts, training datasets shared across worker pods
- POSIX-light is enough (SMB) — file ownership/mode work, hard links don't,
  byte-range locks are advisory
- You need strict POSIX (hard links, advisory + mandatory locks) → use the **NFS**
  variant

Pick something else when:

- You need ultra-low latency, <1ms p99 → **local NVMe**
- Single-writer durable block → **Azure Disk**
- Hundreds of PVs from one node, iSCSI semantics → **Elastic SAN**

---

## 2. SMB vs NFS — decision tree

- **Windows pods in the mix?** → SMB (NFS does not support Windows)
- **Need hard links / strict POSIX locks?** → NFS
- **Need AAD/Kerberos identity-based auth on the wire?** → SMB
- **Cluster has no private VNet or you can't add a private endpoint?** → SMB
  (NFS Files requires private endpoint + public access disabled)
- **High concurrent reads, dataset-style workloads?** → NFS with `nconnect=4`
- **Default for this lab** → SMB Premium (`acstor-azurefiles-premium`)

---

## 3. Managed Identity + RBAC setup (NO keys)

Storage account keys are disabled in this tenant. Dynamic provisioning has to
work entirely through identity. The CSI driver acts as the kubelet MI, so the
kubelet MI needs RBAC at the **resource group** scope (so it can create the
storage account and then assign itself data-plane access).

### 3.1 Grab the kubelet MI

```bash
RG=rg-acstor-lab
CLUSTER=$(az aks list -g "$RG" --query '[0].name' -o tsv)

KUBELET_MI_ID=$(az aks show -g "$RG" -n "$CLUSTER" \
  --query 'identityProfile.kubeletidentity.objectId' -o tsv)
RG_ID=$(az group show -n "$RG" --query id -o tsv)
```

### 3.2 Assign roles at RG scope

```bash
# Required for dynamic provisioning + SMB data-plane mount via AAD/Kerberos
az role assignment create \
  --assignee-object-id "$KUBELET_MI_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage File Data SMB Share Contributor" \
  --scope "$RG_ID"

# Lets the driver create the storage account + share dynamically
az role assignment create \
  --assignee-object-id "$KUBELET_MI_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "$RG_ID"
```

> ⚠️ `Contributor` at RG scope is the simplest path for dynamic provisioning.
> If your security posture forbids it, scope a custom role to just
> `Microsoft.Storage/storageAccounts/*` and assign at RG.

### 3.3 NFS-only — private endpoint + DNS

NFS mounts require the storage account to be private. Before applying the NFS
StorageClass:

```bash
VNET=$(az network vnet list -g "$RG" --query '[0].name' -o tsv)
SUBNET=acstor-pe   # dedicated subnet for private endpoints

az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$SUBNET" \
  --address-prefixes 10.40.99.0/24 \
  --disable-private-endpoint-network-policies true

# Private DNS zone linked to the AKS VNet
az network private-dns zone create -g "$RG" -n privatelink.file.core.windows.net
az network private-dns link vnet create -g "$RG" \
  -n privatelink-file-link \
  --zone-name privatelink.file.core.windows.net \
  --virtual-network "$VNET" \
  --registration-enabled false
```

The CSI driver, when provisioning via the NFS StorageClass, will create the
FileStorage account with public access disabled. You still need a private
endpoint per dynamically-created account, which the driver does **not** create
for you — pre-create a static storage account + share if you want NFS fully
automated, or accept the per-account PE step.

---

## 4. StorageClass options

This repo ships three StorageClasses, all MI-auth, all `reclaimPolicy: Delete`,
all `volumeBindingMode: Immediate`:

| File | StorageClass name | SKU | Protocol | Use case |
|---|---|---|---|---|
| `manifests/storageclass/azure-files-standard.yaml` | `acstor-azurefiles-standard` | Standard_LRS | SMB | Cost-sensitive RWX, dev/test, CI caches |
| `manifests/storageclass/azure-files-premium.yaml`  | `acstor-azurefiles-premium`  | Premium_LRS  | SMB | **Default for this demo** — low-latency RWX |
| `manifests/storageclass/azure-files-nfs.yaml`      | `acstor-azurefiles-nfs`      | Premium_LRS  | NFS 4.1 | Strict POSIX, Linux-only, requires VNet |

---

## 5. Deploy the workload

```bash
kubectl apply -f manifests/storageclass/azure-files-premium.yaml
kubectl apply -f manifests/workloads/nginx-shared.yaml
kubectl -n demo-files get pvc,pods
```

Expected:

```
NAME                                     STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS                AGE
persistentvolumeclaim/nginx-shared-pvc   Bound    pvc-...      100Gi      RWX            acstor-azurefiles-premium   30s

NAME                              READY   STATUS    RESTARTS   AGE
pod/nginx-shared-7c9b8df8-abc12   1/1     Running   0          25s
pod/nginx-shared-7c9b8df8-def34   1/1     Running   0          25s
pod/nginx-shared-7c9b8df8-ghi56   1/1     Running   0          25s
```

---

## 6. Verify all 3 pods share the same file

```bash
# Write from one pod (deploy/<name> picks an arbitrary pod)
kubectl exec -n demo-files deploy/nginx-shared -c nginx -- \
  sh -c 'echo "written by $(hostname)" > /usr/share/nginx/html/shared-test.txt'

# Read from every pod — same content expected
for pod in $(kubectl get pods -n demo-files -l app=nginx-shared -o name); do
  echo "--- $pod ---"
  kubectl exec -n demo-files $pod -- cat /usr/share/nginx/html/shared-test.txt
done
```

All three pods should print the same `written by <hostname>` line.

---

## 7. Multi-writer concurrency test

Each pod writes its own file; then read all files from a different pod:

```bash
# Each pod writes its own file
for pod in $(kubectl get pods -n demo-files -l app=nginx-shared -o name); do
  name=$(basename "$pod")
  kubectl exec -n demo-files "$pod" -- \
    sh -c "echo 'hello from $name @ \$(date -u +%FT%TZ)' > /usr/share/nginx/html/$name.txt"
done

# List + read all files from a single arbitrary pod
READER=$(kubectl get pods -n demo-files -l app=nginx-shared -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n demo-files "$READER" -- sh -c 'ls -la /usr/share/nginx/html/ && echo "---" && cat /usr/share/nginx/html/nginx-shared-*.txt'
```

You should see one file per pod, all readable from the reader pod. This proves
concurrent multi-writer + multi-reader semantics over SMB.

---

## 8. Snapshot (backup story)

Azure Files supports share-level snapshots out of band of Kubernetes. They are
fast (CoW at the share level) and crash-consistent.

```bash
# Discover the dynamically-created account + share (look at the PV)
PV=$(kubectl -n demo-files get pvc nginx-shared-pvc -o jsonpath='{.spec.volumeName}')
SHARE=$(kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeAttributes.shareName}')
ACCOUNT=$(kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeAttributes.storageAccount}')

# Take a snapshot (AAD auth, no keys)
az storage share snapshot \
  --name "$SHARE" \
  --account-name "$ACCOUNT" \
  --auth-mode login
```

For policy-driven backup, attach the storage account to an Azure Backup vault
with the **Azure Files share** workload type.

---

## 9. Failure scenarios (full detail in `docs/FAILURE-SCENARIOS.md`)

- **Standard tier throttling** — IOPS capped by tier; fix is to move to Premium or shard shares
- **SMB session drop / network blip** — kernel CIFS client reconnects automatically with `actimeo`/`nosharesock` mount opts; verify with a `dd` during a netpol blip
- **Pod eviction during write** — SMB: in-flight write may be partial; NFS: locked file may stay locked briefly
- **Quota exhaustion** — writes fail with `ENOSPC`; expand the share via `kubectl edit pvc`

---

## 10. Cleanup

```bash
kubectl delete -f manifests/workloads/nginx-shared.yaml
kubectl delete -f manifests/storageclass/azure-files-premium.yaml
# reclaimPolicy: Delete → the storage account + share are also torn down
```
