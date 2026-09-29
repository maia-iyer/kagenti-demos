#!/usr/bin/env bash
# Tear down the demo-specific resources created by setup.sh (and crank.sh).
#
# Does NOT touch the kind cluster, Substrate, or the autoscaled-workerpool
# demo itself — those were prerequisites, not owned by this demo.

set -euo pipefail

ATESPACE="${ATESPACE:-burst}"
NUM_ACTORS="${NUM_ACTORS:-300}"
DELETE_PARALLELISM="${DELETE_PARALLELISM:-20}"
POOL_NS="ate-demo-autoscaled-workerpool"
POOL="counter"
HPA_MIN_RESTORE="${HPA_MIN_RESTORE:-1}"
HPA_MAX_RESTORE="${HPA_MAX_RESTORE:-10}"

echo "==> Deleting up to ${NUM_ACTORS} b* actors from atespace ${ATESPACE}..."
seq -w 1 "${NUM_ACTORS}" | xargs -n1 -P"${DELETE_PARALLELISM}" -I{} bash -c '
  name="b$1"
  kubectl ate delete actor "$name" -a "$2" >/dev/null 2>&1 || true
' _ {} "${ATESPACE}"

echo "==> Restoring HPA counter bounds to min=${HPA_MIN_RESTORE}, max=${HPA_MAX_RESTORE}..."
kubectl -n "${POOL_NS}" patch hpa "${POOL}" --type=merge \
  -p "{\"spec\":{\"minReplicas\":${HPA_MIN_RESTORE},\"maxReplicas\":${HPA_MAX_RESTORE}}}" \
  >/dev/null || true

echo "==> Stripping any --parked-request-budget arg added by crank.sh..."
NS="ate-system"
DEP="atenet-router"
CONTAINER="atenet-router"
ARGS_JSON=$(kubectl -n "${NS}" get deploy "${DEP}" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].args}" 2>/dev/null || echo "[]")
if echo "${ARGS_JSON}" | jq -e 'any(startswith("--parked-request-budget="))' >/dev/null 2>&1; then
  NEW_ARGS=$(printf '%s\n' "${ARGS_JSON}" | jq -c \
    '[.[] | select(startswith("--parked-request-budget=") | not)]')
  kubectl -n "${NS}" patch deploy "${DEP}" --type=json -p "$(jq -n \
    --argjson args "${NEW_ARGS}" \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":$args}]')" \
    >/dev/null
  kubectl -n "${NS}" rollout status deploy/"${DEP}" --timeout=120s
else
  echo "    (no crank patch present — nothing to undo)"
fi

echo ""
echo "Teardown complete."
echo ""
echo "Not removed by this script (deliberately — they may be shared):"
echo "  - atespace ${ATESPACE}   (delete with: kubectl ate delete atespace ${ATESPACE})"
echo "  - the autoscaled-workerpool demo itself (delete from substrate/: "
echo "    ./hack/install-ate-kind.sh --delete-demo-autoscaled-workerpool)"
