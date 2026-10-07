#!/usr/bin/env bash
# Set up the moca_chained_subagents demo.
#
# Assumes MOCA (rossoctl/moca) is already installed on the current kubectl
# context via its quick-start (deploy/knative/setup-kind.sh). This script does
# the demo-specific setup:
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
SANDBOX_POOL_SELECTOR="${SANDBOX_POOL_SELECTOR:-sh.kagenti.io/sandbox-pool=default}"
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

SANDBOX_PODS="$(kubectl -n "${MOCA_NS}" get pods \
  -l "${SANDBOX_POOL_SELECTOR}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ -z "${SANDBOX_PODS}" ]; then
  echo "    no Running sandbox pods matched selector '${SANDBOX_POOL_SELECTOR}' in '${MOCA_NS}'." >&2
  echo "    A leaf leases any pool-labeled pod, so every one needs the fixture." >&2
  echo "    Did the MOCA quick-start finish? See:" >&2
  echo "      https://github.com/rossoctl/moca#quick-start" >&2
  exit 1
fi

# NOTE: the KEDA ScaledJob ('leaf-worker') is deliberately NOT checked here.
# It drains MOCA's async Redis stream, and this demo uses the SYNC run path
# exclusively. On the sync path the Knative serverless-harness revision runs
# the agent in-process and execs into a leased sandbox pod directly, so no
# leaf-worker Job is ever created and the ScaledJob stays ACTIVE=False.
# Requiring it would be a false prerequisite.

echo "    ok: kubectl, curl, jq on PATH"
echo "    ok: namespace ${MOCA_NS} exists"
echo "    ok: sandbox pool pods: ${SANDBOX_PODS}"

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

echo "==> Waiting for sandbox pool pods to be Ready..."
for pod in ${SANDBOX_PODS}; do
  kubectl -n "${MOCA_NS}" wait --for=condition=Ready "pod/${pod}" --timeout=90s >/dev/null
done
echo "    ok"

echo "==> Seeding example_repo/ into every pool-labeled sandbox at ${WORKSPACE_REF}..."
# Every pool-labeled sandbox needs the fixture because a leaf leases
# any one of them for a given run — if the lease lands on an unseeded pod, the
# agent cannot find the repo path and the leaf fails with reason "error".
for pod in ${SANDBOX_PODS}; do
  echo "    - ${pod}"
  kubectl -n "${MOCA_NS}" exec "${pod}" -- sh -c "mkdir -p '${WORKSPACE_REF}'"
  kubectl -n "${MOCA_NS}" exec "${pod}" -- sh -c "rm -rf '${WORKSPACE_REF}'/* '${WORKSPACE_REF}'/.[!.]* 2>/dev/null; true"
  kubectl -n "${MOCA_NS}" cp "${SCRIPT_DIR}/example_repo/." "${pod}:${WORKSPACE_REF}"
done
echo "    ok"

echo "==> Staging scratch dir at ${SCRATCH_DIR}..."

mkdir -p "${SCRATCH_DIR}/.claude/skills"
mkdir -p "${SCRATCH_DIR}/.moca-runs"
mkdir -p "${SCRATCH_DIR}/bin"
cp "${SCRIPT_DIR}/settings.json.example" \
   "${SCRATCH_DIR}/.claude/settings.json"
cp -r "${SCRIPT_DIR}/skill" \
      "${SCRATCH_DIR}/.claude/skills/moca-dispatch"
install -m 0755 "${SCRIPT_DIR}/bin/moca" "${SCRATCH_DIR}/bin/moca"

# Rewrite .claude/settings.json so the moca CLI is on PATH for Bash tool
# invocations. The example file ships without an env block; inject one
# that prepends the scratch dir's bin/ to $PATH.
python3 - "${SCRATCH_DIR}/.claude/settings.json" "${SCRATCH_DIR}/bin" <<'PY'
import json, sys, os
settings_path, bin_dir = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    s = json.load(f)
env = s.setdefault("env", {})
env["PATH"] = f"{bin_dir}:" + os.environ.get("PATH", "/usr/bin:/bin")
with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PY

cat > "${SCRATCH_DIR}/MOCA.md" <<EOF
# MOCA settings for this scratch session

Base URL:      ${MOCA_BASE}
Host header:   ${MOCA_HOST}
workspaceRef:  ${WORKSPACE_REF}
Run id:        ${RUN_ID}

The fixture (example_repo/) has been seeded into every pool-labeled sandbox
(selector '${SANDBOX_POOL_SELECTOR}') at ${WORKSPACE_REF}
in namespace ${MOCA_NS}. Every curl to MOCA must send:

  -H "Host: ${MOCA_HOST}"

Dispatch is a DETACHED SYNCHRONOUS turn. POST ${MOCA_BASE}/runs with no
'async' field blocks until the leaf finishes and returns the answer inline.
'moca start' forks a detached worker (nohup, disowned) to hold that blocking
call, so the turn returns immediately and the run survives Claude exiting.

MOCA persists each leaf's result cluster-side BEFORE writing the sync
response, so GET ${MOCA_BASE}/runs/status?sessionId=<id> can recover a
result (for 24h) even if the detached worker is killed.

Run records live in .moca-runs/ — see the moca-dispatch skill.

Session-id scheme: "<run-id>.<leaf-label>" (e.g. "${RUN_ID}.diagnose",
"${RUN_ID}.fix"). Pick <leaf-label> per leaf; it's operator-meaningful.
MOCA validates session ids as alphanumerics plus '-', '_', '.', starting and
ending alphanumeric — so '.' is the separator and a '/' is REJECTED at the
API boundary before the leaf runs.
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
echo "  3. The demo flow is operator prompts; dispatch is a detached sync turn."
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
echo "  4. Watch the harness revision cold-start and scale back to zero:"
echo ""
echo "       kubectl -n ${MOCA_NS} get pods -w"
echo ""
echo "     On the sync path the work runs in the serverless-harness-* pod"
echo "     (which exec's into a leased sandbox-* pod). Expect that pod to"
echo "     appear on dispatch and disappear once idle. There are no"
echo "     leaf-worker-* pods on this path — those belong to the async queue."
