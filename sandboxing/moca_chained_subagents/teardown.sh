#!/usr/bin/env bash
# Tear down the demo-specific resources created by setup.sh.
#
# Does NOT touch the MOCA install or the kind cluster. Those are
# prerequisites, not owned by this demo.
#
# Run this AFTER collecting every leaf you care about: deleting the session
# makes its turn logs unreachable, so any uncollected answer is lost.

set -euo pipefail

MOCA_NS="${MOCA_NS:-moca}"
SANDBOX_NS="${SANDBOX_NS:-moca-sandbox}"
CP_PORT="${CP_PORT:-8090}"
CP_URL="${CP_URL:-http://127.0.0.1:${CP_PORT}}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"
MOCA_MD="${SCRATCH_DIR}/MOCA.md"
API_HDR="${SCRATCH_DIR}/.moca-auth/api.hdr"

echo "==> Deleting the demo session..."
if [[ -f "${MOCA_MD}" ]]; then
  SESSION_ID="$(grep -E '^Session id:[[:space:]]' "${MOCA_MD}" 2>/dev/null \
    | sed -E 's/^Session id:[[:space:]]+//' | head -1 || true)"
else
  SESSION_ID=""
fi

if [[ -z "${SESSION_ID}" ]]; then
  echo "    (no session id in ${MOCA_MD}; nothing to delete)"
elif [[ ! -f "${API_HDR}" ]]; then
  echo "    (no API token at ${API_HDR}; cannot delete session ${SESSION_ID})"
  echo "    Delete it later with:  mocactl sessions delete ${SESSION_ID}"
else
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X DELETE -H @"${API_HDR}" \
    "${CP_URL}/v1/sessions/${SESSION_ID}" 2>/dev/null || echo '000')"
  case "${code}" in
    200|202|204) echo "    deleted session ${SESSION_ID}" ;;
    404)         echo "    session ${SESSION_ID} already gone" ;;
    000)         echo "    could not reach the control plane at ${CP_URL} (port-forward down?)"
                 echo "    Delete it later with:  mocactl sessions delete ${SESSION_ID}" ;;
    *)           echo "    session delete returned HTTP ${code}"
                 echo "    Delete it later with:  mocactl sessions delete ${SESSION_ID}" ;;
  esac
fi

echo "==> Sandbox workspace..."
# Nothing to clean by hand: the workspace at /workspace/<session-id> is
# container-local (no volume) and MOCA reclaims it once it goes idle past
# SH_WORKSPACE_IDLE. It also disappears whenever the sandbox pod restarts.
echo "    (reclaimed automatically once idle; no action needed)"

echo "==> Restoring the sandbox workspace idle timeout..."
# setup.sh widens SH_WORKSPACE_IDLE so a paused demo keeps its files. Undo
# that so the MOCA install is left as it was found.
if kubectl -n "${SANDBOX_NS}" get statefulset moca-sandbox >/dev/null 2>&1; then
  if kubectl -n "${SANDBOX_NS}" set env statefulset/moca-sandbox \
       SH_WORKSPACE_IDLE- >/dev/null 2>&1; then
    echo "    restored the default (30m)"
  else
    echo "    warning: could not unset SH_WORKSPACE_IDLE" >&2
  fi
else
  echo "    (StatefulSet moca-sandbox not present; nothing to restore)"
fi

echo "==> Removing scratch directory ${SCRATCH_DIR}..."
if [[ -d "${SCRATCH_DIR}" ]]; then
  rm -rf "${SCRATCH_DIR}"
  echo "    removed (including the API token in .moca-auth/)"
else
  echo "    (already absent)"
fi

echo ""
echo "Teardown complete."
echo ""
echo "Not touched by this script (deliberately — they're prerequisites):"
echo "  - MOCA install in namespaces ${MOCA_NS} and ${SANDBOX_NS}"
echo "  - the kind cluster"
echo "  - your mocactl login and stored credentials"
echo "  - the two port-forwards (Ctrl-C them in their terminals if still running)"
