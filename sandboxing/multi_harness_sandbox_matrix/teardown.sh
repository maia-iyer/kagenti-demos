#!/usr/bin/env bash
# Tear down the multi-harness sandbox matrix.
#
# Two parts, separable on purpose: removing run/ is local and always safe,
# while removing actors touches a shared cluster. A plain ./teardown.sh does
# the local half only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${MATRIX_RUN_DIR:-${SCRIPT_DIR}/run}"
ATESPACE="${ATESPACE:-claude-sandbox}"

ACTORS=0
KEEP_RESULTS=0

usage() {
  cat <<'EOF'
usage: ./teardown.sh [--actors] [--keep-results]

  (default)        Remove run/ -- binaries, workspaces, results, logs.
  --actors         Also suspend and delete the matrix's actors in the cluster.
  --keep-results   Remove workspaces/, bin/, and logs/ but keep results/,
                   so scores survive a rebuild.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --actors)       ACTORS=1 ;;
    --keep-results) KEEP_RESULTS=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $ACTORS -eq 1 ]]; then
  echo "==> Deleting matrix actors in atespace ${ATESPACE}..."
  if ! kubectl ate get actors -a "${ATESPACE}" >/dev/null 2>&1; then
    echo "    Cannot reach the ate api server -- skipping actor cleanup."
    echo "    (Is 'kubectl port-forward -n ate-system svc/api 8080:443' running?)"
  else
    # Only actors this demo creates: smoke-* from smoke.sh and matrix-* from
    # scenario runs. Session actors (sess-*) belong to the Claude Code demo
    # and are left alone.
    actors="$(kubectl ate get actors -a "${ATESPACE}" -o name 2>/dev/null \
      | sed 's|.*/||' | grep -E '^(smoke|matrix)-' || true)"
    if [[ -z "$actors" ]]; then
      echo "    No matrix actors found."
    else
      while read -r actor; do
        [[ -z "$actor" ]] && continue
        echo "    deleting ${actor}"
        kubectl ate suspend actor "${actor}" -a "${ATESPACE}" >/dev/null 2>&1 || true
        kubectl ate delete actor "${actor}" -a "${ATESPACE}" >/dev/null 2>&1 \
          || echo "      (delete failed; may already be gone)"
      done <<< "$actors"
    fi
  fi
fi

if [[ ! -d "$RUN_DIR" ]]; then
  echo "==> ${RUN_DIR} does not exist; nothing local to remove."
  exit 0
fi

if [[ $KEEP_RESULTS -eq 1 ]]; then
  echo "==> Removing ${RUN_DIR}/{bin,workspaces,logs}, keeping results/..."
  rm -rf "${RUN_DIR}"/bin "${RUN_DIR}"/workspaces "${RUN_DIR}"/logs
else
  echo "==> Removing ${RUN_DIR}..."
  rm -rf "${RUN_DIR}"
fi

echo ""
echo "Teardown complete."
if [[ $ACTORS -eq 0 ]]; then
  echo "Cluster actors were left in place; use --actors to remove them."
fi
