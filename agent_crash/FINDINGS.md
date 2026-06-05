# Agent Crash — Findings

Cross-demo findings for the [`kagenti-state-management`](../../../maiasaurus-wiki/pages/initiatives/kagenti-state-management.md) initiative. Per-demo logs stay in each demo directory.

Working stance under test: **platform preserves, harness reconstructs** — memory via filesystem-substrate preservation; skills/protocols as platform primitives.

## Findings

<!-- Template:
### YYYY-MM-DD — <finding>
- Demos: <dirs>
- Bears on: <open question / stance claim>
- Result: what happened, what it means for the stance.
-->

### 2026-06-04 — PVC-backed `/root/.claude` survives `kubectl delete pod` with no harness changes
- Demos: `claude_code_kind_agentsandbox_single`
- Bears on: open question "Does a PVC-backed `~/.claude` survive `kubectl delete pod` such that a replacement pod resumes the session without harness changes?"
- Result: Replacement pod (new UID) came up with `notes.md` byte-identical and the session jsonl (`877289a5-...jsonl`, 25513 bytes, same mtime) untouched. `claude --print --resume <id>` in the new pod recalled prior-conversation context that exists only in the jsonl ("your two bullets") — i.e. the harness reconstructed the in-memory conversation from filesystem state alone. Confirms the "platform preserves, harness reconstructs" stance for the between-turns case on PVC storage. Mid-tool-call and mid-inference kills are still untested; this is the easy case.

### 2026-06-04 — Mounting `~/.claude/` is not enough: `~/.claude.json` is a sibling and holds load-bearing state
- Demos: `claude_code_kind_agentsandbox_single`
- Bears on: open question "What is the minimum filesystem guarantee the platform must provide — whole `$HOME`, `~/.claude/` only, or a harness-declared path set?"
- Result: The Sandbox PVC mounts `/root/.claude/` (directory), which covers the session jsonl under `projects/` — the load-bearing artifact for `--resume`. But `~/.claude.json` (a *file*, sibling not child) sits on the pod's writable layer and is wiped on kill. Per the [Claude Code settings docs](https://code.claude.com/docs/en/settings), this file holds the OAuth session, per-project trust decisions, per-project allowed tools, user- and local-scope MCP server configs, and various caches. Our demo didn't notice because it uses `ANTHROPIC_AUTH_TOKEN` (no OAuth), `--print` mode (no trust dialog), no MCP servers, and an explicit `--resume <id>` (bypasses project-state lookup). A typical interactive user would silently lose login, every per-project trust answer, every allowed-tools approval, and every MCP server registration on each pod kill — while session jsonl resume "works." Argues the contract should be a *harness-declared path set* (not "mount `~/.claude/`"), and that "must be file-backed *and* under a single declared root" deserves to be promoted as a legibility antipattern for harness authors who scatter state across `$HOME`. Concretely: this demo's manifest should also mount `/root/.claude.json` (or move to mounting all of `/root` / `$HOME`).

### 2026-06-04 — A2A surface survives pod kill, but the contract is the harness author's declared path set
- Demos: `claude_code_kind_agentsandbox_a2a`
- Bears on: open questions on A2A shim state and `InMemoryTaskStore` loss
- Result: Conversation continued across the kill — replacement pod correctly applied "append a third bullet to the Goals section" without re-context. The in-pod A2A server's only load-bearing state is `/home/node/.claude/a2a-session-id` (a UUID it writes on first call, reads thereafter, passes as `query(resume=...)`); with that file PVC-backed the server is stateless from the platform's view. But A2A's other identity layer — the **Task** (one user→assistant exchange, addressable by `task_id` for `tasks/get` / push notifications) — is held in `InMemoryTaskStore` (a Python dict in RAM) and dies with the pod. Synchronous `message/send` doesn't observe this; a host polling `tasks/get` across a kill would get a 404. Same shape as the `.claude.json` finding: harness authors scatter state across in-RAM, `~/.claude/`, sibling files, and per-server data structures, and the platform contract has to be the harness's declared path set, not a fixed convention.

### 2026-06-04 — The demo's "one UUID file per pod" is minimum viable harness-to-A2A glue, not the right interface
- Demos: `claude_code_kind_agentsandbox_a2a`
- Bears on: harness interface design (see Questions surfaced)
- Result: The A2A server collapses every `SendMessage` into the same Claude Code session and never reads A2A's `contextId`. Three consequences: two unrelated A2A clients on the same pod cross-contaminate transcripts; the host can't address prior conversations; Task records aren't addressable across kills. The principled shape is `contextId → claude_session_id` persisted on the PVC, with the same store backing `TaskStore`. Treat this as evidence the single-session contract works, not as a template for multi-session harness servers.

### 2026-06-04 — emptyDir loss is total and silent on the replacement pod
- Demos: `claude_code_kind_single`
- Bears on: open question "Is `emptyDir` loss silent for Claude Code (fresh session, no error)?"
- Result: After `kubectl delete pod` on a Deployment whose `/workspace` and `/root/.claude` were `emptyDir`, the replacement pod came up with both directories empty — no `notes.md`, no `projects/` subtree, no marker that prior state ever existed. The harness has no signal that it's a *replacement* rather than a *first* boot; from inside the pod the situation is indistinguishable from a clean install. This argues the preservation contract needs an explicit failure mode (e.g. a controller annotation or sentinel file the harness can read) — silent loss makes "platform preserves" undetectable from inside the harness.

## Questions surfaced

Promote into the initiative page once sharp.

- Does Claude Code resume cleanly from `~/.claude/` after a `kill -9`, both between turns and mid-tool-call / mid-inference?
- Does a PVC-backed `~/.claude` survive `kubectl delete pod` such that a replacement pod resumes the session without harness changes?
- When the harness resumes, what state is *not* recovered from the filesystem alone — bash cwd/env, background processes, in-flight tool calls — and which of those are load-bearing?
- Is filesystem-substrate preservation sufficient, or does the platform also need a snapshot/checkpoint primitive to cover mid-inference and mid-skill kills?
- What is the minimum filesystem guarantee the platform must provide — whole `$HOME`, `~/.claude/` only, or a harness-declared path set?
- Do any target harnesses (Hermes, Goose, OpenShell) hold load-bearing state in memory without writing to disk, breaking the "platform preserves, harness reconstructs" stance?
- Should "must be file-backed" be promoted to a legibility antipattern the initiative calls out for harness authors?
- Exposing a local-TUI harness over A2A appears to require an in-pod shim — does the shim itself carry state the platform must preserve, and what is its lifecycle relative to the harness pod?
- Is `emptyDir` loss silent for Claude Code (fresh session, no error), and if so does the preservation contract need explicit failure modes rather than best-effort guarantees?
- Is there an observable difference between killing between turns vs. mid-turn on PVC-backed storage, or does the preservation contract collapse to a single case?
- What should the harness-to-A2A interface look like for a multi-session agent? `contextId → session_id` mapping seems right — where does the mapping live (PVC file, sqlite, external store) and which component owns its schema?
- Should the platform offer `TaskStore` as a primitive (PVC-backed or external), so individual harness authors don't each re-derive whether their A2A `Task` records survive a kill?
- For multi-session harnesses, what is the unit of isolation — one Claude Code session per `contextId`, or one pod per user with multiple sessions inside? Affects whether PVC partitioning (per-`contextId` or per-user) is the right shape.
- Is there a minimum interface harness authors should declare to the platform — a manifest of "paths I need preserved" + "RPC surface I expose" — so the platform can enforce the preservation contract instead of trusting per-harness convention?

## Superseded

Move overturned findings here with a pointer to the replacement.

_None yet._
