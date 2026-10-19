#!/usr/bin/env bash
# Tear down the demo-specific resources created by setup.sh.
#
# Does NOT touch the MOCA install, Context Service, or the kind cluster.
# Those are prerequisites, not owned by this demo. Your mocactl login and
# stored credentials are also yours — not touched.
#
# Run this AFTER collecting every leaf you care about: deleting a session
# makes its stored result unreachable, so any uncollected answer is lost.

set -euo pipefail

MOCA_NS="${MOCA_NS:-moca}"
SANDBOX_NS="${SANDBOX_NS:-moca-sandbox}"
SANDBOX_POD_SELECTOR="${SANDBOX_POD_SELECTOR:-app=moca-sandbox}"
SANDBOX_CONTAINER="${SANDBOX_CONTAINER:-sandbox}"
HARNESS_PORT="${HARNESS_PORT:-8080}"
CP_PORT="${CP_PORT:-8090}"
HARNESS_URL="${HARNESS_URL:-http://127.0.0.1:${HARNESS_PORT}}"
CP_URL="${CP_URL:-http://127.0.0.1:${CP_PORT}}"
SCRATCH_DIR="${SCRATCH_DIR:-$HOME/tmp/moca-chained-scratch}"
# Constant: scopes `mocactl subagents --tag` to this demo's leaves on
# the machine-global ledger. Must match the tag used in operator prompts.
TAG="moca-chained-subagents-demo"

# mocactl needs the port-forwards to list sessions, delete sessions, and
# delete the workload.
export SH_CONTROL_PLANE_URL="${CP_URL}"
export SH_HARNESS_URL="${HARNESS_URL}"

echo "==> Collecting this demo's leaf sessions..."
SESSION_IDS=""
if command -v mocactl >/dev/null 2>&1; then
  if listing="$(mocactl subagents --tag "${TAG}" --json 2>/dev/null)"; then
    SESSION_IDS="$(printf '%s' "${listing}" \
      | jq -r '.subagents[]?.sessionId' 2>/dev/null || true)"
  else
    echo "    (mocactl could not list the tag's subagents — port-forward down?)" >&2
  fi
fi
# Union with the parent's per-leaf notes in the scratch dir, so teardown
# still works when mocactl cannot reach the cluster. Workload ids live
# only on the notes (one per leaf — there is no shared workload anymore).
WORKLOAD_IDS=""
if [[ -d "${SCRATCH_DIR}/leaves" ]]; then
  for note in "${SCRATCH_DIR}"/leaves/*.json; do
    [[ -e "${note}" ]] || continue
    sid="$(jq -r '.sessionId // empty' "${note}" 2>/dev/null || true)"
    if [[ -n "${sid}" ]]; then
      SESSION_IDS="$(printf '%s\n%s' "${SESSION_IDS}" "${sid}")"
    fi
    wid="$(jq -r '.workloadId // empty' "${note}" 2>/dev/null || true)"
    if [[ -n "${wid}" ]]; then
      WORKLOAD_IDS="$(printf '%s\n%s' "${WORKLOAD_IDS}" "${wid}")"
    fi
  done
fi
SESSION_IDS="$(printf '%s\n' "${SESSION_IDS}" | sed '/^$/d' | sort -u)"
WORKLOAD_IDS="$(printf '%s\n' "${WORKLOAD_IDS}" | sed '/^$/d' | sort -u)"

if [[ -z "${SESSION_IDS}" ]]; then
  echo "    (no leaf sessions found for this demo; nothing to delete)"
else
  for sid in ${SESSION_IDS}; do
    if mocactl sessions delete "${sid}" >/dev/null 2>&1; then
      echo "    deleted session ${sid}"
    else
      echo "    could not delete session ${sid} (already gone?)" >&2
      echo "      delete it later with:  mocactl sessions delete ${sid}" >&2
    fi
  done
fi

echo "==> Deleting leftover workloads..."
# The agent is expected to delete each leaf's workload after collecting
# its result, so this step is a no-op in the normal case. It catches
# workloads from leaves the operator abandoned (dispatched but never
# collected). Writable per-run copies are discarded when the run ends;
# the shared read-only cache is released by DELETE /workloads/{id}.
if [[ -z "${WORKLOAD_IDS}" ]]; then
  echo "    (no workload ids in leaf notes; nothing to delete)"
else
  for wid in ${WORKLOAD_IDS}; do
    if mocactl workloads delete "${wid}" >/dev/null 2>&1; then
      echo "    deleted workload ${wid}"
    else
      echo "    could not delete workload ${wid} (already gone?)"
    fi
  done
fi

echo "==> Removing this demo's per-session dirs from sandbox pods..."
# MOCA's remote-worker creates /workspace/<sessionId>/ on first Exec for every
# session (workspace-subdir capability). With --workload, the leaf's cwd is
# the workload mount instead, so those directories end up empty but persist
# on the pod until the worker's 30-min idle sweep. Clean up only the
# sessions this demo created, right now, so the pod does not visibly carry
# demo detritus between runs. The sweep would get these eventually anyway;
# this just makes it immediate.
if [[ -z "${SESSION_IDS}" ]]; then
  echo "    (no session ids known; nothing to clean up)"
elif ! command -v kubectl >/dev/null 2>&1; then
  echo "    (kubectl not on PATH; skipping per-session dir cleanup)" >&2
else
  pods="$(kubectl -n "${SANDBOX_NS}" get pods -l "${SANDBOX_POD_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "${pods}" ]]; then
    echo "    (no sandbox pods matched -l ${SANDBOX_POD_SELECTOR} in ns ${SANDBOX_NS}; skipping)" >&2
  else
    for sid in ${SESSION_IDS}; do
      # Guard: ${sid} is a UUID from mocactl, but shell-interpolate carefully
      # since this becomes an rm -rf argument on the pod.
      case "${sid}" in
        [0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*) ;;
        *) echo "    (skipping non-UUID-shaped sid: ${sid})" >&2; continue ;;
      esac
      for pod in ${pods}; do
        if kubectl -n "${SANDBOX_NS}" exec "${pod}" -c "${SANDBOX_CONTAINER}" -- \
          rm -rf "/workspace/${sid}" >/dev/null 2>&1; then
          echo "    removed /workspace/${sid} from ${pod}"
        fi
      done
    done
  fi
fi

echo "==> Removing scratch directory ${SCRATCH_DIR}..."
if [[ -d "${SCRATCH_DIR}" ]]; then
  rm -rf "${SCRATCH_DIR}"
  echo "    removed"
else
  echo "    (already absent)"
fi

echo ""
echo "Teardown complete."
echo ""
echo "Not touched by this script (deliberately — they're prerequisites or yours):"
echo "  - MOCA install in namespaces ${MOCA_NS} and ${SANDBOX_NS}"
echo "  - Context Service install"
echo "  - the kind cluster"
echo "  - your mocactl login and stored credentials"
echo "  - the machine-global subagent ledger (~/.local/state/mocactl/subagents.jsonl)"
echo "    — its rows age out on their own; only the sessions were deleted above"
echo "  - the two port-forwards (Ctrl-C them in their terminals if still running)"
