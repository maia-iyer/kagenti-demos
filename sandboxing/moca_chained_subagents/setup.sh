#!/usr/bin/env bash
# Set up the moca_chained_subagents demo.
#
# Assumes MOCA (rossoctl/moca) is already installed on the current kubectl
# context via its quick-start (deploy/knative/setup-kind.sh), and the KEDA
# ScaledJob for leaf workers has been applied. This script does the
# demo-specific setup:
#   1. Seed example_repo/ into sandbox-0:/workspace/$RUN/repo via kubectl cp.
#   2. Stage settings and skill into a scratch directory for a Claude session.
#   3. Record the base URL, Host header, and workspaceRef the skill needs.
#
# This script does NOT stand up MOCA. See the demo README prerequisites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MOCA_NS="${MOCA_NS:-default}"
MOCA_PORT="${MOCA_PORT:-8080}"
MOCA_BASE="${MOCA_BASE:-http://localhost:${MOCA_PORT}}"
MOCA_HOST="${MOCA_HOST:-serverless-harness.default.example.com}"
SANDBOX_POD="${SANDBOX_POD:-sandbox-0}"
SCALEDJOB_NAME="${SCALEDJOB_NAME:-leaf-worker}"
RUN_ID="${RUN_ID:-review-$(date +%s)}"
WORKSPACE_REF="${WORKSPACE_REF:-/workspace/${RUN_ID}/repo}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"

echo "==> Prerequisite checks..."

for bin in kubectl curl jq; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "    missing required binary: ${bin}" >&2
    exit 1
  fi
done

if ! kubectl get ns "${MOCA_NS}" >/dev/null 2>&1; then
  echo "    namespace '${MOCA_NS}' not found on current kubectl context." >&2
  echo "    Install MOCA via its quick-start first:" >&2
  echo "      https://github.com/rossoctl/moca#quick-start" >&2
  exit 1
fi

if ! kubectl -n "${MOCA_NS}" get pod "${SANDBOX_POD}" >/dev/null 2>&1; then
  echo "    sandbox pod '${SANDBOX_POD}' not found in '${MOCA_NS}'." >&2
  echo "    Did the MOCA quick-start finish? See:" >&2
  echo "      https://github.com/rossoctl/moca#quick-start" >&2
  exit 1
fi

if ! kubectl get scaledjob "${SCALEDJOB_NAME}" -n "${MOCA_NS}" >/dev/null 2>&1; then
  echo "    KEDA ScaledJob '${SCALEDJOB_NAME}' not found." >&2
  echo "    Apply it from the MOCA repo before continuing:" >&2
  echo "      kubectl apply -f deploy/knative/leaf-scaledjob.yaml" >&2
  echo "    (Without it, POST /runs is accepted but no worker ever starts.)" >&2
  exit 1
fi

echo "    ok: kubectl, curl, jq on PATH"
echo "    ok: namespace ${MOCA_NS} exists"
echo "    ok: pod ${SANDBOX_POD} present in ${MOCA_NS}"
echo "    ok: ScaledJob ${SCALEDJOB_NAME} present"

echo "==> Checking MOCA is reachable at ${MOCA_BASE} (Host: ${MOCA_HOST})..."
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
             -H "Host: ${MOCA_HOST}" "${MOCA_BASE}/healthz" || echo "000")"
if ! echo "${HTTP_CODE}" | grep -qE '^(200|204|404)$'; then
  echo "    cannot reach MOCA at ${MOCA_BASE} (got HTTP ${HTTP_CODE})." >&2
  echo "    Start the Kourier port-forward in another terminal:" >&2
  echo "      kubectl port-forward -n kourier-system svc/kourier ${MOCA_PORT}:80" >&2
  exit 1
fi
echo "    ok: MOCA reachable (HTTP ${HTTP_CODE})"

echo "==> Waiting for ${SANDBOX_POD} to be Ready..."
kubectl -n "${MOCA_NS}" wait --for=condition=Ready "pod/${SANDBOX_POD}" --timeout=90s >/dev/null
echo "    ok"

echo "==> Seeding example_repo/ into ${SANDBOX_POD}:${WORKSPACE_REF}..."
kubectl -n "${MOCA_NS}" exec "${SANDBOX_POD}" -- sh -c "mkdir -p '${WORKSPACE_REF}'"
kubectl -n "${MOCA_NS}" exec "${SANDBOX_POD}" -- sh -c "rm -rf '${WORKSPACE_REF}'/* '${WORKSPACE_REF}'/.[!.]* 2>/dev/null; true"
kubectl -n "${MOCA_NS}" cp "${SCRIPT_DIR}/example_repo/." "${SANDBOX_POD}:${WORKSPACE_REF}"
echo "    ok"

echo "==> Staging scratch dir at ${SCRATCH_DIR}..."

mkdir -p "${SCRATCH_DIR}/.claude/skills"
mkdir -p "${SCRATCH_DIR}/.moca-runs"
cp "${SCRIPT_DIR}/settings.json.example" \
   "${SCRATCH_DIR}/.claude/settings.json"
cp -r "${SCRIPT_DIR}/skill" \
      "${SCRATCH_DIR}/.claude/skills/moca-dispatch"

cat > "${SCRATCH_DIR}/MOCA.md" <<EOF
# MOCA settings for this scratch session

Base URL:      ${MOCA_BASE}
Host header:   ${MOCA_HOST}
workspaceRef:  ${WORKSPACE_REF}
Run id:        ${RUN_ID}

The fixture (example_repo/) has been seeded into ${SANDBOX_POD}:${WORKSPACE_REF}
in namespace ${MOCA_NS}. Every curl to MOCA must send:

  -H "Host: ${MOCA_HOST}"

Dispatch is async: POST ${MOCA_BASE}/runs starts a leaf and returns a handle;
GET ${MOCA_BASE}/runs/status?sessionId=<id> returns the result when done.
Run records live in .moca-runs/ — see the moca-dispatch skill.

Session-id scheme: "<run-id>/<leaf-label>" (e.g. "${RUN_ID}/diagnose",
"${RUN_ID}/fix"). Pick <leaf-label> per leaf; it's operator-meaningful.
EOF

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo ""
echo "  1. Keep the Kourier port-forward running in another terminal:"
echo ""
echo "       kubectl port-forward -n kourier-system svc/kourier ${MOCA_PORT}:80"
echo ""
echo "  2. Start Claude from the scratch dir:"
echo ""
echo "       cd ${SCRATCH_DIR} && claude"
echo ""
echo "  3. The demo flow is operator prompts; dispatch is async."
echo "     Suggested first prompt:"
echo ""
echo "       There's a Node.js project seeded at ${WORKSPACE_REF} on MOCA."
echo "       Dispatch a subagent to diagnose why its tests are failing."
echo ""
echo "     Claude will start the leaf and return control immediately."
echo "     You can Ctrl-C and come back later. When you're ready to"
echo "     collect the diagnosis, say:"
echo ""
echo "       Check on that subagent and report the diagnosis."
echo ""
echo "     Then, after reviewing the diagnosis:"
echo ""
echo "       Good. Dispatch another subagent to apply that fix, run the"
echo "       tests, and report the diff and outcome. Check on it when it's done."
echo ""
echo "  4. Watch leaf-worker pods cold-start:"
echo ""
echo "       kubectl -n ${MOCA_NS} get pods -w"
