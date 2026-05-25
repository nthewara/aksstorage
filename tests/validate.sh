#!/usr/bin/env bash
# Validate the Azure Container Storage v2.1 lab (Cassandra on NVMe primary path).
# Exit non-zero on any check failure.

set -euo pipefail

NS_ACSTOR="${NS_ACSTOR:-acstor}"
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

c "Done."
ok "validation passed ✓"
