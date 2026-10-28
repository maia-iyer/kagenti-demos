#!/usr/bin/env bash
# Install the MOCA + Context Service prerequisites for this demo on a local
# kind cluster. Idempotent: safe to re-run.
#
# What it does, in order:
#   1. Create the kind cluster `moca`.
#   2. Run MOCA's deploy/k8s/setup.sh --target kind --build.
#   3. Point CoreDNS at public resolvers (podman's resolv.conf is flaky).
#   4. Build the context-service image, load it into kind, and apply its
#      manifest patched to live in the `context-service` namespace. The
#      upstream manifest ships `serverless-harness`, but MOCA's supervisor
#      egress NetworkPolicy only allows the namespace literally named
#      `context-service` with pods labelled app.kubernetes.io/name=context-service.
#   5. Create the moca-context-service ConfigMap + Secret, restart the
#      supervisor.
#   6. Background the three port-forwards (supervisor, control plane,
#      context-service public URL) with logs under
#      ~/.local/state/moca-chained-demo/. prereqs-uninstall.sh kills
#      them by matching on `kubectl --context kind-moca ... port-forward`.
#
# What it does NOT do (keep these as operator steps, see README):
#   - Install mocactl / contextctl / kubectl / jq / kind / podman.
#   - mocactl login, credential add, doctor.
#   - Run this demo's own setup.sh.

set -euo pipefail

# Inputs. CLONE_DIR is the parent of both checkouts: MOCA at $CLONE_DIR/moca,
# Context Service at $CLONE_DIR/context-service. Required, no default — point
# it at wherever you cloned the two repos (see README > Checkouts).
: "${CLONE_DIR:?CLONE_DIR is required: parent of the moca/ and context-service/ checkouts (see README > Checkouts)}"

MOCA_DIR="${CLONE_DIR}/moca"
CONTEXT_SERVICE_DIR="${CLONE_DIR}/context-service"

KIND_CLUSTER="${KIND_CLUSTER:-moca}"
KUBE_CONTEXT="kind-${KIND_CLUSTER}"

# Local port-forward ports. If you override these, set the same env vars
# before running ./setup.sh.
HARNESS_PORT="${HARNESS_PORT:-18080}"
CP_PORT="${CP_PORT:-18090}"
CS_PORT="${CS_PORT:-19090}"
HARNESS_URL="http://127.0.0.1:${HARNESS_PORT}"

if [[ -z "${SH_GITHUB_CLIENT_ID:-}" ]]; then
  echo "SH_GITHUB_CLIENT_ID is required (GitHub OAuth app, device-flow enabled)." >&2
  exit 1
fi

for d in "${MOCA_DIR}" "${CONTEXT_SERVICE_DIR}"; do
  if [[ ! -d "${d}" ]]; then
    echo "checkout not found: ${d}" >&2
    exit 1
  fi
done

for bin in kind kubectl docker jq; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "missing: ${bin}" >&2; exit 1; }
done

# A hard requirement upstream: without pi-fork populated the Docker build
# dies at `npm ci` inside the empty submodule.
if [[ -z "$(ls -A "${MOCA_DIR}/pi-fork" 2>/dev/null)" ]]; then
  echo "MOCA pi-fork submodule is empty. Run:" >&2
  echo "  (cd ${MOCA_DIR} && git submodule update --init --recursive)" >&2
  exit 1
fi

echo "==> 1/6 kind cluster ${KIND_CLUSTER}"
if ! kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER}"; then
  kind create cluster --name "${KIND_CLUSTER}"
else
  echo "    cluster ${KIND_CLUSTER} already exists, reusing"
fi

echo "==> 2/6 MOCA deploy/k8s/setup.sh"
# SH_WORKLOAD_SANDBOXES=1 turns on moca-provisioner: workloads created with
# `--sandboxes N` get their own StatefulSet + PVC, instead of running on the
# shared pool with a per-run writable overlay. Needs Kubernetes 1.30+ (kind
# ships 1.31). The demo's two workload creates (diagnose read-only, fix
# writable) rely on this path.
(cd "${MOCA_DIR}" && \
  SH_WORKLOAD_SANDBOXES=1 SH_PUBLIC_HARNESS_URL="${HARNESS_URL}" \
  ./deploy/k8s/setup.sh --target kind --build)

echo "==> 3/6 CoreDNS -> 1.1.1.1 / 8.8.8.8 (podman resolv.conf workaround)"
# Idempotent: if forward is already patched, this is a no-op apply.
kubectl --context "${KUBE_CONTEXT}" -n kube-system get configmap coredns -o yaml |
  sed 's#forward \. /etc/resolv.conf#forward . 1.1.1.1 8.8.8.8#' |
  kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n kube-system rollout restart deployment/coredns >/dev/null

echo "==> 4/6 Context Service image + manifest"
# ghcr.io/rossoctl/context-service:latest is private (403 anonymous).
# Build and load; set imagePullPolicy: Never so the kubelet uses the
# loaded tag instead of trying to pull.
(cd "${CONTEXT_SERVICE_DIR}" && \
  docker build --load -t dev.local/context-service:local .)
kind load docker-image dev.local/context-service:local --name "${KIND_CLUSTER}"

# Rewrite the namespace: the manifest ships `serverless-harness`, MOCA
# requires `context-service`. The upstream manifest has no Namespace
# resource of its own, so create it before applying.
kubectl --context "${KUBE_CONTEXT}" create namespace context-service \
  --dry-run=client -o yaml |
  kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
sed 's/namespace: serverless-harness/namespace: context-service/g' \
    "${CONTEXT_SERVICE_DIR}/deploy/context-service.yaml" |
  kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null

kubectl --context "${KUBE_CONTEXT}" -n context-service \
  set image deployment/context-service \
  context-service=dev.local/context-service:local >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n context-service \
  patch deployment context-service \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"context-service","imagePullPolicy":"Never"}]}}}}' \
  >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n context-service \
  rollout status deployment/context-service --timeout=90s

echo "==> 5/6 moca-context-service ConfigMap + Secret (both sides of the token)"
# The supervisor sends this token as Bearer; context-service reads its expected
# value from secret context-service/context-service-control-plane (key `token`).
# If that secret is missing, context-service accepts no token and returns 401
# on every /internal/v1 call — which the supervisor surfaces as a 502
# context_service_error. Provision both sides with the same value.
CS_TOKEN="demo-token-unchecked"
kubectl --context "${KUBE_CONTEXT}" -n moca create configmap moca-context-service \
  --from-literal=enabled=1 \
  --from-literal=url=http://context-service.context-service.svc:8080 \
  --from-literal=public-url=http://127.0.0.1:${CS_PORT} \
  --from-literal=namespace=context-service \
  --dry-run=client -o yaml |
  kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n moca create secret generic moca-context-service \
  --from-literal=token="${CS_TOKEN}" \
  --dry-run=client -o yaml |
  kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n context-service create secret generic context-service-control-plane \
  --from-literal=token="${CS_TOKEN}" \
  --dry-run=client -o yaml |
  kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n context-service rollout restart deployment/context-service >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n context-service rollout status deployment/context-service --timeout=90s
kubectl --context "${KUBE_CONTEXT}" -n moca rollout restart deployment/moca-supervisor >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n moca rollout status deployment/moca-supervisor --timeout=90s

echo "==> 6/6 Background port-forwards (supervisor, control plane, context-service)"
# Why these three: mocactl talks to the control plane and the harness
# (supervisor), and the client-side bundle upload during `mocactl workloads
# create` targets context-service's public URL. The harness local port is
# whatever SH_PUBLIC_HARNESS_URL names (set in step 2); the context-service
# public-url ConfigMap entry (step 5) matches CS_PORT above.
PF_LOG_DIR="${PF_LOG_DIR:-${HOME}/.local/state/moca-chained-demo}"
mkdir -p "${PF_LOG_DIR}"

# Re-running the script must not stack duplicate port-forwards. Match on
# the full argv — do NOT simplify to `pkill kubectl`, which would nuke
# unrelated port-forwards on this machine, and do NOT lsof-kill by port:
# on Rancher Desktop, lima's SSH mux binds *:8080 and killing it takes the
# whole VM down (see Troubleshooting > "the harness refused: 404").
pkill -f "kubectl --context ${KUBE_CONTEXT} .* port-forward" 2>/dev/null || true

# A port-forward whose pod rotated dies with "lost connection to pod" but can
# leave the local port bound to the stale kubectl process, blocking a fresh
# bind with "address already in use". Reap any kubectl PID still listening on
# a demo port — target `kubectl` by command name, not whatever's on the port.
free_stale_pf() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    local pid
    for pid in $(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null || true); do
      if [[ "$(ps -o comm= -p "${pid}" 2>/dev/null || true)" == *kubectl* ]]; then
        echo "    freeing stale kubectl on ${port} (pid ${pid})"
        kill -9 "${pid}" 2>/dev/null || true
      fi
    done
  fi
}
free_stale_pf "${HARNESS_PORT}"
free_stale_pf "${CP_PORT}"
free_stale_pf "${CS_PORT}"

start_pf() {
  local ns="$1" svc="$2" local_port="$3" remote_port="$4" log_name="$5"
  nohup kubectl --context "${KUBE_CONTEXT}" -n "${ns}" port-forward \
    "svc/${svc}" "${local_port}:${remote_port}" \
    >"${PF_LOG_DIR}/${log_name}.log" 2>&1 &
  disown
}
start_pf moca            moca-supervisor      "${HARNESS_PORT}" 8080 moca-supervisor
start_pf moca            moca-control-plane   "${CP_PORT}"      8080 moca-control-plane
start_pf context-service context-service      "${CS_PORT}"      8080 context-service

# Give kubectl a moment to establish the forwards before probing. The retry
# loop below is the real safety net — this is just so the common case prints
# "up" on the first try instead of after a visible pause.
sleep 2

# Port-forwards to a svc/ depend on the service's endpoints being ready,
# which can lag by up to ~30 s after `deploy/k8s/setup.sh --build` rolls the
# supervisor. Poll with backoff for ~20 s before giving up.
probe_pf() {
  local port="$1" log_name="$2"
  local status
  for _ in {1..10}; do
    status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
      "http://127.0.0.1:${port}/" 2>/dev/null || true)"
    if [[ "${status}" != "000" && -n "${status}" ]]; then
      echo "    127.0.0.1:${port} up (HTTP ${status})"
      return 0
    fi
    sleep 2
  done
  echo "    port-forward on 127.0.0.1:${port} is not reachable after ~20s." >&2
  echo "    See log:  ${PF_LOG_DIR}/${log_name}.log" >&2
  return 1
}
probe_pf "${HARNESS_PORT}" moca-supervisor
probe_pf "${CP_PORT}"      moca-control-plane
probe_pf "${CS_PORT}"      context-service

cat <<EOF

Prereqs installed. Port-forwards are running in the background; logs:
  ${PF_LOG_DIR}/

Next, once per machine:

  export SH_CONTROL_PLANE_URL=http://127.0.0.1:${CP_PORT}
  mocactl login
  # ANTHROPIC_BASE_URL points at an Anthropic-compatible endpoint (e.g. a
  # LiteLLM gateway); ANTHROPIC_AUTH_TOKEN is the bearer token for it.
  printf %s "\$ANTHROPIC_AUTH_TOKEN" | mocactl credentials add anthropic \\
    --host "\$(printf %s "\$ANTHROPIC_BASE_URL" | awk -F/ '{print \$3}')" --kind bearer \\
    --endpoint "\$ANTHROPIC_BASE_URL"
  mocactl doctor

Then run this demo's ./setup.sh.

To tear everything down (port-forwards + kind cluster):  ./prereqs-uninstall.sh
EOF
