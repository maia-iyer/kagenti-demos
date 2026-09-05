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
