#!/usr/bin/env bash
# Tear down the demo-specific resources created by setup.sh.
#
# Does NOT touch the MOCA install, Context Service, or the kind cluster.
# Those are prerequisites, not owned by this demo. Your mocactl login and
# stored credentials are also yours — not touched.
#
# Run this AFTER collecting every leaf you care about: deleting a session
# makes its stored result unreachable, so any uncollected answer is lost.

set -euo pipefail

MOCA_NS="${MOCA_NS:-moca}"
HARNESS_PORT="${HARNESS_PORT:-8080}"
CP_PORT="${CP_PORT:-8090}"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:${HARNESS_PORT}}"
CP_URL="${CP_URL:-http://127.0.0.1:${CP_PORT}}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"
MOCA_MD="${SCRATCH_DIR}/MOCA.md"

# mocactl needs the port-forwards to list sessions, delete sessions, and
# delete the workload.
export SH_CONTROL_PLANE_URL="${CP_URL}"
export SH_HARNESS_URL="${HARNESS_URL}"

echo "==> Collecting this demo's leaf sessions..."
# The demo tag (written to MOCA.md by setup.sh) scopes the machine-global
# mocactl subagent ledger to this run.
TAG=""
WORKLOAD_ID=""
DIGEST_PUBLIC=""
DIGEST_FULL=""
if [[ -f "${MOCA_MD}" ]]; then
  TAG="$(grep -E '^Demo tag:' "${MOCA_MD}" 2>/dev/null \
    | sed -E 's/^Demo tag:[[:space:]]+//' | head -1 || true)"
  WORKLOAD_ID="$(grep -E '^Workload id:' "${MOCA_MD}" 2>/dev/null \
    | sed -E 's/^Workload id:[[:space:]]+//' | head -1 || true)"
  DIGEST_PUBLIC="$(grep -E '^Config digest public:' "${MOCA_MD}" 2>/dev/null \
    | sed -E 's/^Config digest public:[[:space:]]+//' | head -1 || true)"
  DIGEST_FULL="$(grep -E '^Config digest full:' "${MOCA_MD}" 2>/dev/null \
    | sed -E 's/^Config digest full:[[:space:]]+//' | head -1 || true)"
fi

SESSION_IDS=""
if [[ -n "${TAG}" ]] && command -v mocactl >/dev/null 2>&1; then
  if listing="$(mocactl subagents --tag "${TAG}" --json 2>/dev/null)"; then
    SESSION_IDS="$(printf '%s' "${listing}" \
      | jq -r '.subagents[]?.sessionId' 2>/dev/null || true)"
  else
    echo "    (mocactl could not list the tag's subagents — port-forward down?)" >&2
  fi
fi
# Union with the parent's per-leaf notes in the scratch dir, so teardown
# still works when mocactl cannot reach the cluster.
if [[ -d "${SCRATCH_DIR}/leaves" ]]; then
  for note in "${SCRATCH_DIR}"/leaves/*.json; do
    [[ -e "${note}" ]] || continue
    sid="$(jq -r '.sessionId // empty' "${note}" 2>/dev/null || true)"
    if [[ -n "${sid}" ]]; then
      SESSION_IDS="$(printf '%s\n%s' "${SESSION_IDS}" "${sid}")"
    fi
  done
fi
SESSION_IDS="$(printf '%s\n' "${SESSION_IDS}" | sed '/^$/d' | sort -u)"

if [[ -z "${SESSION_IDS}" ]]; then
  echo "    (no leaf sessions found for this demo; nothing to delete)"
else
  for sid in ${SESSION_IDS}; do
    if mocactl sessions delete "${sid}" >/dev/null 2>&1; then
      echo "    deleted session ${sid}"
    else
      echo "    could not delete session ${sid} (already gone?)" >&2
      echo "      delete it later with:  mocactl sessions delete ${sid}" >&2
    fi
  done
fi

echo "==> Deleting the workload..."
# The workload's shared read-only cache and any per-run writable copies are
# released by DELETE /workloads/{id}. Writable per-run copies are already
# discarded when their runs end (nothing persists across runs in phase 1).
if [[ -z "${WORKLOAD_ID}" ]]; then
  echo "    (no workload id in MOCA.md; nothing to delete)"
else
  if mocactl workloads delete "${WORKLOAD_ID}" >/dev/null 2>&1; then
    echo "    deleted workload ${WORKLOAD_ID}"
  else
    echo "    could not delete workload ${WORKLOAD_ID} (already gone?)" >&2
    echo "      delete it later with:  mocactl workloads delete ${WORKLOAD_ID}" >&2
  fi
fi

echo "==> Deleting the config bundles..."
# Config bundles promoted at setup time; delete them to free the budget.
delete_bundle() {
  local digest="$1"
  local label="$2"
  if [[ -z "${digest}" ]]; then
    echo "    (no ${label} digest in MOCA.md; nothing to delete)"
    return
  fi
  if mocactl bundles delete "${digest}" >/dev/null 2>&1; then
    echo "    deleted ${label}  ${digest}"
  else
    echo "    could not delete ${label}  ${digest} (already gone?)" >&2
    echo "      delete it later with:  mocactl bundles delete ${digest}" >&2
  fi
}
delete_bundle "${DIGEST_PUBLIC}" public-only
delete_bundle "${DIGEST_FULL}"   full

echo "==> Removing scratch directory ${SCRATCH_DIR}..."
if [[ -d "${SCRATCH_DIR}" ]]; then
  rm -rf "${SCRATCH_DIR}"
  echo "    removed"
else
  echo "    (already absent)"
fi

echo ""
echo "Teardown complete."
echo ""
echo "Not touched by this script (deliberately — they're prerequisites or yours):"
echo "  - MOCA install in namespace ${MOCA_NS}"
echo "  - Context Service install"
echo "  - the kind cluster"
echo "  - your mocactl login and stored credentials"
echo "  - the machine-global subagent ledger (~/.local/state/mocactl/subagents.jsonl)"
echo "    — its rows age out on their own; only the sessions were deleted above"
echo "  - the two port-forwards (Ctrl-C them in their terminals if still running)"
