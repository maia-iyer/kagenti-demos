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
SANDBOX_POD_SELECTOR="${SANDBOX_POD_SELECTOR:-app=moca-sandbox}"
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

echo "==> Removing the seeded workspace from the sandbox pods..."
# setup.sh kubectl-cps the fixture into /workspace/<session-id> on every
# sandbox pod. MOCA's idle sweeper only reclaims a workspace after a turn
# has run in it, so a seeded-but-never-used directory would sit there until
# the pod restarts — remove it by hand.
if [[ -z "${SESSION_ID}" ]]; then
  echo "    (no session id in ${MOCA_MD}; nothing to clean)"
else
  pods="$(kubectl -n "${SANDBOX_NS}" get pods -l "${SANDBOX_POD_SELECTOR}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pods}" ]]; then
    echo "    (no Running sandbox pods matched '${SANDBOX_POD_SELECTOR}'; nothing to clean)"
  else
    for pod in ${pods}; do
      if kubectl -n "${SANDBOX_NS}" exec "${pod}" -c sandbox -- \
           rm -rf "/workspace/${SESSION_ID}" >/dev/null 2>&1; then
        echo "    removed /workspace/${SESSION_ID} from ${pod}"
      else
        echo "    (could not clean ${pod} — pod gone or restarting?)"
      fi
    done
  fi
fi

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
