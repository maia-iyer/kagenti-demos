#!/usr/bin/env bash
# Print paste-ready commands for watching the demo in three or four terminals.
#
# No tmux dependency — just prints what to paste. Assumes the atenet-router
# port-forwards described in setup.sh's footer are already running:
#
#   kubectl port-forward -n ate-system svc/atenet-router 8000:80
#   kubectl port-forward -n ate-system svc/atenet-router 4041:4040

set -euo pipefail

ATESPACE="${ATESPACE:-burst}"
POOL_NS="ate-demo-autoscaled-workerpool"
POOL="counter"

cat <<EOF
# Pane 1 — worker pool and pods (should stay at 3 replicas):

watch -n2 'kubectl -n ${POOL_NS} get workerpool,pods'

# Pane 2 — actor states (multiplexing: substrate cycles Running <-> Suspended
#          so 300 actors fit through 3 workers). Head to keep the pane short:

watch -n2 'kubectl ate get actors -a ${ATESPACE} | head -30'

# Pane 3 — assigned-workers gauge (multiplex proof: stays near POOL_REPLICAS,
#          not NUM_ACTORS). Reads the external metric served by
#          prometheus-adapter from the upstream demo:

watch -n2 "kubectl get --raw '/apis/external.metrics.k8s.io/v1beta1/namespaces/${POOL_NS}/ate_workerpool_workers?labelSelector=ate_worker_state%3Dassigned,ate_workerpool_namespace%3D${POOL_NS},ate_workerpool_name%3D${POOL}' | jq -r '.items[0].value'"

# Pane 4 — parking gauge (parking proof: spikes during a burst, drains after).
#          Reads the atenet-router's live /statusz snapshot on the status port.
#          Fields: enabled, active (currently parked), max_parked, max_wait.

watch -n1 "curl -s 'http://localhost:4041/statusz?format=json' | jq .parking"
EOF
