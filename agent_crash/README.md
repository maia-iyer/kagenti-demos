# Agent Crash

Crash-recovery experiments for agent harnesses — the first experiment track for the Kagenti state-management initiative. The directory is named `agent_crash` (not `claude_crash`) so it can host non-Claude harnesses (OpenShell, future entrants) alongside the Claude Code demos.

The forcing question: when a harness process is killed, what state must the platform own versus what the harness can reconstruct? Each demo kills a harness (locally or as a pod) and observes whether the session resumes cleanly.

## Demos

| # | Demo | Harness | Environment | Status |
|---|------|---------|-------------|--------|
| 1 | [claude_code_local_single](./claude_code_local_single/) | Claude Code | Local | Sketch |
| 2 | [claude_code_kind_single](./claude_code_kind_single/) | Claude Code | Kind (emptyDir, Deployment) | Sketch |
| 3 | [claude_code_kind_agentsandbox_single](./claude_code_kind_agentsandbox_single/) | Claude Code | Kind (PVC, agent-sandbox) | Sketch |
| 4 | [claude_code_kind_agentsandbox_a2a](./claude_code_kind_agentsandbox_a2a/) | Claude Code (via A2A) | Kind (PVC, agent-sandbox) | Sketch |
| 5 | [claude_code_kind_agentsandbox_a2a_template](./claude_code_kind_agentsandbox_a2a_template/) | Claude Code (via A2A) | Kind (PVC, agent-sandbox extensions: Template + WarmPool + Claim) | Validated end-to-end |

Demos 2 and 3 share the harness, image, workload, and kill mechanism — only the storage layer and the controller change. Demo 2 is the negative control (loss expected); demo 3 is the positive control (survival expected). Demo 4 reuses demo 3's storage model but swaps the host-to-pod surface from `kubectl exec` to A2A, probing whether a local-TUI harness can be exposed as an A2A agent without harness changes. Demo 5 reuses demo 4's app, image, and client and re-provisions the sandbox via the `extensions.agents.x-k8s.io` chain (`SandboxTemplate` → `SandboxWarmPool` → `SandboxClaim`) instead of a direct `Sandbox`, probing what the claim layer adds and what it doesn't — see that demo's README for the validated pod-kill recovery and the negative result on `lifecycle.shutdownPolicy: Retain`.

Additional scenarios (Claude Code multi-session, OpenShell local/multi/Kind) are outlined in [`scratch.md`](./scratch.md) and will be promoted into their own demo directories as they are built.

## Future demos

Each agent-sandbox capability addresses a different platform concern. Each one motivates its own demo — keep the existing demos focused on a single variable, and let new demos grow the track.

- **Multi-tenant claim load** — many concurrent users, each backed by a per-user `SandboxClaim` against a shared `SandboxTemplate`, with `replicas: N` in the warm pool. Measure claim-acquisition latency, observe whether warm-pool replenishment keeps up under churn, and confirm per-user PVC isolation under realistic traffic. Demo 5 stops at one user; this is the actual multi-tenant story.
- **Shared memory between claimed sandboxes** — two claims (same template or different) that need to read/write the same persistent state. `volumeClaimTemplates` produces a fresh per-Sandbox PVC and can't express this; the demo would need a pre-created RWX PVC referenced via `podTemplate.spec.volumes`, or an external state surface (DB, vector store) consumed via env. Probes the gap demo 5 surfaced when `kubectl delete sandboxclaim` cascade-deleted the Sandbox and its PVCs regardless of `lifecycle.shutdownPolicy`.
- **Graceful suspend vs. abrupt kill** (Sandbox snapshots) — contrast `OperatingMode: Suspended` (or `sandbox.suspend()` from the SDK) with the `kubectl delete pod` flow. Both end with the pod down, but only suspend preserves in-memory state via a snapshot. Currently tied to gVisor + GKE Autopilot, so this demo would target GKE rather than Kind.
- **Heterogeneous templates behind one platform** — a `claude-code-template` and a `hermes-template` (or similar) co-resident in the same cluster, claims routed to one or the other by an orchestrator. Tests the template-as-contract framing under actual harness diversity, not just one template repeated.

Shared helpers, manifests, and libraries will move into `shared/` the first time two demos need the same piece.
