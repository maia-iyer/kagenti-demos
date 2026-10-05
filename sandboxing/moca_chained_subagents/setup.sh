#!/usr/bin/env bash
# Set up the moca_chained_subagents demo.
#
# Assumes MOCA (rossoctl/serverless-harness) is already installed on the
# current kubectl context. This script does the demo-specific setup:
#   1. Publish example_repo/ as a workspace, synced into the MOCA
#      namespace as a PVC.
#   2. Create two MOCA workloads bound to that PVC — workload-A
#      (read-only) and workload-B (read-write).
#   3. Stage settings and skill into a scratch directory for a Claude
#      session.
#
# Workspace publishing uses lib/ctx.sh — a thin kubectl-only shim that
# mirrors the subset of contextctl verbs this demo needs. To swap in
# real contextctl later, replace the function bodies in lib/ctx.sh with
# contextctl invocations; the call sites below do not change.
#
# This script does NOT stand up MOCA. That's a prerequisite — see the
# demo README.

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

echo "==> Prerequisite checks..."

for bin in kubectl curl jq; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "    missing required binary: ${bin}" >&2
    exit 1
  fi
done

if ! kubectl get ns "${MOCA_NS}" >/dev/null 2>&1; then
  echo "    MOCA namespace '${MOCA_NS}' not found on current kubectl context." >&2
  echo "    Install MOCA (rossoctl/serverless-harness) first, or override MOCA_NS." >&2
  exit 1
fi

if ! curl -sS -o /dev/null -w '%{http_code}\n' "${MOCA_URL}/healthz" 2>/dev/null | grep -qE '^(200|204|404)$'; then
  echo "    cannot reach MOCA at ${MOCA_URL}." >&2
  echo "    Start a port-forward in another terminal:" >&2
  echo "      kubectl -n ${MOCA_NS} port-forward svc/<harness-svc> ${MOCA_PORT}:<port>" >&2
  echo "    (The exact service name and port depend on your MOCA install;" >&2
  echo "     check 'kubectl -n ${MOCA_NS} get svc'.)" >&2
  exit 1
fi

echo "    ok: kubectl, curl, jq on PATH"
echo "    ok: namespace ${MOCA_NS} exists"
echo "    ok: MOCA reachable at ${MOCA_URL}"

echo "==> Publishing example_repo/ as a workspace..."

ctx_create_local      "${CTX_LOCAL}"
ctx_artifact_publish  "${CTX_LOCAL}" "${SCRIPT_DIR}/example_repo"
ctx_create_remote     "${CTX_REMOTE}" "${MOCA_NS}"
ctx_sync_push         "${CTX_LOCAL}" "${CTX_REMOTE}" "${MOCA_NS}"

echo "==> Resolving PVC claim name for ${CTX_REMOTE}..."
CLAIM_NAME="$(ctx_get_claim "${CTX_REMOTE}" "${MOCA_NS}")"
echo "    claim: ${CLAIM_NAME}"

echo "==> Creating MOCA workloads..."

create_workload() {
  local name="$1" ro="$2"
  curl -sS -X POST "${MOCA_URL}/workloads" \
    -H 'content-type: application/json' \
    -d "$(jq -n \
          --arg name "${name}" \
          --arg claim "${CLAIM_NAME}" \
          --argjson ro "${ro}" \
          '{name:$name, sandboxes:1, workspace:{claimName:$claim, readOnly:$ro}}')" \
    | tee "/tmp/moca-${name}.json"
  echo
}

create_workload "${WORKLOAD_A}" true
create_workload "${WORKLOAD_B}" false

echo "==> Staging scratch dir at ${SCRATCH_DIR}..."

mkdir -p "${SCRATCH_DIR}/.claude/skills"
mkdir -p "${SCRATCH_DIR}/.moca-runs"
cp "${SCRIPT_DIR}/settings.json.example" \
   "${SCRATCH_DIR}/.claude/settings.json"
cp -r "${SCRIPT_DIR}/skill" \
      "${SCRATCH_DIR}/.claude/skills/moca-dispatch"

cat > "${SCRATCH_DIR}/WORKLOADS.md" <<EOF
# MOCA workloads for this scratch session

| Role       | Workload           | Mount                     |
|------------|--------------------|---------------------------|
| researcher | ${WORKLOAD_A}      | /workspace (read-only)    |
| fixer      | ${WORKLOAD_B}      | /workspace (read-write)   |

MOCA base URL: ${MOCA_URL}

Dispatch is async: POST /runs starts a leaf and returns a handle;
GET /runs/status?sessionId=<id> returns the result when done. Run
records live in .moca-runs/ — see the moca-dispatch skill.

Session-id scheme: "<run-id>/<leaf-label>" (e.g. "x7f2/a", "x7f2/b").
Pick <run-id> fresh per operator request; <leaf-label> is a short
operator-meaningful identifier within the run.
EOF

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo ""
echo "  1. Keep the MOCA port-forward running in another terminal."
echo ""
echo "  2. Start Claude from the scratch dir:"
echo ""
echo "       cd ${SCRATCH_DIR} && claude"
echo ""
echo "  3. The demo flow is operator prompts; dispatch is async."
echo "     Suggested first prompt:"
echo ""
echo "       There's a Node.js project in example_repo on MOCA."
echo "       Dispatch a subagent against the read-only workload to"
echo "       diagnose why its tests are failing."
echo ""
echo "     Claude will start the leaf and return control immediately."
echo "     You can Ctrl-C and come back later. When you're ready to"
echo "     collect the diagnosis, say:"
echo ""
echo "       Check on that subagent and report the diagnosis."
echo ""
echo "     Then, after reviewing the diagnosis:"
echo ""
echo "       Good. Dispatch another subagent against the read-write"
echo "       workload to apply that fix, run the tests, and report the"
echo "       diff and outcome. Check on it when it's done."
echo ""
echo "  4. Watch leaf pods cold-start in the MOCA namespace:"
echo ""
echo "       kubectl -n ${MOCA_NS} get pods -w"
