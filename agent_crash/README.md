# Agent Crash

Crash-recovery experiments for agent harnesses — the first experiment track for the Kagenti state-management initiative. The directory is named `agent_crash` (not `claude_crash`) so it can host non-Claude harnesses (OpenShell, future entrants) alongside the Claude Code demos.

The forcing question: when a harness process is killed, what state must the platform own versus what the harness can reconstruct? Each demo kills a harness (locally or as a pod) and observes whether the session resumes cleanly.

## Demos

| # | Demo | Harness | Environment | Status |
|---|------|---------|-------------|--------|
| 1 | [claude_code_local_single](./claude_code_local_single/) | Claude Code | Local | Sketch |
| 2 | [claude_code_kind_single](./claude_code_kind_single/) | Claude Code | Kind (emptyDir, Deployment) | Sketch |
| 3 | [claude_code_kind_agentsandbox_single](./claude_code_kind_agentsandbox_single/) | Claude Code | Kind (PVC, agent-sandbox) | Sketch |

Demos 2 and 3 share the harness, image, workload, and kill mechanism — only the storage layer and the controller change. Demo 2 is the negative control (loss expected); demo 3 is the positive control (survival expected).

Additional scenarios (Claude Code multi-session, OpenShell local/multi/Kind) are outlined in [`scratch.md`](./scratch.md) and will be promoted into their own demo directories as they are built.

Shared helpers, manifests, and libraries will move into `shared/` the first time two demos need the same piece.
