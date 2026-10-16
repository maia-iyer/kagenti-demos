#!/usr/bin/env bash
# Set up the moca_chained_subagents demo on MOCA's Kubernetes deployment.
#
# Assumes MOCA (rossoctl/moca) and Context Service (rossoctl/context-service)
# are already installed on the current kubectl context, that mocactl and
# contextctl are on PATH, and that the port-forwards are running. This
# script does the demo-specific setup:
#   1. Verify the toolchain and that mocactl can drive the install end to
#      end (mocactl doctor).
#   2. Pack the fixture into a workspace .context bundle, create a workload
#      from it, and record the workload id in MOCA.md. The two leaves of
#      this run share that workload: the diagnose leaf mounts it read-only,
#      the fix leaf gets its own writable copy per run.
#   3. Stage a scratch dir: a leaves/ dir for prompts/notes/results, the
#      moca-dispatch skill, and Claude Code settings pointing at this run.
#
# Session dispatch happens later via `mocactl spawn --workload <id>` (and
# `--writable` for the fix leaf); no `kubectl cp` is involved.
#
# This script does NOT stand up MOCA or Context Service. See the demo
# README prerequisites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MOCA_NS="${MOCA_NS:-moca}"
# The control plane tells clients where the harness is, and deploy/k8s
# advertises it as http://127.0.0.1:8080 — so the supervisor's port-forward
# must use local port 8080 specifically.
HARNESS_PORT="${HARNESS_PORT:-8080}"
CP_PORT="${CP_PORT:-8090}"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:${HARNESS_PORT}}"
CP_URL="${CP_URL:-http://127.0.0.1:${CP_PORT}}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"

echo "==> Prerequisite checks..."

for bin in kubectl jq contextctl; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "    missing required binary: ${bin}" >&2
    exit 1
  fi
done
# mocactl is invoked directly by the demo (it is never re-staged into the
# scratch dir), so it must already be on PATH here.
if ! command -v mocactl >/dev/null 2>&1; then
  echo "    mocactl is not on PATH. Install it (Node 22+):" >&2
  echo "      curl -fsSL https://raw.githubusercontent.com/rossoctl/moca/main/scripts/install-mocactl.sh | sh" >&2
  exit 1
fi
# Capability probe: mocactl must have both the subagent commands and the
# workloads subcommand. An old mocactl answers 'unknown command' here instead;
# reinstall from the edge release (above) or any newer tagged release.
spawn_probe="$(mocactl spawn 2>&1 || true)"
if ! printf '%s' "${spawn_probe}" | grep -q 'spawn needs a prompt'; then
  echo "    this mocactl has no working 'spawn' subagent command — too old." >&2
  echo "    Reinstall with the install script above." >&2
  exit 1
fi
workloads_probe="$(mocactl workloads 2>&1 || true)"
if ! printf '%s' "${workloads_probe}" | grep -q 'workloads needs create, get or delete'; then
  echo "    this mocactl has no 'workloads' subcommand — too old." >&2
  echo "    Reinstall with the install script above (MOCACTL_VERSION=edge)." >&2
  exit 1
fi
echo "    ok: kubectl, jq, contextctl, mocactl on PATH (workloads + subagent commands present)"

if ! kubectl get ns "${MOCA_NS}" >/dev/null 2>&1; then
  echo "    namespace '${MOCA_NS}' not found on current kubectl context." >&2
  echo "    Install MOCA's Kubernetes deployment first:" >&2
  echo "      cd <moca>/deploy/k8s && ./setup.sh --target kind --build" >&2
  exit 1
fi
echo "    ok: namespace ${MOCA_NS} exists"

echo "==> Running mocactl doctor..."
# doctor (with the port-forward URLs via env) covers everything the old setup
# probed by hand: control-plane reachability, login, credential, harness
# located/reachable/trusted, and an end-to-end scratch session. It prints one
# suggested fix per failing check and exits non-zero on failure.
if ! SH_CONTROL_PLANE_URL="${CP_URL}" SH_HARNESS_URL="${HARNESS_URL}" mocactl doctor; then
  echo "" >&2
  echo "    doctor failed. Its output above includes the fix for each failing" >&2
  echo "    check. Both port-forwards must be running:" >&2
  echo "      kubectl port-forward -n ${MOCA_NS} svc/moca-supervisor ${HARNESS_PORT}:8080" >&2
  echo "      kubectl port-forward -n ${MOCA_NS} svc/moca-control-plane ${CP_PORT}:8080" >&2
  echo "    Context Service's public URL must also be reachable (configured in" >&2
  echo "    MOCA's moca-context-service ConfigMap). See README prerequisites." >&2
  exit 1
fi

echo "==> Staging scratch dir at ${SCRATCH_DIR}..."
# Fresh staging on every run: the demo tag is per-run, so notes and results
# from an earlier run would be orphaned. Collect results before re-running.
rm -rf "${SCRATCH_DIR}"
mkdir -p "${SCRATCH_DIR}/.claude/skills/moca-dispatch" "${SCRATCH_DIR}/leaves"

# Claude Code settings, patched to point mocactl at the port-forwards.
# mocactl itself is already on PATH — verified above, not patched.
cp "${SCRIPT_DIR}/settings.json.example" "${SCRATCH_DIR}/.claude/settings.json"
settings_tmp="$(mktemp)"
jq --arg cp "${CP_URL}" --arg harness "${HARNESS_URL}" \
   '.env = ((.env // {}) + {SH_CONTROL_PLANE_URL: $cp, SH_HARNESS_URL: $harness})' \
   "${SCRATCH_DIR}/.claude/settings.json" >"${settings_tmp}"
mv -f "${settings_tmp}" "${SCRATCH_DIR}/.claude/settings.json"

# The dispatch skill — the agent flow's mechanism contract (the by-hand
# appendix in the README never reads it; a Claude session does).
cp "${SCRIPT_DIR}/skill/SKILL.md" \
   "${SCRATCH_DIR}/.claude/skills/moca-dispatch/SKILL.md"

# The fixture the demo's two leaves share, packed into a workspace .context
# bundle for Context Service.
cp -R "${SCRIPT_DIR}/example_repo" "${SCRATCH_DIR}/example_repo"

# Purge any Python bytecode left in the fixture from a prior in-tree test run
# (e.g. verifying the fixture locally). A .pyc file is tagged with the Python
# version that produced it (e.g. greet.cpython-311.pyc); the sandbox's Python
# may be a different minor version and would ignore or reject it, and leaf
# prompts assume a clean fixture. (`contextctl ctx pack` does not yet honor
# .gitignore, so this purge is what keeps those files out of the bundle.)
find "${SCRATCH_DIR}/example_repo" \
  \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) \
  -prune -exec rm -rf {} +

echo "==> Packing fixture as a workspace context bundle..."
# ctx pack produces a .context file (gzipped tar) under workspace/, with
# every file sha256-pinned by the resulting revision. The upload limits
# (10,000 entries, 256 MiB per file, 1 GiB expanded) are enforced client-
# side, so an oversized fixture fails before upload.
CONTEXT_BUNDLE="${SCRATCH_DIR}/example_repo.context"
contextctl ctx pack "${SCRATCH_DIR}/example_repo" --type workspace \
  --output "${CONTEXT_BUNDLE}"

echo "==> Creating the shared workload..."
# One workload per demo run, shared by both leaves: the diagnose leaf mounts
# it read-only, the fix leaf gets its own writable per-run copy via --writable.
# Writes do NOT persist across runs (that is phase-2 workloads,
# https://github.com/rossoctl/moca/issues/476).
WORKLOAD_JSON="$(SH_CONTROL_PLANE_URL="${CP_URL}" SH_HARNESS_URL="${HARNESS_URL}" \
  mocactl workloads create --context "${CONTEXT_BUNDLE}" --json)"
WORKLOAD_ID="$(printf '%s' "${WORKLOAD_JSON}" | jq -r '.workloadId')"
if [[ -z "${WORKLOAD_ID}" || "${WORKLOAD_ID}" == "null" ]]; then
  echo "    workloads create did not return a workloadId:" >&2
  echo "    ${WORKLOAD_JSON}" >&2
  exit 1
fi
echo "    created workload ${WORKLOAD_ID}"

echo "==> Promoting the two config bundles..."
# Config bundles carry each leaf's skills + commands (NOT CLAUDE.md). They
# travel server-held and content-addressed, picked up at dispatch time via
# `mocactl spawn --config <digest>`. The diagnose leaf runs with the
# public-only posture; the fix leaf runs with the full-access posture.
promote_bundle() {
  local dir="$1"
  local label="$2"
  local json
  json="$(SH_CONTROL_PLANE_URL="${CP_URL}" SH_HARNESS_URL="${HARNESS_URL}" \
    mocactl promote "${dir}" --json 2>/dev/null)"
  local digest
  digest="$(printf '%s' "${json}" | jq -r '.digest')"
  if [[ -z "${digest}" || "${digest}" == "null" ]]; then
    echo "    promote ${label} did not return a digest:" >&2
    echo "    ${json}" >&2
    exit 1
  fi
  printf '%s' "${digest}"
}
DIGEST_PUBLIC="$(promote_bundle "${SCRIPT_DIR}/bundles/public-only" public-only)"
echo "    promoted public-only  ${DIGEST_PUBLIC}"
DIGEST_FULL="$(promote_bundle "${SCRIPT_DIR}/bundles/full" full)"
echo "    promoted full         ${DIGEST_FULL}"

# One demo tag per scratch dir. mocactl's subagent ledger is machine-global;
# the tag is what scopes listing and teardown to this demo instance.
TAG="chained-$(date +%Y%m%d-%H%M%S)"

cat > "${SCRATCH_DIR}/MOCA.md" <<EOF
# MOCA runtime facts for this demo run

Control plane URL:     ${CP_URL}
Harness URL:           ${HARNESS_URL}
Demo tag:              ${TAG}
Workload id:           ${WORKLOAD_ID}
Config digest public:  ${DIGEST_PUBLIC}
Config digest full:    ${DIGEST_FULL}
Context bundle:        ./example_repo.context
Leaves dir:            ./leaves

Every mocactl command run from this directory needs the port-forward URLs
in the environment (the staged .claude/settings.json does this for Claude):

  export SH_CONTROL_PLANE_URL=${CP_URL}
  export SH_HARNESS_URL=${HARNESS_URL}

Notes:
- Both leaves share workload ${WORKLOAD_ID}. The diagnose leaf dispatches
  with '--config ${DIGEST_PUBLIC} --workload ${WORKLOAD_ID}' (read-only).
  The fix leaf dispatches with '--config ${DIGEST_FULL} --workload
  ${WORKLOAD_ID} --writable' and gets its own copy, discarded when the run
  ends.
- Each child's identity is (config digest, workload revision, sessionId) —
  three sha256-pinned handles, all server-held, all reconstructable from
  this file + the mocactl ledger.
- Leaf cwd is the workload's view (or writable copy): project files are
  immediately visible with 'pwd' / 'ls'. There is no fixture-seeding step.
- There is no cancel; a dispatched leaf runs to completion. Results persist
  server-side for 24h — collect with 'mocactl get <sessionId>' inside that
  window.
EOF

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo ""
echo "  1. Keep BOTH port-forwards running in other terminals:"
echo ""
echo "       kubectl port-forward -n ${MOCA_NS} svc/moca-supervisor ${HARNESS_PORT}:8080"
echo "       kubectl port-forward -n ${MOCA_NS} svc/moca-control-plane ${CP_PORT}:8080"
echo ""
echo "     Context Service's public URL (configured in moca-context-service)"
echo "     must be reachable from this host too; see README prerequisites."
echo ""
echo "  2. Drive the demo by hand from the scratch dir — the full sequence"
echo "     (spawn, collect, chain) is the demo README's 'Appendix: running"
echo "     the flow by hand':"
echo ""
echo "       cd ${SCRATCH_DIR}"
echo "       export SH_CONTROL_PLANE_URL=${CP_URL} SH_HARNESS_URL=${HARNESS_URL}"
echo "       mocactl spawn \"\$(cat leaves/diagnose.prompt.txt)\" \\"
echo "         --config ${DIGEST_PUBLIC} \\"
echo "         --kind prompt --workload ${WORKLOAD_ID} --tag ${TAG} --json"
echo ""
echo "  3. Or start Claude from the scratch dir and drive it with operator"
echo "     prompts (the agent flow — see the README's 'Run a session'):"
echo ""
echo "       cd ${SCRATCH_DIR} && claude"
