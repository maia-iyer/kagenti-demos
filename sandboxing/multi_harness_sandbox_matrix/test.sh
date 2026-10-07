#!/usr/bin/env bash
# Run every test that does not need a cluster.
#
# Phase 0's substrate leg requires a kind cluster with Substrate deployed, so
# it is verified by ./smoke.sh --backend=substrate rather than here. What runs
# here is everything that pins a contract: the Go backend interface, the
# substrate upload-ceiling preflight, and the Pi extension's two halves.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${MATRIX_RUN_DIR:-${SCRIPT_DIR}/run}"
fail=0

echo "=== Go: backend contract + substrate preflight ==="
(cd "${SCRIPT_DIR}/common" && go vet ./... && go test ./...) || fail=1

# The Pi tests shell out to harness-exec, so it has to exist first.
if [[ ! -x "${RUN_DIR}/bin/harness-exec" ]]; then
  echo ""
  echo "=== Building harness-exec (needed by the Pi tests) ==="
  mkdir -p "${RUN_DIR}/bin"
  (cd "${SCRIPT_DIR}/common" && go build -o "${RUN_DIR}/bin/harness-exec" ./cmd/harness-exec)
fi

echo ""
echo "=== Pi M1: exec contract (onData/timeout/abort/exit semantics) ==="
# Uses the local backend, so no cluster. tsx can load ops.ts because it
# imports nothing from Pi at runtime.
npx -y tsx "${SCRIPT_DIR}/pi/m1/ops_test.mjs" || fail=1

echo ""
echo "=== Pi M1: extension registration ==="
# Loads the real Pi package via the jiti bundled with Pi; skips cleanly if Pi
# is not installed.
node "${SCRIPT_DIR}/pi/m1/run_register_test.mjs" || fail=1

echo ""
if [[ $fail -eq 0 ]]; then
  echo "All cluster-free tests passed."
  echo ""
  echo "Not covered here (needs a cluster):"
  echo "  ./smoke.sh --backend=substrate   # uname -s must return Linux"
else
  echo "FAILURES above." >&2
fi
exit $fail
