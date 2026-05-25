#!/usr/bin/env bash
# Validate the Azure Container Storage lab is healthy.
# Exit non-zero on any check failure.

set -euo pipefail

NS_ACSTOR="${NS_ACSTOR:-acstor}"
NS_DEMO="${NS_DEMO:-acstor-demo}"

c() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
bad() { printf '\033[1;31m✗ %s\033[0m\n' "$*"; exit 1; }

c "kubectl context"
kubectl config current-context
kubectl get nodes -o wide

c "Azure Container Storage namespace + pods"
kubectl get ns "$NS_ACSTOR" >/dev/null 2>&1 || bad "namespace $NS_ACSTOR missing — is the ACStor extension installed?"
not_ready=$(kubectl -n "$NS_ACSTOR" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print}' | wc -l | tr -d ' ')
[ "$not_ready" = "0" ] && ok "all acstor pods Running" || { kubectl -n "$NS_ACSTOR" get pods; bad "$not_ready acstor pods not Running"; }

c "Storage pools"
kubectl -n "$NS_ACSTOR" get storagepool.containerstorage.azure.com 2>/dev/null || echo "(no storagepool CRs yet)"

c "StorageClasses present"
kubectl get sc | grep -E 'acstor-' || bad "no acstor StorageClass found"
ok "acstor storage classes present"

c "Demo workload"
kubectl get ns "$NS_DEMO" >/dev/null 2>&1 || { echo "(demo namespace not deployed yet — skipping)"; exit 0; }
kubectl -n "$NS_DEMO" get pvc
kubectl -n "$NS_DEMO" get pods

bound=$(kubectl -n "$NS_DEMO" get pvc --no-headers | awk '$2=="Bound"{c++} END{print c+0}')
[ "$bound" -ge 1 ] && ok "$bound PVC(s) Bound" || bad "no Bound PVCs"

c "Postgres write/read"
if kubectl -n "$NS_DEMO" get statefulset postgres >/dev/null 2>&1; then
  kubectl -n "$NS_DEMO" exec postgres-0 -- psql -U postgres -c "CREATE TABLE IF NOT EXISTS t(x int); INSERT INTO t VALUES (1); SELECT count(*) FROM t;" \
    && ok "postgres I/O ok" || bad "postgres I/O failed"
fi

c "Done."
ok "validation passed"
