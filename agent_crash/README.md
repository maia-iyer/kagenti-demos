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

Demos 2 and 3 share the harness, image, workload, and kill mechanism — only the storage layer and the controller change. Demo 2 is the negative control (loss expected); demo 3 is the positive control (survival expected). Demo 4 reuses demo 3's storage model but swaps the host-to-pod surface from `kubectl exec` to A2A, probing whether a local-TUI harness can be exposed as an A2A agent without harness changes.

Additional scenarios (Claude Code multi-session, OpenShell local/multi/Kind) are outlined in [`scratch.md`](./scratch.md) and will be promoted into their own demo directories as they are built.

## Future demos

Each agent-sandbox extension addresses a different platform capability. Each one motivates its own demo — keep the existing demos focused on a single variable, and let new demos grow the track.

- **Multi-user crash recovery** (`SandboxTemplate` + `SandboxClaim`) — many concurrent users, each backed by a per-user `SandboxClaim` against a shared `SandboxTemplate`. Kill user A's pod and confirm A's PVC returns to A's replacement pod, not B's. Tests PVC partitioning across many sandboxes from one template.
- **Fast resume via warm pool** (`SandboxWarmPool`) — keep N pre-warmed Sandboxes ready so claims resolve without the image-pull + PVC-provisioning latency. Different question from crash recovery (provisioning latency, not state survival), but a real platform capability worth demonstrating on its own. Note: a warm pool hands out a *different* Sandbox with *different* PVCs, so it would break the survival contract of the current PVC demo if mixed in.
- **Graceful suspend vs. abrupt kill** (Sandbox snapshots) — contrast `OperatingMode: Suspended` (or `sandbox.suspend()` from the SDK) with the `kubectl delete pod` flow. Both end with the pod down, but only suspend preserves in-memory state via a snapshot. Currently tied to gVisor + GKE Autopilot, so this demo would target GKE rather than Kind.

Shared helpers, manifests, and libraries will move into `shared/` the first time two demos need the same piece.
