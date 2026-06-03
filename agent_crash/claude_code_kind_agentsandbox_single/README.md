# Claude Code in Kind — Single Session via agent-sandbox (PVC-backed positive control)

Same harness, same workload, and same kill mechanism as [`claude_code_kind_single`](../claude_code_kind_single/), but the pod is managed by a [`Sandbox`](https://github.com/kubernetes-sigs/agent-sandbox) custom resource instead of a Deployment, and `/root/.claude` plus `/workspace` are backed by PVCs provisioned via `spec.volumeClaimTemplates` instead of `emptyDir`.

The expected result flips from **loss** to **survival**: when the underlying pod is deleted, the agent-sandbox controller schedules a replacement pod and reattaches the same PVCs. `claude --resume` should pick up the previous session and `notes.md` should still be on disk.

## Goal

Show that moving session state off `emptyDir` and onto PVC storage owned by the `Sandbox` is sufficient to survive a pod-level kill, without changing anything else about the harness or the workload. This is the positive-control counterpart to `claude_code_kind_single`.

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

## Install agent-sandbox

Pin a release tag from <https://github.com/kubernetes-sigs/agent-sandbox/releases> (latest at time of writing: `v0.4.6`) and apply the core manifest. The extensions manifest (`SandboxTemplate`, `SandboxClaim`, `SandboxWarmPool`) is **not needed** for this demo.

```bash
export AGENT_SANDBOX_VERSION="v0.4.6"
kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"
kubectl wait --for=condition=Available --timeout=120s \
  deployment/agent-sandbox-controller -n agent-sandbox-system
```

> If `kubectl get deploy -n agent-sandbox-system` shows a different deployment name, adjust the `wait` accordingly.

Verify the CRD is registered:

```bash
kubectl get crd sandboxes.agents.x-k8s.io
```

## Build the demo image

Same image as the Deployment-based demo (Claude Code baked in, no in-pod install):

```bash
podman build -t localhost/claude-crash-demo:local .
kind load docker-image localhost/claude-crash-demo:local
```

> If you already built and loaded this image for `claude_code_kind_single`, you can skip this step — it's the same tag and same content.

## Setup

> **Safety note:** the kill script in this directory targets only pods labeled `app=claude-crash-demo`. Do **not** substitute `kubectl delete pod --all`.

Pick a model id your LiteLLM serves and export it alongside `MY_LITELLM` and `MY_LITELLM_TOKEN`:

```bash
export ANTHROPIC_MODEL="<the model id your LiteLLM serves>"
```

Create the Secret from your LiteLLM token first (the Sandbox references it by name on creation):

```bash
kubectl create secret generic claude-litellm \
  --from-literal=ANTHROPIC_AUTH_TOKEN="$MY_LITELLM_TOKEN"
```

The Sandbox manifest references `${MY_LITELLM}` and `${ANTHROPIC_MODEL}` directly — substitute them at apply time with `envsubst` so the pod is born with the right env (the controller does **not** reconcile pod env when you patch the Sandbox after creation):

```bash
envsubst < manifests/sandbox.yaml | kubectl apply -f -
```

Wait for the pod to be Ready:

```bash
kubectl wait --for=condition=Ready --timeout=120s pod -l app=claude-crash-demo
POD=$(kubectl get pod -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$POD" -- bash
```

The pod now exposes the Anthropic-compatible env vars Claude Code reads:

- `ANTHROPIC_BASE_URL` — your LiteLLM endpoint (from `$MY_LITELLM`)
- `ANTHROPIC_MODEL` — the model id Claude Code will request
- `ANTHROPIC_AUTH_TOKEN` — your LiteLLM key, mounted from the `claude-litellm` Secret
- `ANTHROPIC_API_KEY=""` — kept empty so the auth token is what gets used

`/root/.claude` and `/workspace` are mounted from PVCs provisioned by the Sandbox controller from `spec.volumeClaimTemplates`. Confirm:

```bash
kubectl get pvc
```

You should see two PVCs whose names start with `claude-crash-demo-` (one for `claude-home`, one for `workspace`).

---

## Scenario — Delete the pod, keep the session

State spans the conversation (what the model remembers via Claude Code) and the filesystem (what was already written). With PVC-backed volumes attached by the Sandbox controller, pod-local state is expected to **survive** pod deletion.

### Step 1. Build up some state

In the pod shell:

```bash
claude --model "$ANTHROPIC_MODEL"
```

Paste each prompt, one at a time. Wait for completion before the next. (These match `claude_code_kind_single` and `claude_code_local_single` verbatim so the workload is identical across demos.)

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

`notes.md` is in `/workspace` and the session log is under `/root/.claude/projects/`. Both directories are PVC-backed.

### Step 2. Delete the pod

Terminal B (from this demo directory):

```bash
./kill-by-pod.sh
```

The Sandbox controller will schedule a replacement pod onto the same PVCs. Terminal A's `exec` session drops.

Optional: add `--force` to skip graceful shutdown and mirror the `kill -9` feel of the local demo:

```bash
./kill-by-pod.sh default --force
```

### Step 3. Wait for the new pod and exec in

```bash
kubectl wait --for=condition=Ready --timeout=120s pod -l app=claude-crash-demo
POD=$(kubectl get pod -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$POD" -- bash
```

### Step 4. Observe the survival

Inside the new pod:

```bash
ls /workspace
ls -la /root/.claude/
cd /workspace
claude --model "$ANTHROPIC_MODEL" --resume
```

Expected:

- `/workspace` contains the `notes.md` from before — same content, same mtime.
- `/root/.claude/` contains the session/project metadata from before.
- `claude --resume` lists the prior session and resumes it cleanly.

Everything Claude Code wrote to PVC-backed volumes survives the pod delete because the volumes are owned by the Sandbox, not the pod.

---

## What to record

Same columns as the local and emptyDir demos, so all three rows sit next to each other in your notes:

- **Where state lives on disk (pod):** `/root/.claude/` and `/workspace`, both PVC-backed via the Sandbox's `volumeClaimTemplates` — scoped to the **Sandbox**, not the pod
- **Where state lives (off-pod):** the LiteLLM endpoint, the loaded image (`claude-crash-demo:local`), the `claude-litellm` Secret, the `Sandbox` object, and the two PVCs — none wiped by deleting the pod
- **What survived the kill:** session history and project metadata under `/root/.claude`, `notes.md`; cluster-level objects (Sandbox, PVCs, Secret); the loaded image; the LiteLLM endpoint
- **What was lost:** nothing intended to persist (the in-pod TCP session for `kubectl exec` drops, but the user can re-exec)
- **Kill mechanism:** `kubectl delete pod` — the kubelet SIGTERMs the container and the agent-sandbox controller schedules a new pod that re-mounts the existing PVCs

## Why this works

`volumeClaimTemplates` on a `Sandbox` works the way it does on a `StatefulSet`: PVCs are provisioned per Sandbox and survive any number of pod restarts. The default `spec.shutdownPolicy` is `Retain`, so even deleting the `Sandbox` does **not** garbage-collect the PVCs unless `shutdownPolicy: Delete` is set. The session store is no longer bound to the pod's lifetime; it's bound to the Sandbox's, and (with `Retain`) outlives even the Sandbox.

## Cleanup

```bash
kubectl delete -f manifests/sandbox.yaml
kubectl delete secret claude-litellm --ignore-not-found
# PVCs are retained by default (shutdownPolicy: Retain). Delete them explicitly:
kubectl delete pvc -l app=claude-crash-demo
```

Optionally uninstall the controller:

```bash
kubectl delete -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"
```

Optionally tear down the cluster (and stop the Podman VM):

```bash
kind delete cluster
podman machine stop
```

## Open questions (revisit after running)

- The Sandbox controller does not reconcile pod env when you patch the Sandbox after creation — the pod has to be deleted to pick up env changes. We sidestepped that by templating with `envsubst` before the first apply. Worth confirming whether this is intentional or a v0.4.x limitation.
- `volumeClaimTemplates` accept `accessModes: [ReadWriteOnce]`. Does that block the upcoming "two pods briefly overlapping during recreation" question, or does the Sandbox controller serialize pod transitions enough that RWO is always fine here?
- `shutdownPolicy: Retain` keeps PVCs alive past Sandbox deletion. Worth a follow-up demo that flips to `shutdownPolicy: Delete` and shows the GC behavior — different blast radius from a pod-level kill.
