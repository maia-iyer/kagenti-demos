#!/usr/bin/env bash
# Undo prereqs-install.sh:
#   1. Run the demo's own teardown.sh (leaf sessions, bundles, scratch dir)
#      while the cluster is still up.
#   2. Kill the three backgrounded port-forwards (matched by argv on
#      `kubectl --context kind-moca ... port-forward`).
#   3. Delete the kind cluster `moca` — one call wipes MOCA, Context
#      Service, loaded images, the CoreDNS patch, and all namespaces.
#
# Does NOT touch:
#   - mocactl login + stored credentials (~/.config/mocactl)
#   - the moca/ and context-service/ source checkouts under CLONE_DIR
#   - the port-forward log directory (~/.local/state/moca-chained-demo/)

set -euo pipefail

KIND_CLUSTER="${KIND_CLUSTER:-moca}"
KUBE_CONTEXT="kind-${KIND_CLUSTER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Demo-level teardown first — needs the cluster/port-forwards to delete
#    leaf sessions and config bundles cleanly. Idempotent; a missing scratch
#    dir just means there is nothing to clean. Keep going on non-zero exit:
#    uninstalling the cluster is still the right move.
if [[ -x "${SCRIPT_DIR}/teardown.sh" ]]; then
  echo "==> Running demo teardown.sh..."
  "${SCRIPT_DIR}/teardown.sh" || echo "    (teardown.sh exited non-zero; continuing)" >&2
fi

# 2. Kill port-forwards against this cluster. Match on the full argv —
#    do NOT simplify to `pkill kubectl` or you will nuke unrelated
#    port-forwards on the machine.
echo "==> Killing port-forwards against ${KUBE_CONTEXT}..."
if pkill -f "kubectl --context ${KUBE_CONTEXT} .* port-forward" 2>/dev/null; then
  echo "    killed"
else
  echo "    (none running)"
fi

# 3. Delete the kind cluster. One call removes MOCA, Context Service,
#    the loaded images, the CoreDNS patch, and all namespaces.
echo "==> Deleting kind cluster ${KIND_CLUSTER}..."
if kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER}"; then
  kind delete cluster --name "${KIND_CLUSTER}"
else
  echo "    (cluster already gone)"
fi

cat <<EOF

Uninstall complete.

Not touched (deliberately — they are yours):
  - mocactl login and stored credentials (~/.config/mocactl)
  - the moca/ and context-service/ source checkouts under CLONE_DIR
  - port-forward logs (~/.local/state/moca-chained-demo/)
EOF
