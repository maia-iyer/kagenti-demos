#!/usr/bin/env bash
# Set up the moca_chained_subagents demo on MOCA's Kubernetes deployment.
#
# Assumes MOCA (rossoctl/moca) and Context Service (rossoctl/context-service)
# are already installed on the current kubectl context, that mocactl and
# contextctl are on PATH, and that the port-forwards are running. This
# script does the demo-specific setup:
#   1. Verify the toolchain and that mocactl can drive the install end to
#      end (mocactl doctor).
#   2. Stage a scratch dir whose contents are the example_repo project
#      (so `./` at the parent's cwd matches `./` at the leaf's cwd),
#      plus a leaves/ dir for prompts/notes/results, a moca-delegate-task
#      skill (upstream SKILL.md, verbatim),
#      and Claude Code settings pointing at this run.
#
# Pack + workload create + workload delete happen per leaf at dispatch
# time, driven by the agent through the skill — not by this script.
# Session dispatch is `mocactl spawn --workload <id>` (optionally
# `--writable` per leaf); no `kubectl cp` is involved.
#
# This script does NOT stand up MOCA or Context Service. See the demo
# README prerequisites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MOCA_NS="${MOCA_NS:-moca}"
CONTEXT_SERVICE_NS="${CONTEXT_SERVICE_NS:-context-service}"
# The control plane tells clients where the harness is, and deploy/k8s
# advertises it as http://127.0.0.1:8080 — so the supervisor's port-forward
# must use local port 8080 specifically.
HARNESS_PORT="${HARNESS_PORT:-8080}"
CP_PORT="${CP_PORT:-8090}"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:${HARNESS_PORT}}"
CP_URL="${CP_URL:-http://127.0.0.1:${CP_PORT}}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"

# Upstream MOCA checkout — holds the moca-delegate-task skill, staged
# verbatim into the scratch dir. This demo adds no overrides: the two
# operator prompts (one per leaf) carry the demo-specific details
# (pack `./example_repo`, tag `moca-chained-subagents-demo`).
# No default — operators clone rossoctl/moca themselves (see README
# Prerequisites) and point MOCA_DIR at it. Same variable that
# prereqs-install.sh reads.
MOCA_DIR="${MOCA_DIR:-}"
UPSTREAM_SKILL="${MOCA_DIR}/skills/moca-delegate-task/SKILL.md"

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

if [[ -z "${MOCA_DIR}" ]]; then
  echo "    MOCA_DIR is not set. This demo stages upstream MOCA's" >&2
  echo "    moca-delegate-task SKILL.md verbatim into the scratch dir." >&2
  echo "    Point MOCA_DIR at your rossoctl/moca checkout:" >&2
  echo "      MOCA_DIR=/path/to/rossoctl/moca ./setup.sh" >&2
  echo "    (See README Prerequisites > Checkouts for the clone commands.)" >&2
  exit 1
fi
if [[ ! -f "${UPSTREAM_SKILL}" ]]; then
  echo "    upstream skill not found: ${UPSTREAM_SKILL}" >&2
  echo "    MOCA_DIR=${MOCA_DIR} does not look like a rossoctl/moca" >&2
  echo "    checkout. Expected: \${MOCA_DIR}/skills/moca-delegate-task/SKILL.md" >&2
  echo "    Verify the path and that the checkout is up to date (git pull)." >&2
  exit 1
fi
echo "    ok: upstream skill at ${UPSTREAM_SKILL}"

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

# mocactl doctor does not probe Context Service's public URL, but the client
# (contextctl / mocactl workloads create) uploads the bundle directly to it.
# If the port-forward is missing, workloads create fails with "cannot reach
# Context Service: fetch failed" AFTER the server has already allocated and
# then rolled back a workload. Catch that here with a clear fix message.
CS_PUBLIC_URL="$(kubectl -n "${MOCA_NS}" get configmap moca-context-service \
  -o jsonpath='{.data.public-url}' 2>/dev/null || true)"
if [[ -z "${CS_PUBLIC_URL}" ]]; then
  echo "    moca-context-service ConfigMap has no public-url key. Reinstall" >&2
  echo "    prerequisites (see README) so the ConfigMap is populated." >&2
  exit 1
fi
# curl exit 7 = connection refused; anything else (incl. an HTTP status like
# 404 on /) means the service is reachable on this port.
cs_probe_status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
  "${CS_PUBLIC_URL%/}/" 2>/dev/null || true)"
if [[ "${cs_probe_status}" == "000" || -z "${cs_probe_status}" ]]; then
  cs_local_port="$(printf '%s' "${CS_PUBLIC_URL}" | awk -F: '{print $NF}' | tr -d /)"
  echo "" >&2
  echo "    Context Service's public URL (${CS_PUBLIC_URL}) is not reachable" >&2
  echo "    from this host. The server-side workload create will succeed," >&2
  echo "    but the client-side bundle upload will then fail with" >&2
  echo "    'cannot reach Context Service: fetch failed'." >&2
  echo "" >&2
  echo "    Start the third port-forward (keep it running):" >&2
  echo "      kubectl port-forward -n ${CONTEXT_SERVICE_NS} svc/context-service ${cs_local_port:-9090}:8080" >&2
  exit 1
fi
echo "    ok: Context Service public URL reachable at ${CS_PUBLIC_URL}"

echo "==> Staging scratch dir at ${SCRATCH_DIR}..."
# Fresh staging on every run: the demo tag is per-run, so notes and results
# from an earlier run would be orphaned. Collect results before re-running.
rm -rf "${SCRATCH_DIR}"
mkdir -p "${SCRATCH_DIR}/.claude/skills/moca-delegate-task" \
         "${SCRATCH_DIR}/leaves"

# Claude Code settings, patched to point mocactl at the port-forwards.
# mocactl itself is already on PATH — verified above, not patched.
cp "${SCRIPT_DIR}/settings.json.example" "${SCRATCH_DIR}/.claude/settings.json"
settings_tmp="$(mktemp)"
jq --arg cp "${CP_URL}" --arg harness "${HARNESS_URL}" \
   '.env = ((.env // {}) + {SH_CONTROL_PLANE_URL: $cp, SH_HARNESS_URL: $harness})' \
   "${SCRATCH_DIR}/.claude/settings.json" >"${settings_tmp}"
mv -f "${settings_tmp}" "${SCRATCH_DIR}/.claude/settings.json"

# Stage the skill verbatim from upstream. The demo's two operator
# prompts carry what's specific here (which directory to pack, which
# tag to use); the skill itself needs no demo-local override.
staged_skill="${SCRATCH_DIR}/.claude/skills/moca-delegate-task/SKILL.md"
cp "${UPSTREAM_SKILL}" "${staged_skill}"

# The project the leaves pack lives at ./example_repo in the scratch dir —
# NOT at the scratch dir root. Keeping it as a subdir means `leaves/` and
# `.claude/` (parent-side bookkeeping) do not get picked up when the agent
# runs `contextctl ctx pack ./example_repo`. Each leaf's workload then
# contains only the fixture, independent of how many leaves ran before.
cp -R "${SCRIPT_DIR}/example_repo" "${SCRATCH_DIR}/example_repo"

# Purge any Python bytecode left in the fixture from a prior in-tree test run
# (e.g. verifying it locally). A .pyc file is tagged with the Python version
# that produced it (e.g. greet.cpython-311.pyc); the sandbox's Python may be
# a different minor version and would ignore or reject it. (`contextctl ctx
# pack` does not yet honor .gitignore, so this purge is what keeps those
# files out of the bundle.)
find "${SCRATCH_DIR}/example_repo" \
  \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) \
  -prune -exec rm -rf {} +

# .envrc gives operators driving the by-hand flow a one-line way to pick
# up the port-forward URLs in a plain shell. Claude Code sessions still
# inherit the same env via .claude/settings.json; this is the sibling
# for `source .envrc` from a plain `bash`/`zsh`.
cat > "${SCRATCH_DIR}/.envrc" <<EOF
export SH_CONTROL_PLANE_URL=${CP_URL}
export SH_HARNESS_URL=${HARNESS_URL}
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
echo "       source .envrc    # or: export the two URLs by hand"
echo ""
echo "  3. Or start Claude from the scratch dir and drive it with operator"
echo "     prompts (the agent flow — see the README's 'Run a session'):"
echo ""
echo "       cd ${SCRATCH_DIR} && claude"
