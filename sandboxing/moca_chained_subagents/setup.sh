#!/usr/bin/env bash
# Set up the moca_chained_subagents demo on MOCA's Kubernetes deployment.
#
# Assumes MOCA (rossoctl/moca) is already installed on the current kubectl
# context via deploy/k8s/setup.sh, and that both port-forwards are running.
# This script does the demo-specific setup:
#   1. Obtain an API token (via mocactl) and check an inference credential exists.
#   2. Create ONE session for the chain; every leaf is a turn in it.
#   3. Seed example_repo/ into that session's sandbox workspace with a
#      bootstrap turn, and widen the workspace idle timeout so a paused demo
#      does not lose its files.
#   4. Stage settings and skill into a scratch directory for a Claude session.
#
# This script does NOT stand up MOCA. See the demo README prerequisites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MOCA_NS="${MOCA_NS:-moca}"
SANDBOX_NS="${SANDBOX_NS:-moca-sandbox}"
# The control plane tells clients where the harness is, and deploy/k8s
# advertises it as http://127.0.0.1:8080 — so the supervisor's port-forward
# must use local port 8080 specifically.
HARNESS_PORT="${HARNESS_PORT:-8080}"
CP_PORT="${CP_PORT:-8090}"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:${HARNESS_PORT}}"
CP_URL="${CP_URL:-http://127.0.0.1:${CP_PORT}}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"
# How long a sandbox workspace survives with no tool call before MOCA reclaims
# it. The default is 30m, which is short enough that "dispatch diagnose, go to
# lunch, dispatch fix" loses the seeded repo. The demo widens it so the pause
# the demo is built to show is actually safe.
WORKSPACE_IDLE="${WORKSPACE_IDLE:-8h}"

echo "==> Prerequisite checks..."

for bin in kubectl curl jq tar base64; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "    missing required binary: ${bin}" >&2
    exit 1
  fi
done

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

echo "    ok: kubectl, curl, jq, tar, base64 on PATH"
echo "    ok: namespaces ${MOCA_NS} and ${SANDBOX_NS} exist"

echo "==> Checking both port-forwards are up..."
cp_code="$(curl -sS -o /dev/null -w '%{http_code}' "${CP_URL}/healthz" 2>/dev/null || echo '000')"
if ! echo "${cp_code}" | grep -qE '^(200|204|404)$'; then
  echo "    cannot reach the control plane at ${CP_URL} (HTTP ${cp_code})." >&2
  echo "    Start it in another terminal:" >&2
  echo "      kubectl port-forward -n ${MOCA_NS} svc/moca-control-plane ${CP_PORT}:8080" >&2
  exit 1
fi
h_code="$(curl -sS -o /dev/null -w '%{http_code}' "${HARNESS_URL}/healthz" 2>/dev/null || echo '000')"
if ! echo "${h_code}" | grep -qE '^(200|204|401|404)$'; then
  echo "    cannot reach the harness at ${HARNESS_URL} (HTTP ${h_code})." >&2
  echo "    Start it in another terminal (local port must be ${HARNESS_PORT}):" >&2
  echo "      kubectl port-forward -n ${MOCA_NS} svc/moca-supervisor ${HARNESS_PORT}:8080" >&2
  exit 1
fi
echo "    ok: control plane (HTTP ${cp_code}), harness (HTTP ${h_code})"

echo "==> Obtaining an API token..."
# Tokens live in header files, never on a command line: argv is world-readable
# through ps. Everything under .moca-auth/ is 0600 and teardown.sh removes it.
AUTH_DIR="${SCRATCH_DIR}/.moca-auth"
mkdir -p "${AUTH_DIR}"
chmod 700 "${AUTH_DIR}"
API_HDR="${AUTH_DIR}/api.hdr"

API_TOKEN=""
if [ -n "${MOCA_API_TOKEN:-}" ]; then
  API_TOKEN="${MOCA_API_TOKEN}"
  echo "    using MOCA_API_TOKEN from the environment"
elif command -v mocactl >/dev/null 2>&1; then
  rc=0
  API_TOKEN="$(mocactl --control-plane-url "${CP_URL}" auth token 2>/dev/null)" || rc=$?
  if [ "${rc}" -ne 0 ] || [ -z "${API_TOKEN}" ]; then
    case "${rc}" in
      3) echo "    not logged in. Run:  mocactl --control-plane-url ${CP_URL} login" >&2 ;;
      4) echo "    mocactl could not reach the control plane at ${CP_URL}." >&2 ;;
      *) echo "    'mocactl auth token' failed (exit ${rc})." >&2 ;;
    esac
    exit 1
  fi
  echo "    ok: token from mocactl"
else
  echo "    no API token available: mocactl is not installed and MOCA_API_TOKEN is unset." >&2
  echo "    Either install mocactl and run 'mocactl login', or mint a token in-cluster:" >&2
  echo "      kubectl -n ${MOCA_NS} exec deploy/moca-control-plane -c control-plane -- \\" >&2
  echo "        node --import tsx --input-type=module -e \"...\"   # see deploy/k8s/smoke.sh" >&2
  echo "    then re-run with MOCA_API_TOKEN=<token>" >&2
  exit 1
fi
( umask 077; printf 'Authorization: Bearer %s\n' "${API_TOKEN}" >"${API_HDR}" )
unset API_TOKEN

echo "==> Checking for an inference credential..."
# Session creation itself fails without one. The operator-key fallback
# (SH_ALLOW_OPERATOR_FALLBACK) is NOT available on this deployment: it also
# needs SH_OPERATOR_INFERENCE_TOKEN, which this slice does not wire, so turning
# it on makes the control plane refuse to boot. A per-user credential is the
# only supported path here.
creds_body="$(curl -sS -H @"${API_HDR}" "${CP_URL}/v1/credentials" 2>/dev/null || echo '{}')"
inference_names="$(printf '%s' "${creds_body}" \
  | jq -r '[(.credentials // [])[] | select(.consumer == "inference") | .name] | join(" ")' 2>/dev/null || true)"
inference_count="$(printf '%s' "${inference_names}" | wc -w | tr -d ' ')"

if [ "${inference_count}" -eq 0 ]; then
  echo "    no inference credential stored for this user." >&2
  echo "    MOCA issues inference credentials per user, and session creation" >&2
  echo "    fails without one. Add your Anthropic key:" >&2
  echo "" >&2
  echo "      printf %s \"\$ANTHROPIC_API_KEY\" | mocactl --control-plane-url ${CP_URL} \\" >&2
  echo "        credentials add anthropic --host api.anthropic.com \\" >&2
  echo "        --kind api-key --endpoint https://api.anthropic.com" >&2
  echo "" >&2
  echo "    then re-run this script." >&2
  exit 1
fi

SESSION_BODY='{}'
if [ "${inference_count}" -gt 1 ]; then
  if [ -z "${MOCA_INFERENCE_CRED:-}" ]; then
    echo "    you have ${inference_count} inference credentials (${inference_names})." >&2
    echo "    MOCA auto-selects only when there is exactly one. Pick one:" >&2
    echo "      MOCA_INFERENCE_CRED=<name> ./setup.sh" >&2
    exit 1
  fi
  SESSION_BODY="$(jq -n --arg n "${MOCA_INFERENCE_CRED}" '{credentials:{inference:$n}}')"
  echo "    ok: using inference credential '${MOCA_INFERENCE_CRED}'"
else
  echo "    ok: one inference credential (${inference_names}) — auto-selected"
fi

echo "==> Widening the sandbox workspace idle timeout to ${WORKSPACE_IDLE}..."
# Do this BEFORE creating the session: it rolls the sandbox pods, which is
# harmless now and would destroy a seeded workspace later.
if kubectl -n "${SANDBOX_NS}" set env statefulset/moca-sandbox \
     "SH_WORKSPACE_IDLE=${WORKSPACE_IDLE}" >/dev/null 2>&1; then
  kubectl -n "${SANDBOX_NS}" rollout status statefulset/moca-sandbox --timeout=180s >/dev/null 2>&1 || true
  echo "    ok: SH_WORKSPACE_IDLE=${WORKSPACE_IDLE}"
else
  echo "    warning: could not set SH_WORKSPACE_IDLE; the 30m default applies." >&2
  echo "    A chain paused longer than 30m between leaves will lose its files." >&2
fi

echo "==> Creating the session for this chain..."
# ONE session for the whole chain. Every leaf is a turn in it, so every leaf
# shares the sandbox workspace at /workspace/<sessionId> — that is what lets a
# fix leaf see the files a diagnose leaf examined. MOCA generates the id.
resp="$(curl -sS -w '\n%{http_code}' \
  -X POST -H @"${API_HDR}" -H 'Content-Type: application/json' \
  -d "${SESSION_BODY}" "${CP_URL}/v1/sessions")" \
  || { echo "    cannot reach the control plane at ${CP_URL}." >&2; exit 1; }
http_code="$(printf '%s' "${resp}" | tail -1)"
body="$(printf '%s' "${resp}" | sed '$d')"
if [ "${http_code}" != "200" ] && [ "${http_code}" != "201" ]; then
  echo "    session creation failed (HTTP ${http_code})." >&2
  echo "    body: ${body}" >&2
  exit 1
fi
SESSION_ID="$(printf '%s' "${body}" | jq -r '.sessionId // empty')"
[ -n "${SESSION_ID}" ] || { echo "    control plane returned no sessionId. body: ${body}" >&2; exit 1; }
SESSION_TOKEN="$(printf '%s' "${body}" | jq -r '.token // empty')"
[ -n "${SESSION_TOKEN}" ] || { echo "    control plane returned no session token." >&2; exit 1; }
SESS_HDR="${AUTH_DIR}/session.hdr"
( umask 077; printf 'Authorization: Bearer %s\n' "${SESSION_TOKEN}" >"${SESS_HDR}" )
unset SESSION_TOKEN
echo "    ok: session ${SESSION_ID}"
WORKSPACE="/workspace/${SESSION_ID}"

echo "==> Seeding example_repo/ into ${WORKSPACE} via a bootstrap turn..."
# The workspace is created lazily on the session's first tool call, and which
# sandbox pod serves the session is not decided until then either — so there is
# nothing to 'kubectl cp' into yet. Instead the agent writes the fixture
# itself, which creates the workspace, pins the sandbox and seeds the files in
# one step.
#
# The payload is a base64 tarball, not a list of files to retype: the fixture's
# whole value is one specific planted bug, and a model asked to reproduce
# source files from a prompt may silently normalise or "fix" it while typing.
# Decoding is deterministic; transcription is not.
PAYLOAD="$(cd "${SCRIPT_DIR}" && tar czf - example_repo | base64 | tr -d '\n')"
SENTINEL=".moca-fixture-seeded"

BOOTSTRAP_PROMPT="$(cat <<EOF
Run exactly these commands in your current working directory and report the
output of the last two. Do not modify, reformat, or "fix" any file you extract
— the repository contains a deliberate bug that a later task must diagnose.

cat > /tmp/fixture.b64 <<'PAYLOAD_EOF'
${PAYLOAD}
PAYLOAD_EOF
base64 -d /tmp/fixture.b64 > /tmp/fixture.tgz
tar xzf /tmp/fixture.tgz --strip-components=1
touch ${SENTINEL}
rm -f /tmp/fixture.b64 /tmp/fixture.tgz
pwd && hostname
ls -la
EOF
)"

boot_sse="${AUTH_DIR}/bootstrap.sse"
# A plain (non-detachable) SSE turn: setup should wait for seeding to finish.
boot_code="$(curl -sN --max-time 300 \
  -X POST -H @"${SESS_HDR}" \
  -H 'Accept: text/event-stream' -H 'Content-Type: application/json' \
  -o "${boot_sse}" -w '%{http_code}' \
  -d "$(jq -n --arg s "${SESSION_ID}" --arg p "${BOOTSTRAP_PROMPT}" \
        '{sessionId:$s, prompt:$p}')" \
  "${HARNESS_URL}/v1/turn" 2>/dev/null)" || boot_code='000'

if [ "${boot_code}" != "200" ]; then
  echo "    bootstrap turn failed (HTTP ${boot_code})." >&2
  echo "    transcript: ${boot_sse}" >&2
  exit 1
fi

boot_term="$(sed -n 's/^data: //p' "${boot_sse}" \
  | jq -c 'select(.type == "done" or .type == "error")' 2>/dev/null | tail -1 || true)"
if [ -z "${boot_term}" ] || [ "$(printf '%s' "${boot_term}" | jq -r '.type')" != "done" ]; then
  echo "    the bootstrap turn did not complete successfully." >&2
  echo "    transcript: ${boot_sse}" >&2
  [ -n "${boot_term}" ] && printf '    %s\n' "$(printf '%s' "${boot_term}" | jq -c .)" >&2
  exit 1
fi

# Confirm the fixture actually landed, rather than trusting the model's prose.
SANDBOX_POD="$(kubectl -n "${SANDBOX_NS}" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
  | tr ' ' '\n' | while read -r p; do
      [ -n "${p}" ] || continue
      if kubectl -n "${SANDBOX_NS}" exec "${p}" -c sandbox -- \
           test -f "${WORKSPACE}/${SENTINEL}" >/dev/null 2>&1; then
        echo "${p}"; break
      fi
    done || true)"

if [ -z "${SANDBOX_POD}" ]; then
  echo "    could not verify the fixture on any sandbox pod." >&2
  echo "    Expected ${WORKSPACE}/${SENTINEL} to exist." >&2
  echo "    transcript: ${boot_sse}" >&2
  exit 1
fi
if ! kubectl -n "${SANDBOX_NS}" exec "${SANDBOX_POD}" -c sandbox -- \
       test -f "${WORKSPACE}/package.json" >/dev/null 2>&1; then
  echo "    the sentinel exists on ${SANDBOX_POD} but package.json does not —" >&2
  echo "    the archive did not extract as expected. transcript: ${boot_sse}" >&2
  exit 1
fi
echo "    ok: fixture verified on ${SANDBOX_POD} at ${WORKSPACE}"

echo "==> Staging scratch dir at ${SCRATCH_DIR}..."

mkdir -p "${SCRATCH_DIR}/.claude/skills"
mkdir -p "${SCRATCH_DIR}/.moca-runs"
mkdir -p "${SCRATCH_DIR}/bin"
cp "${SCRIPT_DIR}/settings.json.example" \
   "${SCRATCH_DIR}/.claude/settings.json"
rm -rf "${SCRATCH_DIR}/.claude/skills/moca-dispatch"
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

Control plane URL:  ${CP_URL}
Harness URL:        ${HARNESS_URL}
Session id:         ${SESSION_ID}
Workspace:          ${WORKSPACE}
Sandbox pod:        ${SANDBOX_POD}
Sandbox namespace:  ${SANDBOX_NS}

## How dispatch works

There are TWO origins. The control plane (${CP_URL}) owns sessions and
credentials; the harness (${HARNESS_URL}) runs turns. They take different
tokens: an API token for the control plane, and a SESSION token — minted per
session, valid about 300 seconds — for the harness. The moca CLI re-mints a
session token immediately before every harness call, so expiry never matters.

Dispatch is a DETACHABLE TURN. 'moca start' POSTs to ${HARNESS_URL}/v1/turn
with {"detachable":true}, reads the stream only long enough to learn the turn
id, and walks away. MOCA does not abort a detachable turn when its client
disconnects — it writes every frame to a server-side log instead. So the leaf
keeps running with nothing held open locally.

'moca check' COLLECTS by reattaching: GET ${HARNESS_URL}/v1/turn?sessionId=...
replays the turn from the beginning and follows it if it is still running. A
finished turn replays in full for 24 HOURS, so a result survives quitting
Claude Code, closing the laptop, and rebooting.

## One session, one workspace

Every leaf in this chain is a turn in session ${SESSION_ID}, so every leaf
shares the sandbox workspace at ${WORKSPACE}. That is what lets a fix leaf see
the files a diagnose leaf examined. Two consequences:

  - Leaves must run SEQUENTIALLY. A session runs one turn at a time; a second
    concurrent turn is refused with HTTP 409 turn_in_progress.
  - Leaves are not isolated from each other. The isolation boundary is this
    chain versus anything else, not leaf versus leaf.

The workspace is reclaimed after ${WORKSPACE_IDLE} with no tool call, and is
lost outright if the sandbox pod restarts (it is container-local, with no
volume). The turn log in Redis is unaffected by either.

## Timeouts worth knowing

  - A turn that runs more than 30 minutes with NOBODY attached is aborted with
    abortReason "unwatched". Running 'moca check' counts as attaching.
  - A supervisor restart aborts detached turns (abortReason "restarting").
  - Both are infrastructure outcomes, not findings about the code.

Run records live in .moca-runs/ and the API token in .moca-auth/ — see the
moca-dispatch skill. Leaf labels (e.g. "diagnose", "fix") name records locally;
they are not session ids.
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
echo "  2. Start Claude from the scratch dir:"
echo ""
echo "       cd ${SCRATCH_DIR} && claude"
echo ""
echo "  3. The demo flow is operator prompts; dispatch is a detachable turn."
echo "     Suggested first prompt:"
echo ""
echo "       There's a Node.js project at ${WORKSPACE} on MOCA."
echo "       Dispatch a subagent to diagnose why its tests are failing."
echo ""
echo "     Claude will start the leaf and return control immediately."
echo "     You can quit Claude entirely and come back later — the turn runs"
echo "     cluster-side and its result is collectable for 24h. When you're"
echo "     ready to collect the diagnosis, say:"
echo ""
echo "       Check on that subagent and report the diagnosis."
echo ""
echo "     Then, after reviewing the diagnosis:"
echo ""
echo "       Good. Dispatch another subagent to apply that fix, run the"
echo "       tests, and report the diff and outcome. Check on it when it's done."
echo ""
echo "  4. Watch the work land in the sandbox:"
echo ""
echo "       kubectl -n ${SANDBOX_NS} exec ${SANDBOX_POD} -c sandbox -- \\"
echo "         ls -la ${WORKSPACE}"
echo ""
echo "     The harness runs in the moca-supervisor pod (namespace ${MOCA_NS});"
echo "     the agent's tool calls execute in ${SANDBOX_POD} (namespace"
echo "     ${SANDBOX_NS}). Both are warm — nothing scales to zero."
