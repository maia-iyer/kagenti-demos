# Agentic sandboxing demos

Experiments and demos exploring what agentic workloads look like when their
work runs inside sandboxes rather than directly on the developer's laptop.

Two arrangements are in scope:

- **Separate sandbox** — the agent harness (e.g. Claude Code) runs on the
  laptop, and only individual tool calls (shell commands, code execution)
  are redirected into a sandbox. The agent process itself stays local.
- **Encapsulated sandbox** — the agent harness itself runs inside the
  sandbox, so both the agent and everything it does are contained.

## What's here

| Directory | Arrangement | What it demonstrates |
| --- | --- | --- |
| [`local_claude_code_kind_substrate_sandbox/`](local_claude_code_kind_substrate_sandbox/) | Separate | Claude Code on the laptop with every shell command redirected into a per-session [Agent Substrate](https://github.com/agent-substrate/substrate) actor on a local kind cluster. Includes an eager mode (actor stays Running for the whole session) and a lazy mode (actor is resumed/suspended per command). |
| [`burst_multiplex_kind_substrate/`](burst_multiplex_kind_substrate/) | Shared pool | 300 counter actors on a pool pinned to 3 workers, hit with a burst of concurrent HTTP requests. Exercises both actor multiplexing (substrate rotates actors through the few workers) and request parking (the atenet router queues inbound requests during the resume gap instead of returning 503s). Fully local — no API keys, no docker build, no cloud storage. |
| [`moca_chained_subagents/`](moca_chained_subagents/) | Separate (leaf dispatch) | Claude Code on the laptop with the built-in `Task` subagent tool denied. Delegation goes through a skill that dispatches two sequential MOCA leaves (`rossoctl/serverless-harness`): a read-only researcher followed by a read-write fixer, both backed by the same Context Service PVC. Shows substrate-enforced read-only isolation on the researcher and the shape of parent-orchestrated A→B chaining on a serverless harness. |
