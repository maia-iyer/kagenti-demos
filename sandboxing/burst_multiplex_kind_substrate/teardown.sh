#!/usr/bin/env bash
# Tear down the demo-specific resources created by setup.sh (and crank.sh).
#
# Default mode: leaves the `burst` atespace and the upstream
# autoscaled-workerpool demo in place (they may be shared with other demos).
#
# FULL_TEARDOWN=1 mode: additionally deletes the atespace and the
# autoscaled-workerpool namespace, leaving only a clean Substrate install on
# the kind cluster. Use this when this demo owns the whole substrate setup.

set -euo pipefail

ATESPACE="${ATESPACE:-burst}"
NUM_ACTORS="${NUM_ACTORS:-300}"
DELETE_PARALLELISM="${DELETE_PARALLELISM:-20}"
POOL_NS="ate-demo-autoscaled-workerpool"
POOL="counter"
HPA_MIN_RESTORE="${HPA_MIN_RESTORE:-1}"
HPA_MAX_RESTORE="${HPA_MAX_RESTORE:-10}"
FULL_TEARDOWN="${FULL_TEARDOWN:-0}"

echo "==> Deleting up to ${NUM_ACTORS} b* actors from atespace ${ATESPACE}..."
seq -w 1 "${NUM_ACTORS}" | xargs -n1 -P"${DELETE_PARALLELISM}" -I{} bash -c '
  name="b$1"
  kubectl ate delete actor "$name" -a "$2" >/dev/null 2>&1 || true
' _ {} "${ATESPACE}"

echo "==> Sweeping leftover req-* actors from atespace ${ATESPACE} (from create runs)..."
# create-mode requests leave behind `req-<epoch-ns>-<i>` actors if a run was
# Ctrl+C'd before its per-request delete landed. List and delete all matches.
LEFTOVER=$(kubectl ate get actors -a "${ATESPACE}" 2>/dev/null \
  | awk 'NR>1 && $1 ~ /^req-/ {print $1}')
if [[ -n "${LEFTOVER}" ]]; then
  echo "${LEFTOVER}" | xargs -n1 -P"${DELETE_PARALLELISM}" -I{} bash -c '
    kubectl ate delete actor "$1" -a "$2" >/dev/null 2>&1 || true
  ' _ {} "${ATESPACE}"
fi

echo "==> Deleting fast ActorTemplate ${POOL_NS}/counter-fast (if present)..."
kubectl -n "${POOL_NS}" delete actortemplate counter-fast --ignore-not-found

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

if [[ "${FULL_TEARDOWN}" == "1" ]]; then
  echo "==> FULL_TEARDOWN=1: deleting atespace ${ATESPACE}..."
  kubectl ate delete atespace "${ATESPACE}" >/dev/null 2>&1 || true

  echo "==> FULL_TEARDOWN=1: deleting autoscaled-workerpool demo (namespace ${POOL_NS})..."
  # Remove workload objects first so their finalizers don't stall the namespace
  # delete. Ignore-not-found makes each step idempotent.
  kubectl -n "${POOL_NS}" delete hpa "${POOL}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${POOL_NS}" delete workerpool "${POOL}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${POOL_NS}" delete actortemplate --all --ignore-not-found >/dev/null 2>&1 || true
  # Finally the namespace itself (this also removes prometheus-adapter bits
  # that ship with the upstream demo).
  kubectl delete namespace "${POOL_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  echo ""
  echo "Full teardown complete. Substrate itself (ate-system) is untouched."
  echo ""
  echo "If you want to reset Substrate too, from your substrate/ checkout:"
  echo "    ./hack/install-ate-kind.sh --delete-ate-system"
else
  echo ""
  echo "Teardown complete (partial — demo-specific state only)."
  echo ""
  echo "Not removed by this script (may be shared with other demos):"
  echo "  - atespace ${ATESPACE}"
  echo "  - the autoscaled-workerpool demo (namespace ${POOL_NS})"
  echo ""
  echo "For a full teardown that leaves only a clean Substrate install:"
  echo "    FULL_TEARDOWN=1 ./teardown.sh"
fi
