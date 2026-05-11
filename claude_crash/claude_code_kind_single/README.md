# Claude Code + Ollama — Kind, Single Session (emptyDir negative control)

Move the single-session crash-recovery case into Kind and deliberately back `~/.claude` with `emptyDir`. Claude Code talks to **Ollama running on your machine** (not inside the cluster) via `ANTHROPIC_BASE_URL=http://host.docker.internal:11434`, which is the usual hostname Docker Desktop provides so containers can reach the host — no Anthropic API key and no in-cluster Ollama image.

The expected result is still that **pod-local state is lost** when the pod is deleted — this demo exists to make that failure concrete and motivate the PVC-backed variant that follows.

## Goal

Show that when `~/.claude/` lives on `emptyDir`, a `kubectl delete pod` wipes the session store along with the pod. Contrast with `claude_code_local_single`, where `~/.claude` on the host disk survived `kill -9`. This is the same harness and the same workload; only the environment and the kill mechanism change.

## Prerequisites

- A running Kind cluster (`kind create cluster` — see https://kind.sigs.k8s.io/)
- `kubectl` configured against that cluster (`kubectl cluster-info`)
- **Ollama on the host**, with a model pulled (example below uses `qwen3.5` as in the [Ollama + Claude Code docs](https://docs.ollama.com/integrations/claude-code))

Two terminals side-by-side: terminal A execs into the pod and runs Claude Code; terminal B issues the `kubectl delete`.

## Host Ollama (required)

Run Ollama on the same machine that runs Docker / Kind, and **listen on all interfaces** so traffic from the Kind node container can reach you (the default is often loopback-only):

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

In another shell, pull a model once:

```bash
ollama pull qwen3.5
```

> **Context:** Claude Code expects a large context window. Ollama recommends at least ~64k tokens for reliable agentic use — see https://docs.ollama.com/context-length

### Reaching the host from the pod

- **Docker Desktop (macOS / Windows):** `host.docker.internal` usually resolves from Kind workloads; the manifest uses that URL by default.
- **Linux (Kind on docker-ce / podman):** `host.docker.internal` is often **missing**. Point the Deployment at the Docker bridge gateway instead (commonly `172.17.0.1`; confirm with `ip addr show docker0` or your runtime’s docs), for example:

```bash
kubectl set env deployment/claude-crash-demo ANTHROPIC_BASE_URL=http://172.17.0.1:11434
```

Smoke-test from the cluster before installing Claude Code:

```bash
kubectl run -it --rm hostping --image=curlimages/curl --restart=Never -- \
  curl -sS -o /dev/null -w "%{http_code}\n" http://host.docker.internal:11434/api/tags
```

If that fails with “Could not resolve host”, use the Linux `kubectl set env` URL above (or add a `hostAliases` entry to the Pod template with your host’s reachable IP).

## Setup

> **Safety note:** the kill script in this directory targets only pods labeled `app=claude-crash-demo`. Do **not** substitute `kubectl delete pod --all` — that wipes unrelated workloads.

Apply the manifest (no Secret — auth is local):

```bash
kubectl apply -f manifests/claude-pod.yaml
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

The Deployment wires Anthropic-compatible env vars for Ollama ([manual setup](https://docs.ollama.com/integrations/claude-code)); only the base URL targets the **host** instead of `localhost`:

- `ANTHROPIC_BASE_URL` — `http://host.docker.internal:11434` by default (override on Linux if needed)
- `ANTHROPIC_AUTH_TOKEN=ollama`
- `ANTHROPIC_API_KEY=""`

---

## Scenario — Delete the pod, lose the session

State spans the conversation (what the model remembers via Claude Code) and the filesystem (what was already written). On `emptyDir`, pod-local state does not survive. **Ollama and its model cache stay on the host** — only the harness metadata under `/root/.claude` and files under `/workspace` are the subject of this negative control.

### Step 1. Build up some state

In the pod shell:

```bash
claude --model qwen3.5
```

Use the same model name you pulled on the host (adjust if you chose another tag).

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
claude --model qwen3.5 --resume
```

Expected:

- `/workspace` is empty — no `notes.md`.
- `/root/.claude/` is empty — no sessions, no projects.
- `claude --resume` has nothing to resume.

Everything Claude Code stored **in the pod** is gone with the old pod's `emptyDir`. The host Ollama process and its `~/.ollama` cache are unchanged.

---

## What to record

Same columns as the local demo, so the two rows sit next to each other in your notes:

- **Where state lives on disk (pod):** `/root/.claude/` and `/workspace`, both `emptyDir` — scoped to the pod
- **Where state lives (host):** Ollama runtime + model blobs under the host user’s Ollama data dir — **not** wiped by deleting the pod
- **What survived the kill:** nothing pod-local; cluster-level objects (the Deployment spec); host Ollama + pulled models
- **What was lost:** session history and project metadata under `/root/.claude`, `notes.md`, the installed `claude` npm global
- **Kill mechanism:** `kubectl delete pod` — the kubelet SIGTERMs the container and reclaims the pod sandbox, `emptyDir` included

## Why this fails and what's next

`emptyDir` is bound to the pod's lifetime. When the pod is deleted, the volume is reclaimed. For session state to survive a pod delete, it needs to live on storage with a lifetime decoupled from the pod — a PersistentVolume. The next demo (`claude_code_kind_single_pvc`, TBD) backs `/root/.claude` with a PVC and re-runs this scenario; the expectation is that `claude --resume` in the replacement pod finds the session intact.

## Cleanup

```bash
kubectl delete -f manifests/claude-pod.yaml
```

Optionally tear down the cluster:

```bash
kind delete cluster
```

## Open questions (revisit after running)

- Does the installed `claude` binary survive in `/usr/local/lib/node_modules` across pod delete? (No — that lives in the container's writable layer, which is also pod-local. A baked image would change this.)
- When exec'ing into the replacement pod, does the Deployment's rolling behavior ever leave two pods briefly overlapping? If so, which session file wins on a shared PVC? (Relevant for the next demo, not this one.)
- On Linux, is documenting a small Kind `patch` or `kustomize` overlay for `ANTHROPIC_BASE_URL` nicer than ad hoc `kubectl set env`?
