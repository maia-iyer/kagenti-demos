#!/usr/bin/env bash
# Tear down the demo-specific resources created by setup.sh.
#
# Does NOT touch the kind cluster, Substrate, the counter demo, or the sandbox
# demo — those were prerequisites, not owned by this demo.

set -euo pipefail

ATESPACE="${ATESPACE:-claude-sandbox}"
WORKERPOOL_REPLICAS_RESTORE="${WORKERPOOL_REPLICAS_RESTORE:-2}"

echo "==> Deleting all sess-* actors in atespace ${ATESPACE}..."
actors="$(kubectl ate get actors -a "${ATESPACE}" -o name 2>/dev/null | grep '^sess-' || true)"
if [[ -z "${actors}" ]]; then
  echo "    (no sess-* actors found)"
else
  echo "${actors}" | while read -r a; do
    echo "    deleting ${a}"
    kubectl ate delete actor "${a}" -a "${ATESPACE}" || true
  done
fi

echo "==> Scaling sandbox-workerpool back to ${WORKERPOOL_REPLICAS_RESTORE} replicas..."
kubectl -n ate-demo-sandbox scale workerpool/sandbox-workerpool \
  --replicas="${WORKERPOOL_REPLICAS_RESTORE}"

echo ""
echo "Teardown complete."
echo ""
echo "Not removed by this script (deliberately — they may be shared):"
echo "  - atespace ${ATESPACE}   (delete with: kubectl ate delete atespace ${ATESPACE})"
echo "  - substrate-sandbox-hook binary in \$INSTALL_DIR"
echo "  - your scratch directory (delete manually when done)"
