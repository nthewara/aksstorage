#!/usr/bin/env bash
# Validate the Azure Container Storage v2.1 lab (Cassandra on NVMe primary path).
# Exit non-zero on any check failure.

set -euo pipefail

NS_ACSTOR="${NS_ACSTOR:-kube-system}"
NS_CASS="${NS_CASS:-cassandra}"

c()   { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
bad() { printf '\033[1;31m✗ %s\033[0m\n' "$*"; exit 1; }

# ─── 1. kubectl context ───────────────────────────────────────────────────────
c "kubectl context"
kubectl config current-context
kubectl get nodes -o wide -L kubernetes.azure.com/agentpool

# ─── 2. ACStor namespace + pods ──────────────────────────────────────────────
c "Azure Container Storage namespace + pods"
kubectl get ns "$NS_ACSTOR" >/dev/null 2>&1 \
  || bad "namespace $NS_ACSTOR missing — is the ACStor extension installed?"
not_ready=$(kubectl -n "$NS_ACSTOR" get pods --no-headers 2>/dev/null \
  | awk '$3!="Running" && $3!="Completed"{print}' | wc -l | tr -d ' ')
[ "$not_ready" = "0" ] \
  && ok "all acstor pods Running" \
  || { kubectl -n "$NS_ACSTOR" get pods; bad "$not_ready acstor pods not Running"; }

# ─── 3. Expected StorageClasses ──────────────────────────────────────────────
c "StorageClasses"
EXPECTED_SCS=("local-nvme")
for sc in "${EXPECTED_SCS[@]}"; do
  kubectl get sc "$sc" >/dev/null 2>&1 \
    && ok "StorageClass $sc present" \
    || bad "StorageClass $sc missing — apply manifests/storageclass/"
done

# ─── 4. Cassandra StatefulSet readiness ──────────────────────────────────────
c "Cassandra StatefulSet"
if ! kubectl get ns "$NS_CASS" >/dev/null 2>&1; then
  echo "(cassandra namespace not deployed yet — skipping Cassandra checks)"
  SKIP_CASS=1
fi

if [ "${SKIP_CASS:-0}" != "1" ]; then
DESIRED=$(kubectl -n "$NS_CASS" get statefulset cassandra \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
READY=$(kubectl -n "$NS_CASS" get statefulset cassandra \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)

[ "${READY}" = "${DESIRED}" ] \
  && ok "Cassandra StatefulSet: ${READY}/${DESIRED} replicas ready" \
  || bad "Cassandra StatefulSet: only ${READY}/${DESIRED} replicas ready"

# ─── 5. nodetool status — expect 3 UN nodes ──────────────────────────────────
c "nodetool status (expect 3 UN)"
NODETOOL_OUT=$(kubectl -n "$NS_CASS" exec cassandra-0 -- nodetool status 2>/dev/null)
echo "$NODETOOL_OUT"
UN_COUNT=$(echo "$NODETOOL_OUT" | grep -c '^UN' || true)
[ "$UN_COUNT" -ge 3 ] \
  && ok "nodetool: $UN_COUNT UN (Up/Normal) nodes" \
  || bad "nodetool: only $UN_COUNT UN nodes (expected ≥ 3)"

# ─── 6. CQL write + read roundtrip ───────────────────────────────────────────
c "CQL write + read"
kubectl -n "$NS_CASS" exec cassandra-0 -- cqlsh -e "
  CREATE KEYSPACE IF NOT EXISTS validate
    WITH replication = {'class': 'NetworkTopologyStrategy', 'australiaeast': 3};
  USE validate;
  CREATE TABLE IF NOT EXISTS probe (id uuid PRIMARY KEY, ts timestamp, val text);
  INSERT INTO probe (id, ts, val) VALUES (uuid(), toTimestamp(now()), 'acstor-v2.1-ok');
  SELECT val FROM probe LIMIT 1;
" 2>&1 | tee /tmp/cql-out.txt
grep -q 'acstor-v2.1-ok' /tmp/cql-out.txt \
  && ok "CQL write+read roundtrip succeeded" \
  || bad "CQL roundtrip failed — check Cassandra logs"

# ─── 7. PVC check ────────────────────────────────────────────────────────────
c "PVC status"
kubectl -n "$NS_CASS" get pvc
BOUND=$(kubectl -n "$NS_CASS" get pvc --no-headers \
  | awk '$2=="Bound"{c++} END{print c+0}')
[ "$BOUND" -ge 3 ] \
  && ok "$BOUND PVCs Bound" \
  || bad "only $BOUND PVCs Bound (expected ≥ 3)"
fi  # end SKIP_CASS guard

# ─── 8. Azure Files (RWX) ────────────────────────────────────────────────────
c "=== Azure Files ==="
if kubectl get ns demo-files >/dev/null 2>&1; then
  PHASE=$(kubectl -n demo-files get pvc nginx-shared-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$PHASE" = "Bound" ]; then
    ok "PVC: Bound"
  else
    bad "PVC: NOT bound (phase=$PHASE)"
  fi

  kubectl -n demo-files rollout status deploy/nginx-shared --timeout=120s

  # Write from pod 0, read back from pod 1 and pod 2 to prove RWX
  POD0=$(kubectl get pods -n demo-files -l app=nginx-shared -o jsonpath='{.items[0].metadata.name}')
  POD1=$(kubectl get pods -n demo-files -l app=nginx-shared -o jsonpath='{.items[1].metadata.name}' 2>/dev/null || echo "")
  POD2=$(kubectl get pods -n demo-files -l app=nginx-shared -o jsonpath='{.items[2].metadata.name}' 2>/dev/null || echo "")

  kubectl exec -n demo-files "$POD0" -- sh -c 'echo "validate-$(date +%s)" > /usr/share/nginx/html/val.txt'

  if [ -n "$POD1" ] && kubectl exec -n demo-files "$POD1" -- cat /usr/share/nginx/html/val.txt 2>/dev/null | grep -q validate; then
    ok "RWX cross-pod read ($POD0 → $POD1) ✓"
  else
    bad "RWX cross-pod read failed ($POD0 → $POD1) ✗"
  fi

  if [ -n "$POD2" ]; then
    if kubectl exec -n demo-files "$POD2" -- cat /usr/share/nginx/html/val.txt 2>/dev/null | grep -q validate; then
      ok "RWX cross-pod read ($POD0 → $POD2) ✓"
    else
      bad "RWX cross-pod read failed ($POD0 → $POD2) ✗"
    fi
  fi
else
  echo "(demo-files namespace not deployed yet — skipping Azure Files checks)"
fi

# ─── 9. Premium SSD v2 (single-instance Postgres) ────────────────────────────
c "=== Premium SSD v2 ==="
if kubectl get sc premium-ssd-v2 >/dev/null 2>&1; then
  ok "StorageClass premium-ssd-v2 present"
else
  bad "StorageClass premium-ssd-v2 missing — apply manifests/storageclass/premium-ssd-v2.yaml"
fi

if kubectl get ns demo-pgv2 >/dev/null 2>&1; then
  # Wait briefly for STS
  kubectl -n demo-pgv2 rollout status statefulset/postgres-v2 --timeout=180s || true

  READY=$(kubectl -n demo-pgv2 get pod postgres-v2-0 \
    -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].ready}' 2>/dev/null || echo "false")
  if [ "$READY" = "true" ]; then
    ok "postgres-v2-0 Ready"
  else
    bad "postgres-v2-0 NOT Ready (got: $READY)"
  fi

  PVC_PHASE=$(kubectl -n demo-pgv2 get pvc pg-data-postgres-v2-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$PVC_PHASE" = "Bound" ]; then
    ok "PVC pg-data-postgres-v2-0: Bound"
  else
    bad "PVC pg-data-postgres-v2-0: phase=$PVC_PHASE (expected Bound)"
  fi

  # Quick psql roundtrip
  if kubectl -n demo-pgv2 exec postgres-v2-0 -- \
      psql -U demo -d demo -tAc 'SELECT 1;' 2>/dev/null | grep -q '^1$'; then
    ok "psql roundtrip (SELECT 1) succeeded"
  else
    bad "psql roundtrip failed — check postgres-v2 logs"
  fi
else
  echo "(demo-pgv2 namespace not deployed yet — skipping Postgres v2 checks)"
fi

# ─── 10. Premium SSD v1 ZRS (single-instance Postgres, cross-AZ) ────────────
c "=== Premium SSD v1 ZRS ==="
if kubectl get sc premium-ssd-zrs >/dev/null 2>&1; then
  ok "StorageClass premium-ssd-zrs present"
else
  bad "StorageClass premium-ssd-zrs missing — apply manifests/storageclass/premium-ssd-zrs.yaml"
fi

if kubectl get ns demo-pgzrs >/dev/null 2>&1; then
  kubectl -n demo-pgzrs rollout status statefulset/postgres-zrs --timeout=180s || true

  READY=$(kubectl -n demo-pgzrs get pod postgres-zrs-0 \
    -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].ready}' 2>/dev/null || echo "false")
  if [ "$READY" = "true" ]; then
    ok "postgres-zrs-0 Ready"
  else
    bad "postgres-zrs-0 NOT Ready (got: $READY)"
  fi

  PVC_PHASE=$(kubectl -n demo-pgzrs get pvc data-postgres-zrs-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$PVC_PHASE" = "Bound" ]; then
    ok "PVC data-postgres-zrs-0: Bound"
  else
    bad "PVC data-postgres-zrs-0: phase=$PVC_PHASE (expected Bound)"
  fi

  # Verify the backing disk is actually Premium_ZRS
  PV=$(kubectl -n demo-pgzrs get pvc data-postgres-zrs-0 -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
  if [ -n "$PV" ]; then
    SKU=$(kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeAttributes.skuName}' 2>/dev/null || echo "")
    if [ "$SKU" = "Premium_ZRS" ]; then
      ok "PV backed by Premium_ZRS SKU (cross-zone replicated)"
    else
      bad "PV SKU=$SKU (expected Premium_ZRS)"
    fi
  fi
else
  echo "(demo-pgzrs namespace not deployed yet — skipping Postgres ZRS checks)"
fi

c "Done."
ok "validation passed ✓"
