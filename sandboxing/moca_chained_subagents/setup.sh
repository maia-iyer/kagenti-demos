#!/usr/bin/env bash
# Set up the moca_chained_subagents demo on MOCA's Kubernetes deployment.
#
# Assumes MOCA (rossoctl/moca) is already installed on the current kubectl
# context via deploy/k8s/setup.sh, and that both port-forwards are running.
# This script does the demo-specific setup:
#   1. Verify the toolchain, the namespaces, and that mocactl (with the
#      subagent commands) can drive the install end to end (mocactl doctor).
#   2. Stage a scratch dir for the run: a copy of example_repo/ (the seed
#      source for every leaf), a leaves/ dir for prompts/notes/results,
#      MOCA.md runtime facts (including this run's demo tag), the
#      moca-dispatch skill, and Claude Code settings.
#
# Everything else happens at dispatch time, via mocactl: `spawn` creates a
# fresh session per leaf (mocactl owns all auth), and the parent seeds each
# leaf's workspace with kubectl cp right after spawn. Setup therefore no
# longer mints tokens, creates a session, widens timeouts, or copies
# anything into the cluster.
#
# This script does NOT stand up MOCA. See the demo README prerequisites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MOCA_NS="${MOCA_NS:-moca}"
SANDBOX_NS="${SANDBOX_NS:-moca-sandbox}"
# Sandbox pods are matched by label (the moca-sandbox StatefulSet's template
# label) so a leaf's fixture can be seeded on every pod that could serve it.
SANDBOX_POD_SELECTOR="${SANDBOX_POD_SELECTOR:-app=moca-sandbox}"
SANDBOX_CONTAINER="${SANDBOX_CONTAINER:-sandbox}"
# The control plane tells clients where the harness is, and deploy/k8s
# advertises it as http://127.0.0.1:8080 — so the supervisor's port-forward
# must use local port 8080 specifically.
HARNESS_PORT="${HARNESS_PORT:-8080}"
CP_PORT="${CP_PORT:-8090}"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:${HARNESS_PORT}}"
CP_URL="${CP_URL:-http://127.0.0.1:${CP_PORT}}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"

echo "==> Prerequisite checks..."

for bin in kubectl jq; do
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
# Capability probe: mocactl must have the subagent commands. An old mocactl
# answers 'unknown command' here instead.
spawn_probe="$(mocactl spawn 2>&1 || true)"
if ! printf '%s' "${spawn_probe}" | grep -q 'spawn needs a prompt'; then
  echo "    this mocactl has no working 'spawn' subagent command — too old." >&2
  echo "    Install mocactl >= edge-a02b9db and re-run." >&2
  exit 1
fi
echo "    ok: kubectl, jq, mocactl on PATH (subagent commands present)"

if ! kubectl get ns "${MOCA_NS}" >/dev/null 2>&1; then
  echo "    namespace '${MOCA_NS}' not found on current kubectl context." >&2
  echo "    Install MOCA's Kubernetes deployment first:" >&2
  echo "      cd <moca>/deploy/k8s && ./setup.sh --target kind --build" >&2
  exit 1
fi

if ! kubectl -n "${SANDBOX_NS}" get statefulset moca-sandbox >/dev/null 2>&1; then
  echo "    StatefulSet 'moca-sandbox' not found in namespace '${SANDBOX_NS}'." >&2
  echo "    Did deploy/k8s/setup.sh finish?" >&2
  exit 1
fi
echo "    ok: namespaces ${MOCA_NS} and ${SANDBOX_NS} exist"

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
  exit 1
fi

echo "==> Staging scratch dir at ${SCRATCH_DIR}..."
# Fresh staging on every run: the demo tag is per-run, so notes and results
# from an earlier run would be orphaned. Collect results before re-running.
rm -rf "${SCRATCH_DIR}"
mkdir -p "${SCRATCH_DIR}/.claude/skills/moca-dispatch" "${SCRATCH_DIR}/leaves"

# Claude Code settings, patched two ways: the env block that points mocactl
# at the port-forwards, and the kubectl allow patterns rewritten for this
# run's sandbox namespace (the example file carries the default ns).
# mocactl itself is already on PATH — verified above, not patched.
cp "${SCRIPT_DIR}/settings.json.example" "${SCRATCH_DIR}/.claude/settings.json"
settings_tmp="$(mktemp)"
jq --arg cp "${CP_URL}" --arg harness "${HARNESS_URL}" --arg ns "${SANDBOX_NS}" \
   '.env = ((.env // {}) + {SH_CONTROL_PLANE_URL: $cp, SH_HARNESS_URL: $harness})
    | .permissions.allow |= map(gsub("moca-sandbox"; $ns))' \
   "${SCRATCH_DIR}/.claude/settings.json" >"${settings_tmp}"
mv -f "${settings_tmp}" "${SCRATCH_DIR}/.claude/settings.json"

# The dispatch skill — the agent flow's mechanism contract (the by-hand
# appendix in the README never reads it; a Claude session does).
cp "${SCRIPT_DIR}/skill/SKILL.md" \
   "${SCRATCH_DIR}/.claude/skills/moca-dispatch/SKILL.md"

# The fixture the parent seeds every leaf's workspace from (kubectl cp
# source at dispatch time).
cp -R "${SCRIPT_DIR}/example_repo" "${SCRATCH_DIR}/example_repo"

# Purge any Python bytecode left in the fixture from a prior in-tree test run
# (e.g. verifying the fixture locally). A .pyc file is tagged with the Python
# version that produced it (e.g. greet.cpython-311.pyc); the sandbox's Python
# may be a different minor version and would ignore or reject it, and leaf
# prompts assume a clean fixture.
find "${SCRATCH_DIR}/example_repo" \
  \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) \
  -prune -exec rm -rf {} +

# One demo tag per scratch dir. mocactl's subagent ledger is machine-global;
# the tag is what scopes listing and teardown to this demo instance.
TAG="chained-$(date +%Y%m%d-%H%M%S)"

cat > "${SCRATCH_DIR}/MOCA.md" <<EOF
# MOCA runtime facts for this demo run

Control plane URL:     ${CP_URL}
Harness URL:           ${HARNESS_URL}
Demo tag:              ${TAG}
Sandbox namespace:     ${SANDBOX_NS}
Sandbox pod selector:  ${SANDBOX_POD_SELECTOR}
Sandbox container:     ${SANDBOX_CONTAINER}
Fixture (seed source): ./example_repo
Leaves dir:            ./leaves

Every mocactl command run from this directory needs the port-forward URLs
in the environment (the staged .claude/settings.json does this for Claude):

  export SH_CONTROL_PLANE_URL=${CP_URL}
  export SH_HARNESS_URL=${HARNESS_URL}

Notes:
- Every leaf is its own session with its own workspace at
  /workspace/<sessionId>. The parent seeds the fixture into that workspace
  right after spawn (kubectl cp to every sandbox pod).
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
echo "  2. Drive the demo by hand from the scratch dir — the full sequence"
echo "     (spawn, seed, collect, chain) is the demo README's 'Appendix:"
echo "     running the flow by hand':"
echo ""
echo "       cd ${SCRATCH_DIR}"
echo "       export SH_CONTROL_PLANE_URL=${CP_URL} SH_HARNESS_URL=${HARNESS_URL}"
echo "       mocactl spawn \"\$(cat leaves/diagnose.prompt.txt)\" \\"
echo "         --kind prompt --tag ${TAG} --json"
echo ""
echo "  3. Or start Claude from the scratch dir and drive it with operator"
echo "     prompts (the agent flow — see the README's 'Run a session'):"
echo ""
echo "       cd ${SCRATCH_DIR} && claude"
