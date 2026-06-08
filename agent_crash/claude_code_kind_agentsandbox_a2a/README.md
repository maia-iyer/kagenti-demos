# Claude Code in Kind — Multi-Session A2A surface (PVC-backed)

Same harness, same workload, and same kill mechanism as [`claude_code_kind_agentsandbox_single`](../claude_code_kind_agentsandbox_single/), but the user does **not** `kubectl exec` into the pod. Instead, a small A2A server runs inside the pod and forwards each `message/send` to Claude Code via `claude-agent-sdk`. The host talks to the cluster over `kubectl port-forward`.

The forcing question this demo probes: **what happens to a host-side A2A conversation when the agent's pod dies?** With `~/.claude` on a PVC and the server persisting one Claude Code `session_id` per A2A `contextId` to that PVC, each conversation should resume cleanly on the replacement pod — no host-side reconnect logic, no lost transcript, and multiple concurrent conversations on the same pod are supported.

This is the A2A counterpart to the PVC positive control. It does **not** replace it; it adds the host-to-pod communication channel that earlier demos sidestepped with `kubectl exec`.

## Goal

Show that a local-TUI harness (Claude Code) can be exposed via A2A from inside a Kagenti agent-sandbox without harness changes, and that pod-level kills are invisible to the host A2A client when both `~/.claude` and the persisted session-id pointer live on PVC-backed storage.

This directly probes the open question on the [kagenti-state-management initiative](../../../../maiasaurus-wiki/pages/initiatives/kagenti-state-management.md) — *"How do local TUI harnesses square with A2A as the agent-to-agent standard?"*

## Architecture

```
host                                kind cluster
─────                               ────────────
send.sh ──► localhost:8000 ──port-forward──► svc/claude-crash-demo-a2a:8000
                                                          │
                                                          ▼
                                                 pod (Sandbox-managed)
                                                  ├── server/main.py  (a2a-sdk)
                                                  │     └── claude-agent-sdk.query()
                                                  │           ├─ resume=<id from /home/node/.claude/a2a-sessions/<contextId>>
                                                  │           └─ cwd=/workspace
                                                  ├── /home/node/.claude   (PVC)
                                                  └── /workspace      (PVC)
```

The server captures `ResultMessage.session_id` from the SDK on the first call for a given A2A `contextId` and writes it to `/home/node/.claude/a2a-sessions/<contextId>`. Subsequent calls with that same `contextId` (and calls from the *replacement* pod after a kill) read that file and pass `resume=<id>` to `query()`, so the conversation continues. Different `contextId`s map to different Claude Code sessions, so multiple conversations can run side-by-side against the same pod.

> **Note on `claude-agent-sdk`.** Despite the name, the Python SDK is not a direct API client — `query()` spawns the Claude Code CLI (`@anthropic-ai/claude-code`, the Node binary) as a subprocess and talks to it over JSON-on-stdio. That's why this image is `node:20-slim` with `npm install -g @anthropic-ai/claude-code` baked in, and why session transcripts land in the same `~/.claude/projects/<cwd>/` location the interactive CLI uses. Each A2A request ultimately drives a `claude` child process inside the pod.

## Prerequisites

- A running Kind cluster on top of a Podman machine (see below)
- `kubectl` configured against that cluster (`kubectl cluster-info`)
- A **LiteLLM endpoint** that speaks the Anthropic API, plus an API key for it
- The endpoint URL and key exported as `MY_LITELLM` and `MY_LITELLM_TOKEN`

Three terminals: terminal A runs the port-forward; terminal B runs `send.sh`; terminal C runs the kill script and re-establishes the port-forward.

### Start the Podman machine and Kind cluster

```bash
# One-time: create the VM (skip if `podman machine list` already shows one)
podman machine init

podman machine start
podman info >/dev/null && echo "podman ready"

export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster
kubectl cluster-info
```

> Keep `KIND_EXPERIMENTAL_PROVIDER=podman` exported in any shell that runs `kind` against this cluster.

## Install agent-sandbox

```bash
export AGENT_SANDBOX_VERSION="v0.4.6"
kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"
kubectl wait --for=condition=Available --timeout=120s \
  deployment/agent-sandbox-controller -n agent-sandbox-system
kubectl get crd sandboxes.agents.x-k8s.io
```

## Build the demo image

This demo uses a **different** image than the PVC demo (`claude-crash-demo-a2a` instead of `claude-crash-demo`) because it bakes in Python, the A2A server, and `claude-agent-sdk` on top of Claude Code:

```bash
podman build -t localhost/claude-crash-demo-a2a:local .
kind load docker-image localhost/claude-crash-demo-a2a:local
```

Confirm the image landed:

```bash
podman exec kind-control-plane crictl images | grep claude-crash-demo-a2a
```

## Setup

> **Safety note:** the kill script in this directory targets only pods labeled `app=claude-crash-demo`. Do **not** substitute `kubectl delete pod --all`.

```bash
export ANTHROPIC_MODEL="<the model id your LiteLLM serves>"

kubectl create secret generic claude-litellm \
  --from-literal=ANTHROPIC_AUTH_TOKEN="$MY_LITELLM_TOKEN"

sed -e "s|\${MY_LITELLM}|$MY_LITELLM|g" \
    -e "s|\${ANTHROPIC_MODEL}|$ANTHROPIC_MODEL|g" \
    manifests/sandbox.yaml | kubectl apply -f -

kubectl wait --for=condition=Ready --timeout=120s pod -l app=claude-crash-demo
```

The pod env mirrors the PVC demo: `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_AUTH_TOKEN` from the secret, `ANTHROPIC_API_KEY=""`. The container's command is `python -m server.main`, so the A2A server starts automatically on port `8000`.

Sanity-check the server is listening:

```bash
kubectl logs -l app=claude-crash-demo --tail=20
```

Expect uvicorn's `Application startup complete.`

### Forward the A2A port to the host

Terminal A:

```bash
kubectl port-forward svc/claude-crash-demo-a2a 8000:8000
```

Confirm the agent card is reachable from the host:

```bash
curl -s http://localhost:8000/.well-known/agent-card.json | head -40
```

You should see the `claude-code-a2a` agent card with one `claude_code` skill.

---

## Scenario — Drive the conversation from the host, kill the pod, then open a second conversation

The workload mirrors demos 1–3 (same three prompts) so you can compare row-for-row, but every prompt is sent from the **host** via A2A rather than typed inside `kubectl exec`. Steps 1–4 prove one conversation survives a pod kill; Step 5 then opens a second `contextId` against the same pod to prove conversations are isolated, not multiplexed onto a single Claude Code session.

### Step 1. Build up some state from the host

Terminal B (from this demo directory):

```bash
./client/send.sh 'Create a file called notes.md with three sections: "Goals", "Open Questions", and "Next Steps". Each section should have two placeholder bullet points.'

./client/send.sh 'Add a fourth section called "Risks" after "Open Questions", with two placeholder bullets.'

./client/send.sh 'In the "Goals" section, replace the placeholder bullets with: "ship v1 by end of quarter" and "onboard two new contributors".'
```

Each call returns the assistant's text reply. The client defaults `contextId` to `default`; export `A2A_CONTEXT_ID=...` to drive a different conversation in parallel. Confirm `notes.md` was actually written and the session-id pointer exists:

```bash
POD=$(kubectl get pod -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- cat /workspace/notes.md
kubectl exec "$POD" -- ls /home/node/.claude/a2a-sessions/
kubectl exec "$POD" -- cat /home/node/.claude/a2a-sessions/default
```

`a2a-sessions/` should contain one file per A2A `contextId` you've used, and each file holds the Claude Code session UUID being reused across A2A calls for that conversation.

### Step 2. Delete the pod

Terminal C:

```bash
./kill-by-pod.sh
# or, to mirror kill -9:
./kill-by-pod.sh default --force
```

Terminal A's `port-forward` will drop (the pod it was attached to is gone). The Sandbox controller schedules a replacement pod onto the same PVCs; the new pod's container restarts the A2A server, which reads the same `/home/node/.claude/a2a-sessions/<contextId>` files from the PVC.

### Step 3. Re-establish the port-forward against the new pod

Terminal A:

```bash
kubectl wait --for=condition=Ready --timeout=120s pod -l app=claude-crash-demo
kubectl port-forward svc/claude-crash-demo-a2a 8000:8000
```

The Service selector matches the new pod automatically; only the port-forward needs to be re-run because it's bound to a specific TCP session.

### Step 4. Send a follow-up that depends on prior context

Terminal B:

```bash
./client/send.sh 'In the Goals section of notes.md, append a third bullet: "establish weekly review cadence".'
```

Then verify:

```bash
POD=$(kubectl get pod -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- cat /workspace/notes.md
```

Expected:

- The new pod's `notes.md` contains all four sections from before (PVC-backed `/workspace`).
- The third bullet is appended to `Goals` — Claude Code understood "the Goals section of notes.md" without being re-told what `notes.md` is or what's in it. That's session continuity through the kill.
- `kubectl exec "$POD" -- cat /home/node/.claude/a2a-sessions/default` returns the same UUID as before. The session-id pointer survived because the file lives on the `/home/node/.claude` PVC.

### Step 5. Open a second, independent conversation

The previous four steps all ran against `contextId=default` (the client's default). Set a different `contextId` and the server should resume — or in this case, mint — a *different* Claude Code session that knows nothing about `notes.md`.

Terminal B:

```bash
A2A_CONTEXT_ID=ctx-bravo ./client/send.sh 'What files exist in the current working directory? List them, then create a file called bravo.md with a single line: "second conversation".'
```

Expected:

- The reply enumerates `/workspace` (so it can see `notes.md` on the shared PVC) but treats this as a fresh conversation — it does not reference the Goals/Risks/Next Steps structure or the prior edits, because the model has no transcript for them. That's session *isolation* between A2A `contextId`s on the same pod.
- A new pointer file appears alongside the existing one:

  ```bash
  POD=$(kubectl get pod -l app=claude-crash-demo -o jsonpath='{.items[0].metadata.name}')
  kubectl exec "$POD" -- ls /home/node/.claude/a2a-sessions/
  # default
  # ctx-bravo
  kubectl exec "$POD" -- cat /workspace/bravo.md
  # second conversation
  ```

Send another message in the same `ctx-bravo` to confirm continuity within the second conversation, then a message back on `default` to confirm it still remembers the original transcript:

```bash
A2A_CONTEXT_ID=ctx-bravo ./client/send.sh 'Append a second line to bravo.md: "still in the bravo session".'
./client/send.sh 'What is the fourth section of notes.md called?'
```

The first call edits `bravo.md` without re-introducing it; the second call answers "Risks" without being shown `notes.md` again. Two conversations, two Claude Code sessions, one pod, one set of PVCs.

---

## What to record

Same columns as demos 1–3, with two added rows for the A2A surface:

- **Where state lives on disk (pod):** `/home/node/.claude/` (incl. one file per A2A `contextId` under `a2a-sessions/`) and `/workspace`, both PVC-backed via the Sandbox's `volumeClaimTemplates` — scoped to the **Sandbox**, not the pod
- **Where state lives (off-pod):** the LiteLLM endpoint, the loaded image (`claude-crash-demo-a2a:local`), the `claude-litellm` Secret, the `Sandbox` object, the `claude-crash-demo-a2a` Service, and the two PVCs
- **Host-side state:** the `kubectl port-forward` TCP session — does not survive pod kill, must be re-run; no other host state
- **What survived the kill:** session history + project metadata under `/home/node/.claude`, `notes.md`, every `a2a-sessions/<contextId>` pointer, the Service (Service IP unchanged), the Sandbox, the PVCs, the image, the LiteLLM endpoint
- **What was lost:** the in-pod uvicorn process and its in-memory `InMemoryTaskStore` (so old A2A `Task` objects from before the kill are not addressable by id from the new pod — the *conversation* continues but *Task objects* don't)
- **Kill mechanism:** `kubectl delete pod` — the kubelet SIGTERMs the container and the agent-sandbox controller schedules a new pod that re-mounts the existing PVCs and restarts the server

## Why this works (and what it doesn't yet show)

Two things had to survive the kill for the A2A conversation to continue:

1. **Claude Code's own transcript** under `/home/node/.claude/projects/` — already PVC-backed in the prior demo, no change here.
2. **The Claude Code `session_id` the A2A server passes to `query(resume=...)`**, keyed by A2A `contextId` — persisted to `/home/node/.claude/a2a-sessions/<contextId>`, also on the PVC. Without this, the replacement pod's server would mint a fresh session and the model would have no idea what `notes.md` is.

The A2A server's `InMemoryTaskStore` does **not** survive the kill. For the synchronous request/reply pattern in this demo that doesn't matter — the host is using `message/send` and reading the assistant's reply inline. For workflows that depend on long-lived A2A `Task` ids (e.g. polling `tasks/get`, push notifications), the task store would also need to be PVC-backed or moved to an external store. That's the next variable to isolate, not part of this demo.

Streaming (`AgentCapabilities(streaming=True)` + `message/stream`) is a natural fit for `query()`'s async iterator and would let the host see assistant tokens as they arrive. Left off in v1 to keep the wire format minimal.

## Cleanup

```bash
kubectl delete -f manifests/sandbox.yaml
kubectl delete service claude-crash-demo-a2a --ignore-not-found
kubectl delete secret claude-litellm --ignore-not-found
# PVCs are retained by default (shutdownPolicy: Retain). Delete them explicitly:
kubectl delete pvc -l app=claude-crash-demo
```

Optionally uninstall the controller and tear down the cluster:

```bash
kubectl delete -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"
kind delete cluster
podman machine stop
```

## Open questions (revisit after running)

- **What if a client sends no `contextId`?** a2a-sdk mints one per request when the field is absent, which means each such call gets a fresh Claude Code session — fine for stateless calls, surprising if a client expected continuity. The demo client always sends `contextId` (defaulting to `"default"`); a server option to refuse contextId-less requests, or to pin them all to a single fallback session, is the next ergonomics call.
- **What does A2A streaming look like with `claude-agent-sdk`?** `query()` yields messages incrementally; an A2A streaming endpoint would map each `AssistantMessage` to a `TaskStatusUpdateEvent` or partial `Artifact`. Worth a follow-up when the host wants progress visibility.
- **Does `InMemoryTaskStore` loss matter in practice?** The kill drops Task objects. If a host workflow uses `tasks/get` for retry or audit, the task store needs the same PVC-or-external-store treatment as the session pointer.
- **Port-forward is fine for a demo, but does it bias the kill scenario?** The host's TCP session always drops on pod kill regardless of state strategy. A NodePort or Ingress would let us isolate "did the conversation survive?" from "did the transport survive?" — relevant if we extend this to a long-running host client.
- **The June 2026 SDK billing change** (separate Agent SDK credit pool on subscription plans) does not apply here because the LiteLLM proxy authenticates with `ANTHROPIC_AUTH_TOKEN`. Worth noting if anyone reproduces this with a direct Anthropic key on a subscription account.

## Inspecting the in-pod session interactively

If you `kubectl exec` into the pod and want to open the session the A2A server has been driving, the bare-picker form does **not** show it:

```bash
kubectl exec -it "$POD" -- bash
cd /workspace
claude --resume        # picker is empty (or omits the SDK session)
```

The transcript is on disk — `ls ~/.claude/projects/-workspace/` shows the JSONL — but the CLI's interactive picker filters it out. Records written by the SDK are tagged `"entrypoint":"sdk-py"` / `"promptSource":"sdk"`, and the picker appears to scope to human/CLI-originated sessions. Pass the id directly instead:

```bash
claude --resume "$(cat /home/node/.claude/a2a-sessions/default)"
```

(Substitute the `contextId` whose conversation you want to inspect — `ls /home/node/.claude/a2a-sessions/` shows all of them.) This loads the SDK-driven session as expected. Useful for debugging what the A2A server actually said to Claude Code across a kill.
