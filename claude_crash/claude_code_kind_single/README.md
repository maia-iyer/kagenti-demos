# Claude Code in Kind — Single Session (emptyDir negative control)

Move the single-session crash-recovery case into Kind and deliberately back `~/.claude` with `emptyDir`. Claude Code talks to an Anthropic-compatible backend running **outside the cluster**, picked from one of:

- **Ollama** on your machine — no API key, but model quality is constrained by what runs locally.
- **LiteLLM** (or any Anthropic-compatible proxy) reachable over the network — uses real Anthropic models via your proxy credentials.

The expected result is the same regardless of backend: **pod-local state is lost** when the pod is deleted. This demo exists to make that failure concrete and motivate the PVC-backed variant that follows.

## Goal

Show that when `~/.claude/` lives on `emptyDir`, a `kubectl delete pod` wipes the session store along with the pod. Contrast with `claude_code_local_single`, where `~/.claude` on the host disk survived `kill -9`. This is the same harness and the same workload; only the environment and the kill mechanism change.

## Prerequisites

- A running Kind cluster on top of a Podman machine (see below)
- `kubectl` configured against that cluster (`kubectl cluster-info`)
- **One backend**, either:
  - **Ollama on the host**, with a model pulled (example below uses `qwen3.5` as in the [Ollama + Claude Code docs](https://docs.ollama.com/integrations/claude-code)), or
  - **A LiteLLM endpoint** that speaks the Anthropic API, plus an API key for it

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

## Backend setup

Pick **one** of the two backends below. Each one tells you what to export in your shell before running the Setup step — the Setup commands consume those env vars to wire the Deployment.

### Backend A: Host Ollama

Run Ollama on the same machine that runs Docker / Kind, and **listen on all interfaces** so traffic from the Kind node container can reach you (the default is often loopback-only):

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

In another shell, pull a model once:

```bash
ollama pull qwen3.5
```

> **Context:** Claude Code expects a large context window. Ollama recommends at least ~64k tokens for reliable agentic use — see https://docs.ollama.com/context-length

Export the values the Setup step will read:

```bash
export BACKEND=ollama
export ANTHROPIC_BASE_URL=http://host.docker.internal:11434
export ANTHROPIC_MODEL=qwen3.5
```

#### Reaching the host from the pod

- **Docker Desktop (macOS / Windows):** `host.docker.internal` usually resolves from Kind workloads; the value above works.
- **Linux (Kind on docker-ce / podman):** `host.docker.internal` is often **missing**. Point at the Docker bridge gateway instead (commonly `172.17.0.1`; confirm with `ip addr show docker0`):
  ```bash
  export ANTHROPIC_BASE_URL=http://172.17.0.1:11434
  ```

### Backend B: LiteLLM (Anthropic-compatible proxy)

Use this when you want real Anthropic models served via a LiteLLM proxy you have credentials for. Paste your endpoint, model name, and API key into env vars in the same shell you'll run Setup from:

```bash
export BACKEND=litellm
export ANTHROPIC_BASE_URL="<paste your LiteLLM endpoint, e.g. https://litellm.example.com>"
export ANTHROPIC_MODEL="<paste the model id your LiteLLM serves>"
export LITELLM_API_KEY="<paste your LiteLLM API key>"
```

Notes:
- The endpoint must speak the Anthropic API surface (LiteLLM does, when configured for Anthropic-compatible routes).
- Claude Code reads the API key from `ANTHROPIC_AUTH_TOKEN` inside the pod; the Setup step pipes `LITELLM_API_KEY` into a Secret under that name so the key never appears in the manifest or in `kubectl set env` history.

## Setup

> **Safety note:** the kill script in this directory targets only pods labeled `app=claude-crash-demo`. Do **not** substitute `kubectl delete pod --all` — that wipes unrelated workloads.

Apply the manifest:

```bash
kubectl apply -f manifests/claude-pod.yaml
kubectl rollout status deployment/claude-crash-demo
```

Now wire the backend you chose. Run **one** of these blocks in the same shell where you exported the backend env vars.

**Backend A — Ollama:**

```bash
kubectl set env deployment/claude-crash-demo \
  ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
  ANTHROPIC_MODEL="$ANTHROPIC_MODEL" \
  ANTHROPIC_AUTH_TOKEN=ollama \
  ANTHROPIC_API_KEY=""
kubectl rollout status deployment/claude-crash-demo
```

Smoke-test from the cluster before installing Claude Code:

```bash
kubectl run -it --rm hostping --image=curlimages/curl --restart=Never -- \
  curl -sS -o /dev/null -w "%{http_code}\n" "$ANTHROPIC_BASE_URL/api/tags"
```

**Backend B — LiteLLM:**

Create a Secret from the API key in your shell, then point the Deployment at it:

```bash
kubectl create secret generic claude-litellm \
  --from-literal=ANTHROPIC_AUTH_TOKEN="$LITELLM_API_KEY"

kubectl set env deployment/claude-crash-demo \
  ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
  ANTHROPIC_MODEL="$ANTHROPIC_MODEL" \
  ANTHROPIC_API_KEY=""
kubectl set env deployment/claude-crash-demo \
  --from=secret/claude-litellm
kubectl rollout status deployment/claude-crash-demo
```

Get the pod name and exec in:

```bash
POD=$(kubectl get pod -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$POD" -- bash
```

Inside the pod, install Claude Code (the base image is `node:20-slim`, chosen to stay image-agnostic — no auth or binaries baked in):

```bash
npm install -g @anthropic-ai/claude-code
cd /workspace
```

The Deployment now exposes the Anthropic-compatible env vars Claude Code reads:

- `ANTHROPIC_BASE_URL` — your backend endpoint
- `ANTHROPIC_MODEL` — the model id Claude Code will request
- `ANTHROPIC_AUTH_TOKEN` — `ollama` for Ollama, your LiteLLM key (via Secret) for LiteLLM
- `ANTHROPIC_API_KEY=""` — kept empty so the auth token is what gets used

---

## Scenario — Delete the pod, lose the session

State spans the conversation (what the model remembers via Claude Code) and the filesystem (what was already written). On `emptyDir`, pod-local state does not survive. **The backend stays where it is** — Ollama on the host or LiteLLM at its endpoint — only the harness metadata under `/root/.claude` and files under `/workspace` are the subject of this negative control.

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
npm install -g @anthropic-ai/claude-code   # yes, again — the install is also state
cd /workspace
claude --model "$ANTHROPIC_MODEL" --resume
```

Expected:

- `/workspace` is empty — no `notes.md`.
- `/root/.claude/` is empty — no sessions, no projects.
- `claude --resume` has nothing to resume.

Everything Claude Code stored **in the pod** is gone with the old pod's `emptyDir`. The backend itself — host Ollama and its `~/.ollama` cache, or your LiteLLM endpoint — is unchanged.

---

## What to record

Same columns as the local demo, so the two rows sit next to each other in your notes:

- **Where state lives on disk (pod):** `/root/.claude/` and `/workspace`, both `emptyDir` — scoped to the pod
- **Where state lives (off-pod):** the backend — host Ollama runtime + model blobs, or your LiteLLM endpoint — **not** wiped by deleting the pod
- **What survived the kill:** nothing pod-local; cluster-level objects (the Deployment spec, the `claude-litellm` Secret if used); the backend
- **What was lost:** session history and project metadata under `/root/.claude`, `notes.md`, the installed `claude` npm global
- **Kill mechanism:** `kubectl delete pod` — the kubelet SIGTERMs the container and reclaims the pod sandbox, `emptyDir` included

## Why this fails and what's next

`emptyDir` is bound to the pod's lifetime. When the pod is deleted, the volume is reclaimed. For session state to survive a pod delete, it needs to live on storage with a lifetime decoupled from the pod — a PersistentVolume. The next demo (`claude_code_kind_single_pvc`, TBD) backs `/root/.claude` with a PVC and re-runs this scenario; the expectation is that `claude --resume` in the replacement pod finds the session intact.

## Cleanup

```bash
kubectl delete -f manifests/claude-pod.yaml
kubectl delete secret claude-litellm --ignore-not-found   # only created on Backend B
```

Optionally tear down the cluster (and stop the Podman VM):

```bash
kind delete cluster
podman machine stop
```

## Open questions (revisit after running)

- Does the installed `claude` binary survive in `/usr/local/lib/node_modules` across pod delete? (No — that lives in the container's writable layer, which is also pod-local. A baked image would change this.)
- When exec'ing into the replacement pod, does the Deployment's rolling behavior ever leave two pods briefly overlapping? If so, which session file wins on a shared PVC? (Relevant for the next demo, not this one.)
- On Linux, is documenting a small Kind `patch` or `kustomize` overlay for `ANTHROPIC_BASE_URL` nicer than ad hoc `kubectl set env`?
