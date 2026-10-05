#!/usr/bin/env bash
# Tear down the demo-specific resources created by setup.sh.
#
# Does NOT touch the MOCA install or the kind cluster. Those are
# prerequisites, not owned by this demo.

set -euo pipefail

MOCA_NS="${MOCA_NS:-default}"
SANDBOX_POD="${SANDBOX_POD:-sandbox-0}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"

echo "==> Removing seeded fixture from ${SANDBOX_POD}:/workspace..."
if kubectl -n "${MOCA_NS}" get pod "${SANDBOX_POD}" >/dev/null 2>&1; then
  # Wipe every review-* run dir this demo may have created. Harmless if none exist.
  kubectl -n "${MOCA_NS}" exec "${SANDBOX_POD}" -- sh -c \
    'rm -rf /workspace/review-* 2>/dev/null; true' || true
  echo "    cleaned"
else
  echo "    (${SANDBOX_POD} not present; nothing to clean)"
fi

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
echo "  - the Kourier port-forward (Ctrl-C it in its terminal if still running)"
