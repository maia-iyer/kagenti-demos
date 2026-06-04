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

_None yet._

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

## Superseded

Move overturned findings here with a pointer to the replacement.

_None yet._
