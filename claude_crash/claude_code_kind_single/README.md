# Claude Code in Kind — Single Session (emptyDir negative control)

Move the single-session crash-recovery case into Kind and deliberately back `~/.claude` with `emptyDir`. Claude Code runs in the pod against a **LiteLLM endpoint** (or any Anthropic-compatible proxy) reachable over the network from the cluster.

The expected result is that **pod-local state is lost** when the pod is deleted. This demo exists to make that failure concrete and motivate the PVC-backed variant that follows.

## Goal

Show that when `~/.claude/` lives on `emptyDir`, a `kubectl delete pod` wipes the session store along with the pod. Contrast with `claude_code_local_single`, where `~/.claude` on the host disk survived `kill -9`. This is the same harness and the same workload; only the environment and the kill mechanism change.

## Prerequisites

- A running Kind cluster on top of a Podman machine (see below)
- `kubectl` configured against that cluster (`kubectl cluster-info`)
- A **LiteLLM endpoint** that speaks the Anthropic API, plus an API key for it
- The endpoint URL and key exported in your shell as `MY_LITELLM` and `MY_LITELLM_TOKEN` (the Setup commands read those names directly)

Two terminals side-by-side: terminal A execs into the pod and runs Claude Code; terminal B issues the `kubectl delete`.

### Start the Podman machine and Kind cluster

This demo uses Podman as Kind's container runtime. On macOS, Podman runs in a VM that must be started before Kind can talk to it.

```bash
# One-time: create the VM (skip if `podman machine list` already shows one)
podman machine init

# Start the VM (and verify it's up)
podman machine start
podman info >/dev/null && echo "podman ready"

# Tell kind to use podman, then create the cluster
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster
kubectl cluster-info
```

> Keep `KIND_EXPERIMENTAL_PROVIDER=podman` exported in any shell that runs `kind` against this cluster (including the kill-script terminal), or kind will default to docker and fail to find the cluster.

## Build the demo image

Claude Code is baked into the image so the pod is ready to use as soon as it's running — no in-pod `npm install` step. Build it with podman and load it into the Kind cluster via an archive (podman tags local images under `localhost/`, so `kind load docker-image` doesn't pick them up cleanly):

```bash
podman build -t localhost/claude-crash-demo:local .
podman save localhost/claude-crash-demo:local -o /tmp/claude-crash-demo.tar
kind load image-archive /tmp/claude-crash-demo.tar
```

Confirm the image landed on the node:

```bash
podman exec kind-control-plane crictl images | grep claude
```

The manifest references `localhost/claude-crash-demo:local` with `imagePullPolicy: IfNotPresent`, so Kind uses the loaded image directly.

## Setup

> **Safety note:** the kill script in this directory targets only pods labeled `app=claude-crash-demo`. Do **not** substitute `kubectl delete pod --all` — that wipes unrelated workloads.

Pick a model id your LiteLLM serves and export it alongside `MY_LITELLM` and `MY_LITELLM_TOKEN`:

```bash
export ANTHROPIC_MODEL="<the model id your LiteLLM serves>"
```

Apply the manifest:

```bash
kubectl apply -f manifests/claude-pod.yaml
kubectl rollout status deployment/claude-crash-demo
```

Create a Secret from your LiteLLM token, then wire the rest of the env on the Deployment:

```bash
kubectl create secret generic claude-litellm \
  --from-literal=ANTHROPIC_AUTH_TOKEN="$MY_LITELLM_TOKEN"

kubectl set env deployment/claude-crash-demo \
  ANTHROPIC_BASE_URL="$MY_LITELLM" \
  ANTHROPIC_MODEL="$ANTHROPIC_MODEL"
kubectl set env deployment/claude-crash-demo \
  --from=secret/claude-litellm
kubectl rollout status deployment/claude-crash-demo
```

Get the pod name and exec in:

```bash
POD=$(kubectl get pod -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$POD" -- bash
```

The Deployment now exposes the Anthropic-compatible env vars Claude Code reads:

- `ANTHROPIC_BASE_URL` — your LiteLLM endpoint (from `$MY_LITELLM`)
- `ANTHROPIC_MODEL` — the model id Claude Code will request
- `ANTHROPIC_AUTH_TOKEN` — your LiteLLM key, mounted from the `claude-litellm` Secret
- `ANTHROPIC_API_KEY=""` — kept empty so the auth token is what gets used

---

## Scenario — Delete the pod, lose the session

State spans the conversation (what the model remembers via Claude Code) and the filesystem (what was already written). On `emptyDir`, pod-local state does not survive. **The LiteLLM endpoint stays where it is** — only the harness metadata under `/root/.claude` and files under `/workspace` are the subject of this negative control.

### Step 1. Build up some state

In the pod shell:

```bash
claude --model "$ANTHROPIC_MODEL"
```

`ANTHROPIC_MODEL` was set on the Deployment in the Setup step, so it's already in the pod env.

Paste each prompt, one at a time. Wait for completion before the next. (These match `claude_code_local_single` verbatim so the workload is identical across demos.)

**Prompt 1:**
```
Create a file called notes.md with three sections: "Goals", "Open Questions", and "Next Steps". Each section should have two placeholder bullet points.
```

**Prompt 2:**
```
Add a fourth section called "Risks" after "Open Questions", with two placeholder bullets.
```

**Prompt 3:**
```
In the "Goals" section, replace the placeholder bullets with: "ship v1 by end of quarter" and "onboard two new contributors".
```

`notes.md` now exists in `/workspace` and the session log is under `/root/.claude/projects/`.

### Step 2. Delete the pod

Terminal B (from this demo directory):

```bash
./kill-by-pod.sh
```

The Deployment will immediately schedule a replacement pod. Terminal A's `exec` session drops.

Optional: add `--force` to skip graceful shutdown and mirror the `kill -9` feel of the local demo:

```bash
./kill-by-pod.sh default --force
```

### Step 3. Wait for the new pod and exec in

```bash
kubectl rollout status deployment/claude-crash-demo
POD=$(kubectl get pod -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$POD" -- bash
```

### Step 4. Observe the loss

Inside the new pod:

```bash
ls /workspace
ls -la /root/.claude/
cd /workspace
claude --model "$ANTHROPIC_MODEL" --resume
```

Expected:

- `/workspace` is empty — no `notes.md`.
- `/root/.claude/` is empty — no sessions, no projects.
- `claude --resume` has nothing to resume.

Everything Claude Code stored **in the pod** is gone with the old pod's `emptyDir`. The LiteLLM endpoint is unchanged. The `claude` binary itself survives because it's baked into the image, not installed at runtime.

---

## What to record

Same columns as the local demo, so the two rows sit next to each other in your notes:

- **Where state lives on disk (pod):** `/root/.claude/` and `/workspace`, both `emptyDir` — scoped to the pod
- **Where state lives (off-pod):** the LiteLLM endpoint, the loaded image (`claude-crash-demo:local`), and the `claude-litellm` Secret — **not** wiped by deleting the pod
- **What survived the kill:** nothing pod-local; cluster-level objects (the Deployment spec, the `claude-litellm` Secret); the loaded image; the LiteLLM endpoint
- **What was lost:** session history and project metadata under `/root/.claude`, `notes.md`
- **Kill mechanism:** `kubectl delete pod` — the kubelet SIGTERMs the container and reclaims the pod sandbox, `emptyDir` included

## Why this fails and what's next

`emptyDir` is bound to the pod's lifetime. When the pod is deleted, the volume is reclaimed. For session state to survive a pod delete, it needs to live on storage with a lifetime decoupled from the pod — a PersistentVolume. The next demo (`claude_code_kind_single_pvc`, TBD) backs `/root/.claude` with a PVC and re-runs this scenario; the expectation is that `claude --resume` in the replacement pod finds the session intact.

## Cleanup

```bash
kubectl delete -f manifests/claude-pod.yaml
kubectl delete secret claude-litellm --ignore-not-found
```

Optionally tear down the cluster (and stop the Podman VM):

```bash
kind delete cluster
podman machine stop
```

## Open questions (revisit after running)

- When exec'ing into the replacement pod, does the Deployment's rolling behavior ever leave two pods briefly overlapping? If so, which session file wins on a shared PVC? (Relevant for the next demo, not this one.)
- Is documenting a small Kind `patch` or `kustomize` overlay for `ANTHROPIC_BASE_URL` nicer than ad hoc `kubectl set env`?
