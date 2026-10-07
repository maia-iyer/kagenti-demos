#!/usr/bin/env bash
# Phase 0 smoke test: does redirection happen at all?
#
# N=1, scored by eye, no corpus dependency. The whole check is that
# `uname -s` returns Linux through the substrate backend and Darwin through
# the local one. Two backends rather than one on purpose: a single passing
# result cannot distinguish a working sandbox from an abstraction that only
# ever had one code path.
#
# This exercises harness-exec directly, NOT a harness. It is the floor the
# Pi M1 extension stands on -- if this fails, no harness work can succeed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${MATRIX_RUN_DIR:-${SCRIPT_DIR}/run}"
HARNESS_EXEC="${RUN_DIR}/bin/harness-exec"

BACKEND="local"
for arg in "$@"; do
  case "$arg" in
    --backend=*) BACKEND="${arg#*=}" ;;
    -h|--help)   echo "usage: ./smoke.sh [--backend=local|substrate]"; exit 0 ;;
    *)           echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$HARNESS_EXEC" ]]; then
  echo "harness-exec not built at ${HARNESS_EXEC} -- run ./setup.sh first" >&2
  exit 1
fi

# A fresh workspace per run, named rather than mktemp'd so a failure is still
# inspectable afterward.
WS="${RUN_DIR}/workspaces/smoke-${BACKEND}-$$"
mkdir -p "$WS"
printf 'phase 0 smoke test\n' > "$WS/marker.txt"

declare -a EXTRA=()
if [[ "$BACKEND" == "substrate" ]]; then
  # A per-run actor, managed by the backend: created and resumed on first
  # use, suspended on Close. Phase 0 question 6 (actor lifetime) is why this
  # is explicit rather than assumed.
  EXTRA+=(--actor="smoke-$$" --manage)
fi

echo "=== uname -s through the ${BACKEND} backend ==="
set +e
UNAME_OUT="$("$HARNESS_EXEC" --backend="$BACKEND" --workspace="$WS" ${EXTRA[@]+"${EXTRA[@]}"} -- uname -s 2>&1)"
UNAME_RC=$?
set -e
echo "$UNAME_OUT"
echo "exit=${UNAME_RC}"

if [[ $UNAME_RC -ne 0 ]]; then
  echo ""
  echo "RESULT: FAIL -- harness-exec exited ${UNAME_RC}"
  echo "        workspace left at ${WS} for inspection"
  exit 1
fi

HOST_KERNEL="$(uname -s)"
echo ""
case "$BACKEND" in
  substrate)
    if [[ "$UNAME_OUT" == *Linux* ]]; then
      echo "RESULT: PASS -- Linux from the actor (host is ${HOST_KERNEL})"
    else
      echo "RESULT: FAIL -- expected Linux from the actor, got: ${UNAME_OUT}"
      echo "        workspace left at ${WS} for inspection"
      exit 1
    fi
    ;;
  local)
    if [[ "$UNAME_OUT" == *"$HOST_KERNEL"* ]]; then
      echo "RESULT: PASS -- ${HOST_KERNEL} from the laptop, as the control case should be"
      echo "        (this is the seam proving itself: the same call through"
      echo "         --backend=substrate must NOT say ${HOST_KERNEL})"
    else
      echo "RESULT: FAIL -- expected ${HOST_KERNEL} locally, got: ${UNAME_OUT}"
      exit 1
    fi
    ;;
esac

# The workspace round-trip matters separately from the kernel name: a sandbox
# that runs Linux but cannot see the files is not yet useful.
echo ""
echo "=== workspace round-trip ==="
set +e
CAT_OUT="$("$HARNESS_EXEC" --backend="$BACKEND" --workspace="$WS" ${EXTRA[@]+"${EXTRA[@]}"} -- cat marker.txt 2>&1)"
CAT_RC=$?
set -e
echo "$CAT_OUT"
if [[ $CAT_RC -eq 0 && "$CAT_OUT" == *"phase 0 smoke test"* ]]; then
  echo "RESULT: PASS -- workspace visible to the backend"
else
  echo "RESULT: FAIL -- workspace not visible (exit ${CAT_RC})"
  echo "        workspace left at ${WS} for inspection"
  exit 1
fi

rm -rf "$WS"
