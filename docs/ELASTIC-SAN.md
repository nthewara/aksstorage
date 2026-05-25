# Elastic SAN Scenario — Azure Container Storage v2.1

This guide walks through deploying Elastic SAN as a storage backend for AKS via
Azure Container Storage v2.1. ESAN is ideal for high-density PV scenarios where
hundreds of volumes need to be provisioned without hitting VM disk-attach limits.

---

## Prerequisites

- ACS v2.1 lab deployed (`docs/LAB.md §1-2`)
- `elastic-san` extension: `az extension add --upgrade --name elastic-san`
- ESAN provider registered: `az provider register --namespace Microsoft.ElasticSan`

---

## 1. Deploy the Elastic SAN module

The `infra/modules/elasticsan.bicep` module is toggled by the `deployElasticSan` param:

```bash
RG=rg-acstor-lab
az deployment group create \
  -g "$RG" \
  -f infra/main.bicep \
  -p @infra/main.parameters.json \
  -p deployElasticSan=true esanBaseSizeTiB=1
```

This creates:
- Elastic SAN `esan-<nameBase>` (1 TiB base → 5,000 IOPS, 200 MB/s throughput)
- Volume group `vg-acstor`
- RBAC: kubelet identity → `Elastic SAN Volume Group Owner` on the VG
- RBAC: kubelet identity → `Azure Container Storage Operator` on subscription

Capture outputs:

```bash
ESAN_ID=$(az deployment group show -g "$RG" -n main \
  --query properties.outputs.esanId.value -o tsv)
VG_NAME=$(az deployment group show -g "$RG" -n main \
  --query properties.outputs.esanVolumeGroupName.value -o tsv)
echo "ESAN_ID=$ESAN_ID  VG=$VG_NAME"
```

---

## 2. Enable ESAN storage type on the cluster

```bash
CLUSTER=$(az aks list -g "$RG" --query '[0].name' -o tsv)

az aks update -g "$RG" -n "$CLUSTER" \
  --enable-azure-container-storage elasticSan \
  --elastic-san-resource-id "$ESAN_ID"
```

Wait ~5 minutes. Verify:

```bash
kubectl get deploy -n kube-system | grep acstor
kubectl get pod  -n kube-system | grep -E 'acstor|san-csi'
kubectl get sc | grep san
```

---

## 3. Apply the Elastic SAN StorageClass

```bash
kubectl apply -f manifests/storageclass/elastic-san.yaml
kubectl get sc azuresan-csi
```

---

## 4. Provision many PVCs (demonstrate no disk-attach limit)

Unlike Azure Disk (max 64 per VM), ESAN uses iSCSI — no disk-attach ceiling.
Provision 20 PVCs in a loop to demonstrate:

```bash
for i in $(seq 1 20); do
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: esan-pvc-$i
  namespace: acstor-demo
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: azuresan-csi
  resources:
    requests:
      storage: 4Gi
EOF
done

# Wait for all to bind
kubectl -n acstor-demo get pvc | grep esan-pvc
```

All 20 should reach `Bound` status within ~60 seconds.

---

## 5. Deploy a Postgres workload using ESAN

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-esan
  namespace: acstor-demo
spec:
  serviceName: postgres-esan
  replicas: 1
  selector:
    matchLabels:
      app: postgres-esan
  template:
    metadata:
      labels:
        app: postgres-esan
    spec:
      containers:
        - name: postgres
          image: mcr.microsoft.com/cbl-mariner/base/postgres:14
          env:
            - name: POSTGRES_PASSWORD
              value: "esan-demo-only"
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: [pg_isready, -U, postgres]
            initialDelaySeconds: 10
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: azuresan-csi
        resources:
          requests:
            storage: 20Gi
EOF

kubectl -n acstor-demo wait --for=condition=ready pod/postgres-esan-0 --timeout=120s
kubectl -n acstor-demo exec postgres-esan-0 -- psql -U postgres -c \
  "CREATE TABLE IF NOT EXISTS t(x int); INSERT INTO t VALUES (1); SELECT count(*) FROM t;"
```

---

## 6. ESAN sizing guidance

Each 1 TiB of base capacity adds:
- **+5,000 IOPS**
- **+200 MB/s throughput**

For a 5 TiB ESAN: 25,000 IOPS, 1 GB/s throughput — shared across all volumes.
Use the [ESAN pricing calculator](https://azure.microsoft.com/pricing/calculator/) for cost estimates.

---

## 7. Cleanup ESAN resources

```bash
# Delete all ESAN PVCs first
kubectl -n acstor-demo delete pvc -l app=postgres-esan
for i in $(seq 1 20); do kubectl -n acstor-demo delete pvc esan-pvc-$i 2>/dev/null || true; done

# Disable ESAN storage type
az aks update -g "$RG" -n "$CLUSTER" --disable-azure-container-storage elasticSan

# Destroy the ESAN (billed until deleted)
az deployment group delete -g "$RG" -n elasticsan 2>/dev/null || true
# Or delete the ESAN resource directly:
az elastic-san delete --ids "$ESAN_ID" --yes
```
