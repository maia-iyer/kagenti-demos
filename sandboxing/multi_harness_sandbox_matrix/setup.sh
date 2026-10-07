#!/usr/bin/env bash
# Set up the multi-harness sandbox redirection matrix.
#
# Phase 0 scope: build common/ into run/bin/ and establish the run/ layout.
# Backend-specific cluster setup is gated behind --backend=substrate, because
# the local backend needs nothing and should stay runnable on a machine with
# no cluster at all.
#
# The run/ root is the single working area for the whole matrix: no script
# here creates a mktemp dir of its own, so a failed scenario leaves an
# inspectable workspace behind under a predictable name.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${MATRIX_RUN_DIR:-${SCRIPT_DIR}/run}"

BACKEND="local"
WORKERPOOL_REPLICAS="${WORKERPOOL_REPLICAS:-5}"
ATESPACE="${ATESPACE:-claude-sandbox}"

usage() {
  cat <<'EOF'
usage: ./setup.sh [--backend=local|substrate] [--replicas=N] [--atespace=NAME]

  --backend=local       (default) Build only. No cluster needed.
  --backend=substrate   Also scale the sandbox workerpool and create the
                        atespace. Requires a kind cluster with Substrate,
                        the counter demo, and the sandbox demo deployed --
                        see README "Prerequisites".
EOF
}

for arg in "$@"; do
  case "$arg" in
    --backend=*)  BACKEND="${arg#*=}" ;;
    --replicas=*) WORKERPOOL_REPLICAS="${arg#*=}" ;;
    --atespace=*) ATESPACE="${arg#*=}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

case "$BACKEND" in
  local|substrate) ;;
  *) echo "--backend must be local or substrate (got: $BACKEND)" >&2; exit 2 ;;
esac

echo "==> Creating run/ layout at ${RUN_DIR}..."
mkdir -p "${RUN_DIR}"/{bin,workspaces,results,logs}
# Restore the committed .gitkeep markers, which teardown.sh removes along
# with everything else under run/. Keeps the tracked layout intact across a
# teardown/setup cycle instead of showing up as deletions in git status.
for d in "" /bin /workspaces /results /logs; do
  touch "${RUN_DIR}${d}/.gitkeep"
done

echo "==> Building harness-exec into ${RUN_DIR}/bin..."
(cd "${SCRIPT_DIR}/common" && go build -o "${RUN_DIR}/bin/harness-exec" ./cmd/harness-exec)

echo "==> Verifying the local backend (control case)..."
# The local backend is the proof the Backend seam is real rather than
# decorative: if substrate later returns Linux here, redirection happened.
if ! uname_out="$("${RUN_DIR}/bin/harness-exec" --backend=local -- uname -s)"; then
  echo "    local backend smoke test FAILED" >&2
  exit 1
fi
echo "    local backend returns: ${uname_out}"

if [[ "$BACKEND" == "substrate" ]]; then
  echo "==> Checking cluster reachability..."
  if ! kubectl ate get atespaces >/dev/null 2>&1; then
    cat >&2 <<EOF
    Cannot reach the ate api server.

    The substrate backend needs a kind cluster with Substrate, the counter
    demo, and the sandbox demo deployed. That is a one-time prerequisite from
    a substrate/ checkout, not part of this demo -- see README
    "Prerequisites". You also need this port-forward running:

        kubectl port-forward -n ate-system svc/api 8080:443
EOF
    exit 1
  fi

  echo "==> Scaling sandbox-workerpool to ${WORKERPOOL_REPLICAS} replicas..."
  kubectl -n ate-demo-sandbox scale workerpool/sandbox-workerpool \
    --replicas="${WORKERPOOL_REPLICAS}"

  echo "==> Waiting for workerpool pods to be Ready..."
  kubectl -n ate-demo-sandbox wait --for=condition=Ready pod \
    -l ate.dev/worker-pool=sandbox-workerpool --timeout=120s

  echo "==> Creating atespace ${ATESPACE} (idempotent)..."
  create_log="${RUN_DIR}/logs/atespace-create.log"
  if ! kubectl ate create atespace "${ATESPACE}" >"${create_log}" 2>&1; then
    if grep -qi "already exists\|AlreadyExists" "${create_log}"; then
      echo "    (atespace already exists -- that's fine)"
    else
      echo "    atespace create failed; see ${create_log}" >&2
      exit 1
    fi
  fi
fi

echo ""
echo "Setup complete (backend: ${BACKEND})."
echo ""
echo "Run the phase 0 smoke test:"
echo ""
echo "    ./smoke.sh --backend=local        # expect Darwin on macOS"
if [[ "$BACKEND" == "substrate" ]]; then
  echo "    ./smoke.sh --backend=substrate    # expect Linux from the actor"
  echo ""
  echo "The substrate leg also needs the router port-forward:"
  echo ""
  echo "    kubectl port-forward -n ate-system svc/atenet-router 8000:80"
else
  echo ""
  echo "For the substrate leg, re-run as: ./setup.sh --backend=substrate"
fi
