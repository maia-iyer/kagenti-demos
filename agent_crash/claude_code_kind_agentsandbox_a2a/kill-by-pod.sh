#!/usr/bin/env bash
# Delete the pod managed by the claude-crash-demo Sandbox, so the
# agent-sandbox controller recreates it. The Sandbox object itself is
# untouched — only its current Pod is killed. The controller is expected
# to schedule a replacement Pod and reattach the existing PVCs from
# volumeClaimTemplates.
#
# Usage: ./kill-by-pod.sh [namespace] [--force]
#   namespace   defaults to "default"
#   --force     passes --grace-period=0 --force to kubectl
#
# Exit: 0 on delete, 1 if no matching pod, 2 on bad usage.

set -euo pipefail

namespace="default"
force=0

for arg in "$@"; do
  case "$arg" in
    --force)
      force=1
      ;;
    -*)
      echo "unknown flag: $arg" >&2
      echo "usage: $0 [namespace] [--force]" >&2
      exit 2
      ;;
    *)
      namespace="$arg"
      ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found on PATH" >&2
  exit 2
fi

pod="$(kubectl get pod -n "$namespace" -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [ -z "$pod" ]; then
  echo "no pod with label app=claude-crash-demo in namespace=$namespace" >&2
  exit 1
fi

if [ "$force" -eq 1 ]; then
  echo "force-deleting pod=$pod (ns=$namespace)"
  kubectl delete pod "$pod" -n "$namespace" --grace-period=0 --force
else
  echo "deleting pod=$pod (ns=$namespace)"
  kubectl delete pod "$pod" -n "$namespace"
fi
