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
CREATE_PARALLELISM="${CREATE_PARALLELISM:-20}"

# TEMPLATE_MODE=durable  → reuse the upstream counter template
#   (Full memory snapshot on suspend, durable volume commit on request).
#   Slow suspend/resume, but shows the durable-state story.
# TEMPLATE_MODE=fast     → apply a stripped ActorTemplate (no durable volume,
#   no readyz, no explicit snapshot policies). Cheap suspend/resume; use this
#   flavor to show clean multiplex + parking under a burst.
TEMPLATE_MODE="${TEMPLATE_MODE:-fast}"
FAST_TEMPLATE_NAME="counter-fast"
FAST_TEMPLATE_NS="${POOL_NS}"

case "${TEMPLATE_MODE}" in
  durable) TEMPLATE="${POOL_NS}/counter" ;;
  fast)    TEMPLATE="${FAST_TEMPLATE_NS}/${FAST_TEMPLATE_NAME}" ;;
  *) echo "TEMPLATE_MODE must be 'fast' or 'durable' (got: ${TEMPLATE_MODE})" >&2; exit 2 ;;
esac
echo "==> Template mode: ${TEMPLATE_MODE} (${TEMPLATE})"

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

echo "==> Waiting for workerpool to settle at ${POOL_REPLICAS} ready replicas..."
# Wait on the workerpool's own status rather than `kubectl wait pod ...` — the
# latter races with scale-down: it snapshots the pod list at start and then
# errors "pod not found" if any pod in that snapshot gets deleted mid-wait.
ready=0
total=0
for _ in $(seq 1 60); do
  status="$(kubectl -n "${POOL_NS}" get workerpool "${POOL}" \
    -o jsonpath='{.status.readyReplicas} {.status.replicas}' 2>/dev/null || true)"
  ready="${status% *}"
  total="${status#* }"
  ready="${ready:-0}"
  total="${total:-0}"
  if [[ "${ready}" == "${POOL_REPLICAS}" && "${total}" == "${POOL_REPLICAS}" ]]; then
    echo "    ${ready}/${POOL_REPLICAS} ready"
    break
  fi
  sleep 2
done
if [[ "${ready}" != "${POOL_REPLICAS}" ]]; then
  echo "    workerpool did not settle at ${POOL_REPLICAS} within 120s (got ${ready}/${total})" >&2
  exit 1
fi

if [[ "${TEMPLATE_MODE}" == "fast" ]]; then
  echo "==> Applying stripped ActorTemplate ${FAST_TEMPLATE_NS}/${FAST_TEMPLATE_NAME}..."
  # Reuses the upstream counter image + worker selector, but drops the durable
  # volume, readyz, and Full/Data snapshot policies. Result: suspend/resume
  # goes through gvisor with a minimal snapshot, so a burst can rotate 300
  # actors across 3 workers in seconds instead of minutes.
  UPSTREAM_IMAGE=$(kubectl -n "${POOL_NS}" get actortemplate counter \
    -o jsonpath='{.spec.containers[?(@.name=="counter")].image}')
  if [[ -z "${UPSTREAM_IMAGE}" ]]; then
    echo "    could not read counter image from upstream template" >&2
    exit 1
  fi
  kubectl apply -f - <<EOF
apiVersion: ate.dev/v1alpha1
kind: ActorTemplate
metadata:
  name: ${FAST_TEMPLATE_NAME}
  namespace: ${FAST_TEMPLATE_NS}
spec:
  containers:
  - name: counter
    image: ${UPSTREAM_IMAGE}
    command: ["/ko-app/counter"]
  workerSelector:
    matchLabels:
      workload: counter-autoscaled
  snapshotsConfig:
    location: gs://ate-snapshots/${FAST_TEMPLATE_NAME}/
EOF
fi

echo "==> Creating atespace ${ATESPACE} (idempotent)..."
# Capture the command's own exit status (not tee's — a `... | tee` pipeline's
# exit is tee's, which is always 0 without pipefail, so failures were masked).
if out=$(kubectl ate create atespace "${ATESPACE}" 2>&1); then
  echo "${out}"
else
  echo "${out}"
  if echo "${out}" | grep -q -i "already exists\|AlreadyExists"; then
    echo "    (atespace already exists — that's fine)"
  else
    echo "    atespace create failed" >&2
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
echo "       kubectl port-forward -n ate-system svc/atenet-router 4041:4040"
echo ""
echo "  2. Paste the commands printed by ./watch.sh into 3–4 more terminals."
echo ""
echo "  3. Drive load:"
echo ""
echo "       ./load.sh"
echo ""
echo "  If the default 5s parking budget sheds requests on your laptop, run"
echo "  ./crank.sh to bump it to 30s and try again."
