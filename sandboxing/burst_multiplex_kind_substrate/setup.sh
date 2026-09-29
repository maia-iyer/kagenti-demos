#!/usr/bin/env bash
# Set up the burst_multiplex_kind_substrate demo.
#
# Assumes the autoscaled-workerpool demo is already deployed on a kind cluster
# (see README). This script does the demo-specific setup:
#   1. Pin the counter workerpool to POOL_REPLICAS (default 3), overriding the HPA.
#   2. Create the "burst" atespace where the load actors live.
#   3. Spawn NUM_ACTORS (default 300) counter actors in parallel.

set -euo pipefail

ATESPACE="${ATESPACE:-burst}"
NUM_ACTORS="${NUM_ACTORS:-300}"
POOL_REPLICAS="${POOL_REPLICAS:-3}"
POOL_NS="ate-demo-autoscaled-workerpool"
POOL="counter"
TEMPLATE="${POOL_NS}/counter"
CREATE_PARALLELISM="${CREATE_PARALLELISM:-20}"

echo "==> Preflight: workerpool ${POOL_NS}/${POOL} must exist..."
if ! kubectl -n "${POOL_NS}" get workerpool "${POOL}" >/dev/null 2>&1; then
  cat >&2 <<EOF
    workerpool ${POOL_NS}/${POOL} not found.

    Deploy the upstream demo first, from your substrate/ checkout:

        ./hack/install-ate-kind.sh --deploy-demo-autoscaled-workerpool

EOF
  exit 1
fi

echo "==> Pinning HPA counter to min=max=${POOL_REPLICAS} (static pool)..."
kubectl -n "${POOL_NS}" patch hpa "${POOL}" --type=merge \
  -p "{\"spec\":{\"minReplicas\":${POOL_REPLICAS},\"maxReplicas\":${POOL_REPLICAS}}}"

echo "==> Scaling workerpool/${POOL} to ${POOL_REPLICAS} replicas..."
kubectl -n "${POOL_NS}" scale workerpool/"${POOL}" --replicas="${POOL_REPLICAS}"

echo "==> Waiting for workerpool pods to be Ready..."
kubectl -n "${POOL_NS}" wait --for=condition=Ready pod \
  -l ate.dev/worker-pool="${POOL}" --timeout=180s

echo "==> Creating atespace ${ATESPACE} (idempotent)..."
if ! kubectl ate create atespace "${ATESPACE}" 2>&1 | tee /tmp/ate-create.log; then
  if grep -q -i "already exists\|AlreadyExists" /tmp/ate-create.log; then
    echo "    (atespace already exists — that's fine)"
  else
    echo "    atespace create failed; see /tmp/ate-create.log" >&2
    exit 1
  fi
fi

echo "==> Spawning ${NUM_ACTORS} actors in ${ATESPACE} (parallelism=${CREATE_PARALLELISM})..."
# Serial create x 300 takes minutes; parallelize via xargs -P. Tolerate re-runs:
# each create's stdout+stderr is captured, and "already exists" is treated as success.
seq -w 1 "${NUM_ACTORS}" | xargs -n1 -P"${CREATE_PARALLELISM}" -I{} bash -c '
  name="b$1"
  out=$(kubectl ate create actor "$name" -a "$2" --template "$3" 2>&1) || {
    if echo "$out" | grep -q -i "already exists\|AlreadyExists"; then
      exit 0
    fi
    echo "    create $name failed: $out" >&2
    exit 1
  }
' _ {} "${ATESPACE}" "${TEMPLATE}"

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo ""
echo "  1. In two separate terminals, start port-forwards:"
echo ""
echo "       kubectl port-forward -n ate-system svc/atenet-router 8000:80"
echo "       kubectl port-forward -n ate-system svc/atenet-router 9091:9090"
echo ""
echo "  2. Paste the commands printed by ./watch.sh into 3–4 more terminals."
echo ""
echo "  3. Drive load:"
echo ""
echo "       ./load.sh"
echo ""
echo "  If the default 5s parking budget sheds requests on your laptop, run"
echo "  ./crank.sh to bump it to 30s and try again."
