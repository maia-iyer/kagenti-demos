#!/usr/bin/env bash
# Tear down the demo-specific resources created by setup.sh.
#
# Does NOT touch the MOCA install or the kind cluster. Those are
# prerequisites, not owned by this demo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/ctx.sh
source "${SCRIPT_DIR}/lib/ctx.sh"

MOCA_NS="${MOCA_NS:-moca-system}"
MOCA_PORT="${MOCA_PORT:-8080}"
MOCA_URL="${MOCA_URL:-http://localhost:${MOCA_PORT}}"
CTX_LOCAL="${CTX_LOCAL:-moca-chained-fixture-local}"
CTX_REMOTE="${CTX_REMOTE:-moca-chained-fixture-remote}"
WORKLOAD_A="${WORKLOAD_A:-workload-a}"
WORKLOAD_B="${WORKLOAD_B:-workload-b}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"

echo "==> Deleting MOCA workloads..."
for w in "${WORKLOAD_A}" "${WORKLOAD_B}"; do
  if curl -sS -o /dev/null -w '%{http_code}' \
       -X DELETE "${MOCA_URL}/workloads/${w}" | grep -qE '^(200|202|204|404)$'; then
    echo "    deleted (or absent): ${w}"
  else
    echo "    DELETE ${w} returned non-success; check MOCA state manually" >&2
  fi
done

echo "==> Removing workspace contexts..."
ctx_delete_remote "${CTX_REMOTE}" "${MOCA_NS}" || \
  echo "    (remote context already absent or delete failed)"
ctx_delete_local "${CTX_LOCAL}" || \
  echo "    (local context already absent or delete failed)"

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
echo "Not touched by this script (deliberately — they're prerequisites):"
echo "  - MOCA install in namespace ${MOCA_NS}"
echo "  - the kind cluster"
echo ""
echo "If a 'kubectl port-forward' is still running for MOCA, Ctrl-C it."
