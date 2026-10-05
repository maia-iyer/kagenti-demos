#!/usr/bin/env bash
# Thin kubectl-only shim that mirrors the subset of contextctl verbs this
# demo uses. Each function has the same name and argument order as the
# contextctl command it replaces, so swapping back to contextctl later is
# a function-body change, not a restructure.
#
# What this shim does differently from real contextctl:
#   - "local workspace" is not materialized anywhere; the path is passed
#     through as-is to the sync step. ctx_create_local / ctx_delete_local
#     are no-ops that only validate the name.
#   - "remote workspace" is a plain PVC in the target namespace, named
#     the same as the context. No separate catalog.
#   - "sync push" copies the local path into the PVC via a short-lived
#     loader pod and `kubectl cp`.
#
# Everything else — workload creation via MOCA's /workloads, mounting
# the PVC with readOnly true/false — is unchanged, because that's MOCA's
# API, not Context Service's.

set -euo pipefail

: "${LOADER_IMAGE:=busybox:1.36}"

_ctx_require() {
  for bin in kubectl jq; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
      echo "ctx shim: missing required binary: ${bin}" >&2
      return 1
    fi
  done
}

# contextctl ctx create <name> --type workspace --backend filesystem
ctx_create_local() {
  local name="$1"
  [[ -n "${name}" ]] || { echo "ctx_create_local: name required" >&2; return 2; }
  # No persistent state to create; mirror the API shape only.
  echo "    (ctx shim) local context '${name}' noted"
}

# contextctl ctx artifact publish <local-name> <path> --from <local-name> --producer <producer>
ctx_artifact_publish() {
  local local_name="$1" path="$2"
  [[ -n "${local_name}" ]] || { echo "ctx_artifact_publish: local-name required" >&2; return 2; }
  [[ -d "${path}" ]]       || { echo "ctx_artifact_publish: '${path}' is not a directory" >&2; return 2; }
  # In real contextctl this would copy into the local catalog. We just
  # stash the path on a cache var that sync_push reads.
  export CTX_SHIM_LOCAL_PATH_FOR_"${local_name//[^A-Za-z0-9_]/_}"="${path}"
  echo "    (ctx shim) staged ${path} for local context '${local_name}'"
}

# contextctl ctx create <name> --type workspace --backend pvc --namespace <ns>
# Creates a PVC named <name> in <ns>. Idempotent.
ctx_create_remote() {
  local name="$1" ns="$2"
  _ctx_require
  [[ -n "${name}" && -n "${ns}" ]] || { echo "ctx_create_remote: name and namespace required" >&2; return 2; }

  local size="${CTX_PVC_SIZE:-128Mi}"
  local storage_class_flag=""
  if [[ -n "${CTX_STORAGE_CLASS:-}" ]]; then
    storage_class_flag="  storageClassName: ${CTX_STORAGE_CLASS}"
  fi

  if kubectl -n "${ns}" get pvc "${name}" >/dev/null 2>&1; then
    echo "    (ctx shim) remote context '${name}' PVC already exists"
    return 0
  fi

  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  accessModes:
    - ReadWriteOnce
${storage_class_flag}
  resources:
    requests:
      storage: ${size}
EOF
  echo "    (ctx shim) remote context '${name}' PVC created in ${ns}"
}

# contextctl ctx sync push <local-name> --remote-name <remote-name> --namespace <ns>
# Copies the directory published to <local-name> into the PVC named
# <remote-name> in <ns>, via a short-lived loader pod.
ctx_sync_push() {
  local local_name="$1" remote_name="$2" ns="$3"
  _ctx_require
  [[ -n "${local_name}" && -n "${remote_name}" && -n "${ns}" ]] \
    || { echo "ctx_sync_push: local-name, remote-name, namespace required" >&2; return 2; }

  local path_var="CTX_SHIM_LOCAL_PATH_FOR_${local_name//[^A-Za-z0-9_]/_}"
  local path="${!path_var:-}"
  if [[ -z "${path}" ]]; then
    echo "ctx_sync_push: no artifact published to local context '${local_name}' — call ctx_artifact_publish first" >&2
    return 2
  fi
  if [[ ! -d "${path}" ]]; then
    echo "ctx_sync_push: staged path '${path}' is not a directory" >&2
    return 2
  fi

  local loader="ctx-loader-${remote_name}"
  echo "    (ctx shim) starting loader pod ${loader} in ${ns}..."

  # Clean up any stale loader from a prior aborted run.
  kubectl -n "${ns}" delete pod "${loader}" --ignore-not-found --wait=true >/dev/null

  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${loader}
  namespace: ${ns}
  labels:
    app: ctx-shim-loader
spec:
  restartPolicy: Never
  containers:
    - name: loader
      image: ${LOADER_IMAGE}
      command: ["sh", "-c", "mkdir -p /data && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${remote_name}
EOF

  echo "    (ctx shim) waiting for loader to be Ready..."
  kubectl -n "${ns}" wait --for=condition=Ready "pod/${loader}" --timeout=120s >/dev/null

  echo "    (ctx shim) wiping /data (idempotent re-sync)..."
  kubectl -n "${ns}" exec "${loader}" -- sh -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; true' >/dev/null

  echo "    (ctx shim) copying ${path} -> ${remote_name}:/data ..."
  # kubectl cp of a directory places it as a child; copy its contents by
  # appending /. to the source path.
  kubectl -n "${ns}" cp "${path}/." "${loader}:/data"

  echo "    (ctx shim) deleting loader pod..."
  kubectl -n "${ns}" delete pod "${loader}" --wait=true >/dev/null

  echo "    (ctx shim) sync push complete: ${local_name} -> ${remote_name}"
}

# contextctl ctx get <remote-name> --backend pvc --namespace <ns> -o json | jq .claimName
# In this shim the PVC is named identically to the context, so just echo it.
ctx_get_claim() {
  local remote_name="$1" ns="$2"
  _ctx_require
  [[ -n "${remote_name}" && -n "${ns}" ]] || { echo "ctx_get_claim: remote-name and namespace required" >&2; return 2; }
  if ! kubectl -n "${ns}" get pvc "${remote_name}" >/dev/null 2>&1; then
    echo "ctx_get_claim: PVC '${remote_name}' not found in ${ns}" >&2
    return 1
  fi
  echo "${remote_name}"
}

# contextctl ctx delete <remote-name> --backend pvc --namespace <ns>
ctx_delete_remote() {
  local remote_name="$1" ns="$2"
  _ctx_require
  [[ -n "${remote_name}" && -n "${ns}" ]] || { echo "ctx_delete_remote: remote-name and namespace required" >&2; return 2; }
  # Clean up any stray loader first, then the PVC.
  kubectl -n "${ns}" delete pod "ctx-loader-${remote_name}" --ignore-not-found --wait=true >/dev/null
  kubectl -n "${ns}" delete pvc "${remote_name}" --ignore-not-found --wait=true >/dev/null
  echo "    (ctx shim) deleted remote context '${remote_name}' (PVC) in ${ns}"
}

# contextctl ctx delete <local-name>
ctx_delete_local() {
  local name="$1"
  [[ -n "${name}" ]] || { echo "ctx_delete_local: name required" >&2; return 2; }
  echo "    (ctx shim) deleted local context '${name}' (no-op)"
}
