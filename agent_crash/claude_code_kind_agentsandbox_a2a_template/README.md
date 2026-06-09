# Claude Code in Kind — A2A surface, provisioned via SandboxTemplate + SandboxWarmPool + SandboxClaim

Same workload, image, and A2A surface as [`claude_code_kind_agentsandbox_a2a`](../claude_code_kind_agentsandbox_a2a/), but the sandbox is **not** declared with a single `Sandbox` object. Instead a platform-team `SandboxTemplate` carries the podSpec, a small `SandboxWarmPool` keeps one pre-warmed sandbox ready, and a developer-facing `SandboxClaim` adopts it. The host A2A client is unchanged.

The forcing question this demo probes: **does provisioning through the Template/WarmPool/Claim chain (`extensions.agents.x-k8s.io/v1alpha1`) change what survives a kill, and what does the claim layer let us show that direct-Sandbox creation can't?**

Answer (validated by running it end-to-end against agent-sandbox v0.4.6 / API v1alpha1):

- **Pod kill:** identical to the direct-Sandbox demo. The Sandbox name doesn't change when the Pod is recycled, so the same PVCs re-attach and the conversation continues.
- **Claim delete:** in v1alpha1, the claimed Sandbox and its PVCs are cascade-deleted with the claim regardless of `lifecycle.shutdownPolicy`. The "preserve PVCs across claim teardown" story I wanted to demo isn't supported by this version — see the **Findings** section below for what actually happens and why.

So this iteration's net result is: the claim chain reproduces the prior demo's pod-kill recovery, adds operator/user separation as a bookkeeping benefit, and exposes a sharp limit on what `shutdownPolicy` actually controls.

## Architecture

```
host                                kind cluster
─────                               ────────────
send.sh ──► localhost:8000 ──port-forward──► svc/claude-crash-demo-a2a:8000
                                                          │
                                                          ▼
                                              SandboxClaim claude-crash-demo
                                                  │  (sandboxTemplateRef + warmpool name)
                                                  ▼
                                              SandboxWarmPool claude-crash-demo-pool
                                                  │  (instantiates from)
                                                  ▼
                                              SandboxTemplate claude-crash-demo-template
                                                  │  (defines)
                                                  ▼
                                                 pod (Sandbox-managed, named claude-crash-demo-pool-<rand>)
                                                  ├── server/main.py  (a2a-sdk)
                                                  │     └── claude-agent-sdk.query()
                                                  │           ├─ resume=<id from /home/node/.claude/a2a-sessions/<contextId>>
                                                  │           └─ cwd=/workspace
                                                  ├── /home/node/.claude   (PVC, from template's volumeClaimTemplates)
                                                  └── /workspace      (PVC, from template's volumeClaimTemplates)
```

Server behavior is identical to the prior demo: each A2A request maps to a Claude Code session keyed by `contextId`, persisted at `/home/node/.claude/a2a-sessions/<contextId>` on the PVC, so the model resumes where it left off.

## What's actually different from the prior demo (recorded after running)

- **Two separate API groups, two install steps.** The core `Sandbox` CRD lives in `agents.x-k8s.io`; `SandboxTemplate`, `SandboxWarmPool`, `SandboxClaim` live in `extensions.agents.x-k8s.io` and ship as a separate `extensions.yaml`.
- **In v0.4.6, the API version is `v1alpha1`, not `v1beta1`.** The repo `main` branch is on v1beta1 with a different field shape; the released artifacts are still alpha. Schemas can be inspected directly: `kubectl get crd sandboxclaims.extensions.agents.x-k8s.io -o yaml`.
- **`SandboxClaim.spec` in v1alpha1 references the template directly** (`sandboxTemplateRef`) plus a `warmpool` string field selecting which pool to draw from. There is no `warmPoolRef` in this version (that's a v1beta1 shape).
- **Resource names propagate from the warm pool, not the claim.** A claim against `claude-crash-demo-pool` adopts a Sandbox named `claude-crash-demo-pool-<5-char-random>`. Pods, controller-managed Services, and PVCs all derive their names from the *adopted Sandbox*, not the *claim*. To find the adopted Sandbox: `kubectl get sandboxclaim claude-crash-demo -o jsonpath='{.status.sandbox.name}'`.
- **`template.spec.service: true` creates a headless Service with no ports.** It only provides stable DNS for the sandbox; the host can't `port-forward` against it. This demo adds an explicit `manifests/service.yaml` that selects on the pod label `role: claimed` (injected via the claim's `additionalPodMetadata`), so it routes only to the claimed pod and survives sandbox replacement.
- **Pod labels propagate cleanly from `template.spec.podTemplate.metadata.labels`** to all pods derived from the template — including the warm spare. Without disambiguation, a selector on `app=claude-crash-demo` would match both the claimed pod and the warm spare. The claim's `additionalPodMetadata.labels.role: claimed` is what disambiguates them; `kill-by-pod.sh` and `service.yaml` both select on it.
- **PVCs are NOT labeled.** `kubectl get pvc -l app=claude-crash-demo` returns empty even though the pods carry the label. Use sandbox names (`kubectl get pvc | grep claude-crash-demo`) for cleanup.

## Prerequisites

- A running Kind cluster on top of a Podman machine
- `kubectl` configured against that cluster (`kubectl cluster-info`)
- A LiteLLM endpoint that speaks the Anthropic API, plus an API key for it
- `MY_LITELLM` and `MY_LITELLM_TOKEN` exported

Two terminals: A runs the port-forward; B runs `send.sh` and the kill commands.

### Start the Podman machine and Kind cluster

```bash
podman machine start
podman info >/dev/null && echo "podman ready"

export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster
kubectl cluster-info
```

## Install the controller and the extensions

```bash
export AGENT_SANDBOX_VERSION="v0.4.6"

# Core Sandbox CRD + controller (same as the prior demo)
kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"

# Extensions: SandboxTemplate, SandboxWarmPool, SandboxClaim
kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/extensions.yaml"

kubectl wait --for=condition=Available --timeout=120s \
  deployment/agent-sandbox-controller -n agent-sandbox-system

kubectl get crd | grep -E 'sandbox(es|templates|warmpools|claims)'
```

## Build the demo image

The image is unchanged from the prior A2A demo (`claude-crash-demo-a2a`):

```bash
podman build -t localhost/claude-crash-demo-a2a:local .
kind load docker-image localhost/claude-crash-demo-a2a:local
podman exec kind-control-plane crictl images | grep claude-crash-demo-a2a
```

## Setup

> **Safety note:** the kill script in this directory targets only pods labeled `app=claude-crash-demo,role=claimed`. The `role=claimed` selector is what keeps it from also killing the warm-pool spare. Do **not** strip it.

```bash
export ANTHROPIC_MODEL="<the model id your LiteLLM serves>"

kubectl create secret generic claude-litellm \
  --from-literal=ANTHROPIC_AUTH_TOKEN="$MY_LITELLM_TOKEN"

# Apply in dependency order: template, then pool (references template), then claim (references both).
sed -e "s|\${MY_LITELLM}|$MY_LITELLM|g" \
    -e "s|\${ANTHROPIC_MODEL}|$ANTHROPIC_MODEL|g" \
    manifests/template.yaml | kubectl apply -f -

kubectl apply -f manifests/warmpool.yaml
kubectl apply -f manifests/claim.yaml
kubectl apply -f manifests/service.yaml

kubectl wait --for=condition=Ready --timeout=180s pod -l role=claimed
```

Confirm the chain:

```bash
kubectl get sandboxtemplate
kubectl get sandboxwarmpool
kubectl get sandboxclaim
kubectl get sandbox
kubectl get pod -l app=claude-crash-demo
kubectl get pvc | grep claude-crash-demo
kubectl get sandboxclaim claude-crash-demo -o jsonpath='{.status.sandbox.name}'; echo
```

You should see two Sandboxes (one adopted by the claim, one warm spare the pool replenished), one explicit Service (`claude-crash-demo-a2a`, with port 8000), and four PVCs (two per Sandbox).

Sanity-check the server is up:

```bash
kubectl logs -l role=claimed --tail=20
```

Expect uvicorn's `Application startup complete.`

### Forward the A2A port to the host

Terminal A:

```bash
kubectl port-forward svc/claude-crash-demo-a2a 8000:8000
```

The Service routes by label (`app=claude-crash-demo,role=claimed`), so its endpoint follows the claimed pod across pod restarts. The port-forward TCP session itself still drops on pod kill — Kubernetes' problem, not the Service's — and must be re-run. See the prior demo's open questions on this.

Confirm:

```bash
curl -s http://localhost:8000/.well-known/agent-card.json | head -40
```

---

## Scenario A — Pod kill (validated)

Three context-building messages, kill the pod, send a follow-up that depends on prior context, observe continuity. This is the same scenario the prior demo runs; the question here is whether the claim chain changes anything. (It doesn't.)

### A.1 Build state

Terminal B:

```bash
./client/send.sh 'Create a file called notes.md with three sections: "Goals", "Open Questions", and "Next Steps". Each section should have two placeholder bullet points.'

./client/send.sh 'Add a fourth section called "Risks" after "Open Questions", with two placeholder bullets.'

./client/send.sh 'In the "Goals" section, replace the placeholder bullets with: "ship v1 by end of quarter" and "onboard two new contributors".'
```

Inspect:

```bash
POD=$(kubectl get pod -l role=claimed -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- cat /workspace/notes.md
kubectl exec "$POD" -- cat /home/node/.claude/a2a-sessions/default
```

### A.2 Delete the pod

```bash
./kill-by-pod.sh
# or, to mirror kill -9:
./kill-by-pod.sh default --force
```

Terminal A's port-forward drops. The controller schedules a replacement pod under the *same Sandbox name*, so the existing PVCs re-attach.

### A.3 Re-establish the port-forward and verify

Terminal A:

```bash
kubectl wait --for=condition=Ready --timeout=120s pod -l role=claimed
kubectl port-forward svc/claude-crash-demo-a2a 8000:8000
```

Terminal B:

```bash
./client/send.sh 'In the Goals section of notes.md, append a third bullet: "establish weekly review cadence".'

POD=$(kubectl get pod -l role=claimed -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- cat /workspace/notes.md
kubectl exec "$POD" -- cat /home/node/.claude/a2a-sessions/default
```

**Expected and observed:** the third bullet is appended to Goals, all four sections are intact, and the session-id pointer is the same UUID as before the kill. Conversation continuity through pod kill works identically to the direct-Sandbox demo.

---

## Findings — why the originally-planned Scenario B doesn't work

The original v2 plan included a Scenario B: delete the SandboxClaim with `lifecycle.shutdownPolicy: Retain`, observe PVCs surviving, recreate the claim, observe the new sandbox re-attaching the retained PVCs, and continue the conversation. **In v1alpha1, none of that works as I expected.** Recording the actual behavior because the negative result is the answer to the open question this demo was meant to probe.

### What `shutdownPolicy` actually controls

From the v1alpha1 source (`extensions/api/v1alpha1/sandboxclaim_types.go`):

> shutdownTime is the absolute time when the SandboxClaim expires. … the SandboxClaim controller enforces this expiration by deleting the Sandbox resources when the time is reached.
>
> shutdownPolicy determines the behavior when the **SandboxClaim expires**.

The field comment for `Retain` (paraphrased from what I observed in the controller behavior) is: the *claim object* is retained after expiry; the *underlying Sandbox, Pod, and Service are deleted to save resources*.

So `shutdownPolicy: Retain` means "keep the claim CR around so external observers can see it expired" — not "preserve the underlying state across claim teardown." There is no setting on the claim that prevents cascade-deletion of the Sandbox and its PVCs when the claim is removed.

### What I observed when I ran `kubectl delete sandboxclaim claude-crash-demo`

1. The claim was deleted.
2. The claimed Sandbox (owned by the claim via `ownerReferences` with `blockOwnerDeletion: true`) was cascade-deleted.
3. The claimed Sandbox's PVCs (owned by the Sandbox via `volumeClaimTemplates`) were cascade-deleted.
4. The warm spare Sandbox `-p5wxz` and its PVCs survived because they're owned by the warm pool, not the claim.
5. Re-applying `manifests/claim.yaml` adopted the warm spare `-p5wxz` (which had always-empty volumes) and the warm pool minted a fresh `-4cxnl` to replenish itself.
6. The new pod's `/workspace` is empty and `/home/node/.claude/a2a-sessions/` doesn't exist. Conversation lost.

### Why this is the right answer to record, not work around

Two of the open questions on `kagenti-state-management` are *"can a developer-facing claim layer hide the platform-team PVC mechanics?"* and *"what's the unit of state ownership in agent-sandbox?"* The empirical answer at v1alpha1 is: **the unit of state ownership is the `Sandbox`, not the `SandboxClaim`.** PVCs travel with the Sandbox via `volumeClaimTemplates`. The claim is a thin wrapper that creates, adopts, and (on deletion) destroys Sandboxes. If you want state to outlive a claim teardown, you'd need to either (a) detach the PVC from the Sandbox lifecycle (not currently supported by `volumeClaimTemplates`), (b) write the persistent state to an external store, or (c) avoid deleting the claim and use `shutdownPolicy` only for `shutdownTime`-driven expiration.

A v1beta1 SandboxClaim adds different fields (`warmPoolRef`, no direct `templateRef`) and may change these semantics — not validated here.

---

## What to record

- **Provisioning chain:** SandboxTemplate → SandboxWarmPool → SandboxClaim → Sandbox → Pod. Five resources to express what one `Sandbox` did before, plus an explicit Service on top because the controller-managed one carries no ports.
- **Where state lives on disk (pod):** `/home/node/.claude/` (incl. `a2a-sessions/<contextId>` files) and `/workspace`, both PVC-backed via the **template's** `volumeClaimTemplates` — scoped to whichever Sandbox the claim adopted, not to the claim itself.
- **Where state lives (off-pod):** LiteLLM endpoint, image, `claude-litellm` Secret, the SandboxTemplate, the SandboxWarmPool, the SandboxClaim, the adopted Sandbox, the warm spare Sandbox, the controller-managed headless Service, the explicit demo Service, and four PVCs (two per Sandbox).
- **Host-side state:** `kubectl port-forward` TCP session — drops on pod kill, must be re-run.
- **Scenario A — what survived the pod kill:** transcripts, `notes.md`, `a2a-sessions/<contextId>` pointers, all CRs, both PVC pairs, both Services. The new pod re-attached the same PVCs because the Sandbox name didn't change.
- **Scenario B (attempted) — what survived the claim delete:** the WarmPool, the Template, the warm spare Sandbox + its PVCs (which were always empty), the explicit demo Service. Lost: the claimed Sandbox, the Pod, the controller-managed Service, both claimed-Sandbox PVCs, all transcripts, `notes.md`, and the session pointer.
- **Kill mechanism (validated):** `kubectl delete pod` — works as expected.
- **Kill mechanism (negative result):** `kubectl delete sandboxclaim` — does not preserve state regardless of `shutdownPolicy`.

## Cleanup

```bash
kubectl delete -f manifests/service.yaml --ignore-not-found
kubectl delete -f manifests/claim.yaml --ignore-not-found
kubectl delete -f manifests/warmpool.yaml --ignore-not-found
kubectl delete -f manifests/template.yaml --ignore-not-found
kubectl delete secret claude-litellm --ignore-not-found
# Any surviving PVCs (warm spare's, etc.) — they aren't labeled, so list and delete:
kubectl get pvc | grep claude-crash-demo
# kubectl delete pvc <names>
```

Optionally uninstall everything:

```bash
kubectl delete -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/extensions.yaml"
kubectl delete -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"
kind delete cluster
podman machine stop
```

## Open questions (revisit later)

- **Does v1beta1 (when released) preserve PVCs across claim teardown?** The struct shape changed substantially between v1alpha1 (sandboxTemplateRef + warmpool name) and v1beta1 (warmPoolRef only). Whether the PVC ownership model also changed is the load-bearing question for the kagenti-state-management initiative.
- **Is there a way in v1alpha1 to express "this PVC outlives the Sandbox"?** Not via `volumeClaimTemplates`. The path is probably PVCs created out-of-band and referenced via `volumes:` in the pod spec rather than through the template — at the cost of losing the per-sandbox isolation `volumeClaimTemplates` provides. Worth a separate experiment.
- **What's the right way to expose A2A from a SandboxClaim-provisioned pod?** This demo adds an explicit Service with a `role: claimed` selector. An alternative would be a Service per claim, with the claim's controller managing it. Currently the developer is responsible for that wiring — that's a real friction point versus the direct-`Sandbox` demo where the user owned it anyway.
- **Does the warm pool actually accelerate kill recovery in this setup?** Pod-kill in Scenario A doesn't exercise the pool — the Sandbox name is preserved and the controller just makes a new Pod under it. The pool only accelerates *new claim acquisition*, which this demo doesn't test under load. Worth a separate scenario if cold-start time becomes the question.
