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
#
# What it does NOT do (keep these as operator steps, see README):
#   - Install mocactl / contextctl / kubectl / jq / kind / podman.
#   - Start the three port-forwards.
#   - mocactl login, credential add, doctor.
#   - Run this demo's own setup.sh.

set -euo pipefail

# Inputs. CLONE_DIR is a convenience: if set, MOCA_DIR and CONTEXT_SERVICE_DIR
# default to $CLONE_DIR/moca and $CLONE_DIR/context-service. Either checkout
# can still be pointed elsewhere by exporting its own variable.
if [[ -n "${CLONE_DIR:-}" ]]; then
  MOCA_DIR="${MOCA_DIR:-${CLONE_DIR}/moca}"
  CONTEXT_SERVICE_DIR="${CONTEXT_SERVICE_DIR:-${CLONE_DIR}/context-service}"
fi

: "${MOCA_DIR:?MOCA_DIR is required (or set CLONE_DIR so MOCA_DIR defaults to \$CLONE_DIR/moca)}"
: "${CONTEXT_SERVICE_DIR:?CONTEXT_SERVICE_DIR is required (or set CLONE_DIR so it defaults to \$CLONE_DIR/context-service)}"

KIND_CLUSTER="${KIND_CLUSTER:-moca}"
KUBE_CONTEXT="kind-${KIND_CLUSTER}"

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

echo "==> 1/5 kind cluster ${KIND_CLUSTER}"
if ! kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER}"; then
  kind create cluster --name "${KIND_CLUSTER}"
else
  echo "    cluster ${KIND_CLUSTER} already exists, reusing"
fi

echo "==> 2/5 MOCA deploy/k8s/setup.sh"
(cd "${MOCA_DIR}" && ./deploy/k8s/setup.sh --target kind --build)

echo "==> 3/5 CoreDNS -> 1.1.1.1 / 8.8.8.8 (podman resolv.conf workaround)"
# Idempotent: if forward is already patched, this is a no-op apply.
kubectl --context "${KUBE_CONTEXT}" -n kube-system get configmap coredns -o yaml |
  sed 's#forward \. /etc/resolv.conf#forward . 1.1.1.1 8.8.8.8#' |
  kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
kubectl --context "${KUBE_CONTEXT}" -n kube-system rollout restart deployment/coredns >/dev/null

echo "==> 4/5 Context Service image + manifest"
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

echo "==> 5/5 moca-context-service ConfigMap + Secret (both sides of the token)"
# The supervisor sends this token as Bearer; context-service reads its expected
# value from secret context-service/context-service-control-plane (key `token`).
# If that secret is missing, context-service accepts no token and returns 401
# on every /internal/v1 call — which the supervisor surfaces as a 502
# context_service_error. Provision both sides with the same value.
CS_TOKEN="demo-token-unchecked"
kubectl --context "${KUBE_CONTEXT}" -n moca create configmap moca-context-service \
  --from-literal=enabled=1 \
  --from-literal=url=http://context-service.context-service.svc:8080 \
  --from-literal=public-url=http://127.0.0.1:9090 \
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

cat <<EOF

Prereqs installed. Next, in three other terminals:

  kubectl --context ${KUBE_CONTEXT} -n moca port-forward svc/moca-supervisor 8080:8080
  kubectl --context ${KUBE_CONTEXT} -n moca port-forward svc/moca-control-plane 8090:8080
  kubectl --context ${KUBE_CONTEXT} -n context-service port-forward svc/context-service 9090:8080

Then, once per machine:

  export SH_CONTROL_PLANE_URL=http://127.0.0.1:8090
  mocactl login
  # ANTHROPIC_BASE_URL points at an Anthropic-compatible endpoint (e.g. a
  # LiteLLM gateway); ANTHROPIC_AUTH_TOKEN is the bearer token for it.
  printf %s "\$ANTHROPIC_AUTH_TOKEN" | mocactl credentials add anthropic \\
    --host "\$(printf %s "\$ANTHROPIC_BASE_URL" | awk -F/ '{print \$3}')" --kind bearer \\
    --endpoint "\$ANTHROPIC_BASE_URL"
  mocactl doctor

Then run this demo's ./setup.sh.
EOF
