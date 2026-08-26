#!/usr/bin/env bash
# Set up the local_claude_code_kind_substrate_sandbox demo.
#
# Assumes the counter demo and sandbox demo are already deployed to a kind
# cluster (see README). This script does the demo-specific setup:
#   1. Scale the existing sandbox workerpool to 5 replicas.
#   2. Create the "claude-sandbox" atespace where per-session actors live.
#   3. Build the substrate-sandbox-hook binary to $INSTALL_DIR.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/bin}"
WORKERPOOL_REPLICAS="${WORKERPOOL_REPLICAS:-5}"
ATESPACE="${ATESPACE:-claude-sandbox}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Scaling sandbox-workerpool to ${WORKERPOOL_REPLICAS} replicas..."
kubectl -n ate-demo-sandbox scale workerpool/sandbox-workerpool \
  --replicas="${WORKERPOOL_REPLICAS}"

echo "==> Waiting for workerpool pods to be Ready..."
kubectl -n ate-demo-sandbox wait --for=condition=Ready pod \
  -l workload=sandbox --timeout=120s

echo "==> Creating atespace ${ATESPACE} (idempotent)..."
if ! kubectl ate create atespace "${ATESPACE}" 2>&1 | tee /tmp/ate-create.log; then
  if grep -q -i "already exists\|AlreadyExists" /tmp/ate-create.log; then
    echo "    (atespace already exists — that's fine)"
  else
    echo "    atespace create failed; see /tmp/ate-create.log" >&2
    exit 1
  fi
fi

echo "==> Building substrate-sandbox-hook to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
go build -o "${INSTALL_DIR}/substrate-sandbox-hook" "${SCRIPT_DIR}/hook"

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo ""
echo "  1. In two separate terminals, start port-forwards:"
echo ""
echo "       kubectl port-forward -n ate-system svc/api 8080:443"
echo "       kubectl port-forward -n ate-system svc/atenet-router 8000:80"
echo ""
echo "  2. Create a disposable scratch directory for your Claude session:"
echo ""
echo "       mkdir -p ~/tmp/claude-sandbox-scratch/.claude/skills"
echo ""
echo "  3. Copy the settings and skill into your scratch dir:"
echo ""
echo "       cp ${SCRIPT_DIR}/settings.json.example \\"
echo "          ~/tmp/claude-sandbox-scratch/.claude/settings.json"
echo "       cp -r ${SCRIPT_DIR}/skill \\"
echo "             ~/tmp/claude-sandbox-scratch/.claude/skills/substrate-sandbox"
echo ""
echo "  4. Start Claude Code from the scratch directory:"
echo ""
echo "       cd ~/tmp/claude-sandbox-scratch && claude"
echo ""
echo "  5. Ask Claude to do something that runs a shell command."
echo "     Watch the actor come up: kubectl ate get actors -a ${ATESPACE}"
