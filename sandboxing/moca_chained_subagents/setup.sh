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
#      plus a moca-delegate-task skill (upstream SKILL.md, verbatim)
#      and the parent coding agent's config pointing at this run
#      (Claude Code or OpenCode — pick with PARENT=claude|opencode,
#      default claude).
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
# Port-forward ports; keep defaults identical to prereqs-install.sh. If you
# override these, set the same env vars before running ./prereqs-install.sh.
# deploy/k8s/setup.sh is invoked by prereqs-install.sh with
# SH_PUBLIC_HARNESS_URL=http://127.0.0.1:${HARNESS_PORT}, so the control
# plane advertises the port chosen here.
HARNESS_PORT="${HARNESS_PORT:-18080}"
CP_PORT="${CP_PORT:-18090}"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:${HARNESS_PORT}}"
CP_URL="${CP_URL:-http://127.0.0.1:${CP_PORT}}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"

# Which parent coding agent to stage config for. Claude Code is the default
# (settings.json with native `env` injection); OpenCode uses opencode.jsonc
# plus a run-opencode.sh wrapper that exports the port-forward URLs before
# execing opencode (OpenCode has no equivalent of settings.json's `env` key).
PARENT="${PARENT:-claude}"
case "${PARENT}" in
  claude|opencode) ;;
  *)
    echo "    PARENT='${PARENT}' not supported (expected: claude, opencode)" >&2
    exit 1
    ;;
esac

# Upstream MOCA checkout — holds the moca-delegate-task skill, staged
# verbatim into the scratch dir. This demo adds no overrides: the two
# operator prompts (one per leaf) carry the demo-specific detail
# (tag `moca-chained-subagents-demo`).
# No default — operators clone rossoctl/moca themselves (see README
# Prerequisites) and point CLONE_DIR at the parent of that checkout.
# Same variable that prereqs-install.sh reads; MOCA lives at $CLONE_DIR/moca.
: "${CLONE_DIR:?CLONE_DIR is required: parent of the moca/ checkout (see README > Checkouts)}"
MOCA_DIR="${CLONE_DIR}/moca"
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
# --label is how the demo keys per-leaf tracking on the ledger instead of in
# sidecar files. An old mocactl without --label would accept the flag's value
# as part of the prompt and silently miss the mnemonic.
label_probe="$(mocactl spawn --help 2>&1 || true; mocactl --help 2>&1 || true)"
if ! printf '%s' "${label_probe}" | grep -q -- '--label'; then
  echo "    this mocactl has no 'spawn --label' flag — too old." >&2
  echo "    Reinstall with the install script above (MOCACTL_VERSION=edge)." >&2
  exit 1
fi
# --sandboxes / --mount are the workload-sandboxes flags the demo relies on. An
# old mocactl silently falls back to a shared-pool workload (no per-workload PVC)
# when the agent passes them, with no error — the demo degrades without an
# obvious signal.
sandboxes_probe="$(mocactl workloads create 2>&1 || true)"
if ! printf '%s' "${sandboxes_probe}" | grep -q -- '--sandboxes'; then
  echo "    this mocactl has no 'workloads create --sandboxes' flag — too old." >&2
  echo "    Reinstall with the install script above (MOCACTL_VERSION=edge)." >&2
  exit 1
fi
# --prompt-file lets prompt 3 chain the diagnose leaf's output into the fix leaf
# without inlining it on argv — Claude Code's Bash tool refuses inline prompts
# with `#` or multi-line content. Without this flag the chain stalls at prompt 3.
if ! printf '%s' "${label_probe}" | grep -q -- '--prompt-file'; then
  echo "    this mocactl has no 'spawn --prompt-file' flag — too old." >&2
  echo "    Reinstall with the install script above (MOCACTL_VERSION=edge)." >&2
  exit 1
fi
echo "    ok: kubectl, jq, contextctl, mocactl on PATH (workloads + --label + --sandboxes + --prompt-file present)"

if ! kubectl get ns "${MOCA_NS}" >/dev/null 2>&1; then
  echo "    namespace '${MOCA_NS}' not found on current kubectl context." >&2
  echo "    Install MOCA's Kubernetes deployment first:" >&2
  echo "      cd <moca>/deploy/k8s && ./setup.sh --target kind --build" >&2
  exit 1
fi
echo "    ok: namespace ${MOCA_NS} exists"

if [[ ! -f "${UPSTREAM_SKILL}" ]]; then
  echo "    upstream skill not found: ${UPSTREAM_SKILL}" >&2
  echo "    CLONE_DIR=${CLONE_DIR} does not contain a rossoctl/moca checkout" >&2
  echo "    at moca/. Expected: \${CLONE_DIR}/moca/skills/moca-delegate-task/SKILL.md" >&2
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
  echo "    check. The three port-forwards must be running (prereqs-install.sh" >&2
  echo "    backgrounds them; logs: ~/.local/state/moca-chained-demo/). Check:" >&2
  echo "      pgrep -f 'kubectl --context kind-${KIND_CLUSTER:-moca} .* port-forward'" >&2
  echo "    Re-run ./prereqs-install.sh to restart them cleanly." >&2
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
  echo "    The context-service port-forward is backgrounded by" >&2
  echo "    prereqs-install.sh — tail its log for why it died:" >&2
  echo "      ~/.local/state/moca-chained-demo/context-service.log" >&2
  echo "    Re-run ./prereqs-install.sh to restart all three cleanly." >&2
  exit 1
fi
echo "    ok: Context Service public URL reachable at ${CS_PUBLIC_URL}"

echo "==> Staging scratch dir at ${SCRATCH_DIR} (parent: ${PARENT})..."
# Fresh staging on every run: the demo tag is per-run, so notes and results
# from an earlier run would be orphaned. Collect results before re-running.
rm -rf "${SCRATCH_DIR}"
mkdir -p "${SCRATCH_DIR}"

# Stage parent-specific config + skill. Both agents consume the SAME upstream
# SKILL.md verbatim; only the config dir name, config file format, and
# env-injection mechanism differ.
case "${PARENT}" in
  claude)
    mkdir -p "${SCRATCH_DIR}/.claude/skills/moca-delegate-task"
    # Claude Code settings, patched to point mocactl at the port-forwards.
    # mocactl itself is already on PATH — verified above, not patched.
    cp "${SCRIPT_DIR}/parents/claude/settings.json.example" \
       "${SCRATCH_DIR}/.claude/settings.json"
    settings_tmp="$(mktemp)"
    jq --arg cp "${CP_URL}" --arg harness "${HARNESS_URL}" \
       '.env = ((.env // {}) + {SH_CONTROL_PLANE_URL: $cp, SH_HARNESS_URL: $harness})' \
       "${SCRATCH_DIR}/.claude/settings.json" >"${settings_tmp}"
    mv -f "${settings_tmp}" "${SCRATCH_DIR}/.claude/settings.json"
    cp "${UPSTREAM_SKILL}" \
       "${SCRATCH_DIR}/.claude/skills/moca-delegate-task/SKILL.md"
    ;;
  opencode)
    mkdir -p "${SCRATCH_DIR}/.opencode/skills/moca-delegate-task"
    # OpenCode permission policy — no env-injection in the config, so port-
    # forward URLs are exported by the run-opencode.sh wrapper (below).
    cp "${SCRIPT_DIR}/parents/opencode/opencode.jsonc.example" \
       "${SCRATCH_DIR}/.opencode/opencode.jsonc"
    cp "${UPSTREAM_SKILL}" \
       "${SCRATCH_DIR}/.opencode/skills/moca-delegate-task/SKILL.md"
    # Render the wrapper template with the port-forward URLs substituted.
    # Refuse URLs containing sed metacharacters (|, &, \) before substitution:
    # a port-forward URL carrying those would corrupt the resulting wrapper.
    for u in "${CP_URL}" "${HARNESS_URL}"; do
      case "${u}" in
        *[\|\&\\]*)
          echo "    PARENT=opencode: URL '${u}' contains a sed metacharacter (|, &, or \\\\); set CP_URL/HARNESS_URL without one" >&2
          exit 1
          ;;
      esac
    done
    sed -e "s|__CP_URL__|${CP_URL}|g" \
        -e "s|__HARNESS_URL__|${HARNESS_URL}|g" \
        "${SCRIPT_DIR}/parents/opencode/run-opencode.sh.in" \
        > "${SCRATCH_DIR}/run-opencode.sh"
    chmod +x "${SCRATCH_DIR}/run-opencode.sh"
    ;;
esac

# Flatten the fixture into the scratch dir, so the parent's cwd IS the project.
# This matches the upstream moca-delegate-task skill's "the project is in your
# working directory" assumption; operator prompts can pack `.` instead of
# `./example_repo`. Parent-side bookkeeping (`leaves/`, `MOCA.md`, `.envrc`)
# is kept out of each leaf's workload by `.gitignore` below -- contextctl ctx
# pack honors it. `.claude/` is skipped by contextctl directly; `.opencode/`
# is not, so it is listed in the gitignore below for the opencode parent.
# Python bytecode (`__pycache__/`, `*.pyc`, `*.pyo`) is filtered by the
# fixture's own .gitignore inside the project tree.
cp -R "${SCRIPT_DIR}/example_repo/." "${SCRATCH_DIR}/"

# `git init` on the scratch dir so contextctl's .gitignore walk finds both the
# fixture's own rules (copied in above) and the bookkeeping-ignore rules below.
# The .git/ itself is skipped by contextctl. (-q so the init line doesn't drown
# out the summary; -b main so no "fallback to master" warning on newer git.)
git -C "${SCRATCH_DIR}" init -q -b main
# APPEND (not overwrite) -- example_repo/.gitignore already lives at the root
# with the fixture's pyc rules; this adds the parent-side-bookkeeping lines.
cat >> "${SCRATCH_DIR}/.gitignore" <<'EOF'

# Parent-side bookkeeping (added by setup.sh). The scratch dir is also the
# project, so these paths sit alongside src/, tests/, etc.
/MOCA.md
/.envrc
/.moca-delegate/
/results/
EOF
# Parent-specific ignores: contextctl auto-skips .claude/ but NOT .opencode/,
# so without this the parent-side skill + permission config would leak into
# every leaf's workload. The run-opencode.sh wrapper is parent-side only too.
if [[ "${PARENT}" == "opencode" ]]; then
  cat >> "${SCRATCH_DIR}/.gitignore" <<'EOF'
/.opencode/
/run-opencode.sh
EOF
fi

echo "==> Promoting the two config bundles..."
# Config bundles carry each leaf's skills + commands (NOT CLAUDE.md). They
# travel server-held and content-addressed, picked up at dispatch time via
# `mocactl spawn --config <digest>`. The diagnose leaf runs with the
# public-only posture; the fix leaf runs with the full-access posture.
# Workloads themselves are per-leaf and created by the agent at dispatch
# time (not by setup) — see the moca-delegate-task skill.
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

# Record the two digests + run facts in the scratch dir so a resumed parent
# agent session (or an operator driving the by-hand flow) can reconstruct
# them without re-running `mocactl promote`.
case "${PARENT}" in
  claude)   PARENT_ENV_NOTE="Claude sessions get them from .claude/settings.json;" ;;
  opencode) PARENT_ENV_NOTE="OpenCode sessions get them via ./run-opencode.sh (the wrapper staged by setup.sh — it exports the two URLs then execs opencode);" ;;
esac
cat > "${SCRATCH_DIR}/MOCA.md" <<EOF
# MOCA runtime facts for this demo run

Parent coding agent:   ${PARENT}
Control plane URL:     ${CP_URL}
Harness URL:           ${HARNESS_URL}
Config digest public:  ${DIGEST_PUBLIC}
Config digest full:    ${DIGEST_FULL}
Project to pack:       .   (fixture copied into the scratch root)
Results dir:           ./results   (created on first `mocactl get --out results`)

Every mocactl command run from this directory needs the port-forward URLs
in the environment. ${PARENT_ENV_NOTE}
for a plain shell, export them by hand:

    export SH_CONTROL_PLANE_URL=${CP_URL}
    export SH_HARNESS_URL=${HARNESS_URL}

Notes:
- The diagnose leaf dispatches with '--config ${DIGEST_PUBLIC}' (public-
  posture skill, read-only workload). The fix leaf dispatches with
  '--config ${DIGEST_FULL} --writable' (full-access skill, per-run
  writable copy of the workload).
- The agent packs its cwd (this scratch dir) and creates one workload
  per leaf at dispatch time; those workloads are released after collection.
- Each child's identity is (config digest, workload revision, sessionId) —
  three sha256-pinned handles, all server-held, all reconstructable from
  this file plus the mocactl ledger.
- There is no cancel; a dispatched leaf runs to completion. Results persist
  server-side for 24h — collect with 'mocactl get <sessionId>' inside that
  window.
EOF

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo ""
echo "  1. Port-forwards are backgrounded by prereqs-install.sh (logs:"
echo "     ~/.local/state/moca-chained-demo/). If any are down, re-run"
echo "     ./prereqs-install.sh — it kills stale ones and restarts cleanly."
echo ""
echo "  2. Drive the demo by hand from the scratch dir — the full sequence"
echo "     (spawn, collect, chain) is the demo README's 'Appendix: running"
echo "     the flow by hand':"
echo ""
echo "       cd ${SCRATCH_DIR}"
echo "     Export the two port-forward URLs (also recorded in MOCA.md):"
echo ""
echo "       export SH_CONTROL_PLANE_URL=${CP_URL}"
echo "       export SH_HARNESS_URL=${HARNESS_URL}"
echo ""
echo "     The two config digests to dispatch leaves with are in MOCA.md."
echo ""
case "${PARENT}" in
  claude)
    echo "  3. Or start Claude from the scratch dir and drive it with operator"
    echo "     prompts (the agent flow — see the README's 'Run a session'):"
    echo ""
    echo "       cd ${SCRATCH_DIR} && claude"
    ;;
  opencode)
    echo "  3. Or start OpenCode from the scratch dir and drive it with operator"
    echo "     prompts (the agent flow — see the README's 'Run a session'). The"
    echo "     wrapper exports the port-forward URLs before launching:"
    echo ""
    echo "       ${SCRATCH_DIR}/run-opencode.sh"
    ;;
esac
