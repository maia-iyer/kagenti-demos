#!/usr/bin/env bash
# Optional: raise the atenet-router's --parked-request-budget from the default
# 5s to something longer, so a burst against 300 actors on 3 workers doesn't
# shed requests. The demo works without this — parking is on by default — but
# on a slow laptop the resume queue can outrun the 5s budget.
#
# Idempotent: re-running with the same BUDGET just replaces the arg. Undone by
# teardown.sh (which strips any --parked-request-budget arg this script added).

set -euo pipefail

BUDGET="${BUDGET:-30s}"
NS="ate-system"
DEP="atenet-router"
CONTAINER="atenet-router"

echo "==> Reading current args on ${NS}/${DEP} container ${CONTAINER}..."
ARGS_JSON=$(kubectl -n "${NS}" get deploy "${DEP}" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].args}")

# Strip any existing --parked-request-budget=... arg, then append the new one.
NEW_ARGS=$(printf '%s\n' "${ARGS_JSON}" | jq -c \
  --arg budget "--parked-request-budget=${BUDGET}" \
  '[.[] | select(startswith("--parked-request-budget=") | not)] + [$budget]')

echo "==> Patching --parked-request-budget=${BUDGET}..."
kubectl -n "${NS}" patch deploy "${DEP}" --type=json -p "$(jq -n \
  --argjson args "${NEW_ARGS}" \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":$args}]')"

echo "==> Waiting for rollout..."
kubectl -n "${NS}" rollout status deploy/"${DEP}" --timeout=120s

echo ""
echo "Router now runs with --parked-request-budget=${BUDGET}."
echo "Undo with ./teardown.sh (which also cleans up actors and HPA bounds)."
