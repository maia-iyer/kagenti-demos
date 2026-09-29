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
# Pane 1 — worker states (multiplexing: 3 workers cycle FREE <-> ASSIGNED as
#          substrate rotates actors through them):

watch -n1 'kubectl ate get workers -n ${POOL_NS}'

# Pane 2 — parking gauge (parking proof: spikes during a burst, drains after).
#          Reads the atenet-router's live /statusz snapshot on the status port.
#          Fields: enabled, active (currently parked), max_parked, max_wait.

watch -n1 "curl -s 'http://localhost:4041/statusz?format=json' | jq .parking"
EOF
