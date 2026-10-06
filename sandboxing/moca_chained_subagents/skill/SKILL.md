---
name: moca-dispatch
description: Dispatch a subagent to the MOCA serverless harness as an isolated leaf. Use this skill whenever the operator asks you to "use a subagent", "delegate", "run this remotely", "fan out", or anything else that would ordinarily go through the Task tool — Task is denied in this session, so this is the only subagent path. Dispatch is asynchronous: a start call returns a run handle, and a separate check call returns the result when the leaf finishes. The operator can quit Claude between those two steps and resume later.
---

# MOCA dispatch

This session has **no access to the built-in `Task` tool** — it is denied
in `.claude/settings.json`. To run a subagent, dispatch a MOCA leaf via
the `moca` CLI described below. If you try `Task` the permission layer
will refuse; re-route through this skill instead of asking the operator
to lift the deny.

**Do not shell out to `curl` against MOCA directly.** The scratch dir
ships a `moca` CLI (on `PATH`) that wraps dispatch, status polling, and
record-keeping. Using the CLI keeps permission prompts short and
readable (`moca start …` instead of a many-flag `curl` line), and
guarantees run records on disk are shaped the way a resumed session
expects. If the operator asks you to use `curl` directly, surface that
the CLI exists and prefer it.

This skill is **mechanism only**. It tells you how to run and collect
one leaf. It does **not** tell you how many leaves to run, in what
order, or with what prompts — those decisions come from the operator's
request. If the operator asks for one leaf, run one. If they ask for a
chain, start them in sequence and feed outputs forward as they
describe.

## The CLI

The scratch dir contains `MOCA.md` (base URL, host header, run-id,
workspace path) and a `moca` binary. Run it from the scratch dir —
it reads `MOCA.md` from the current working directory.

Three subcommands:

- `moca start <session-id> <prompt-file>` — dispatch a leaf. Writes a
  record file in `.moca-runs/`. Returns immediately.
- `moca check <session-id>` — poll a leaf. If done, writes the full
  response body to a sibling result file and prints the leaf's
  answer text to stdout. If still running, says so.
- `moca list` — show every run record and its current status.

Session ids are `<run-id>/<leaf-label>`, e.g. `review-123/diagnose`.
Reuse `<run-id>` from `MOCA.md` across leaves in the same operator
request so they share a run identity. `<leaf-label>` is a short
identifier within the run (e.g. `diagnose`, `fix`, `review`).

## Procedure 1: start a leaf

1. Write the leaf's prompt text to a file in the scratch dir — e.g.
   `.moca-runs/<run-id>-<leaf-label>.prompt.txt`. (Prompts can be
   multi-paragraph; passing them as a file keeps the shell command
   short and makes the permission prompt readable.)
2. Run:

   ```bash
   moca start "<run-id>/<leaf-label>" .moca-runs/<run-id>-<leaf-label>.prompt.txt
   ```

3. On success the CLI prints `dispatched <session-id>` and the path to
   the record file it wrote. Report the session id to the operator and
   stop — do not block polling in this turn.

**Do not block polling inside this turn.** `moca start` returns as
soon as MOCA accepts the handle; collection is a separate turn.

If the CLI exits non-zero, surface its stderr to the operator. Common
cases:

- `cannot find MOCA.md` → you are not in the scratch dir. `cd` first.
- `MOCA likely has auth enabled, async unavailable` (HTTP 401/403) →
  this install doesn't support async dispatch. Surface and stop.
- `MOCA sandbox pool saturated` (HTTP 503) → surface and stop; do not
  auto-retry.
- `record already exists for <session-id>` → that leaf was already
  dispatched. Use `moca check <session-id>` instead.

## Procedure 2: check a leaf

```bash
moca check "<run-id>/<leaf-label>"
```

Outcomes:

- `status=done` with the leaf's `.text` answer printed on stdout →
  surface the answer to the operator, or embed it verbatim in a
  follow-up leaf's prompt.
- `status=failed` or `status=aborted` → surface the printed reason to
  the operator. Do not auto-redispatch.
- `status=pending` / `status=running` → tell the operator it's not
  ready.

The CLI writes the full response body to the record's `.result.json`
sibling once the leaf is terminal; use `Read` on that file if you need
more than the `.text` field (e.g. usage counters, structured verdict).

## Procedure 3: list pending runs

At the start of a turn, before accepting the operator's next request
at face value, run:

```bash
moca list
```

Each line is `<status><tab><sessionId>`. If there are records with
status `pending`, they are leaves from an earlier turn (or an earlier
Claude session). Options:

- If the operator's request references them ("check on that subagent"
  / "did it finish?"), run procedure 2 against them.
- If the request is unrelated, note them briefly ("you have N pending
  leaves from an earlier dispatch; want me to check on them?") and
  proceed.

Don't silently discard pending records — they represent cluster-side
work the operator paid for.

## Writing the leaf prompt

The leaf has no memory of the parent session and does not see other
leaves' output. Everything it needs must be in its prompt. In
particular:

- **State the workspace path explicitly.** Tell the leaf where its
  files live (the `workspaceRef` from `MOCA.md`, e.g.
  `/workspace/<run-id>/repo`).
- **Pass forward anything the leaf needs from earlier leaves.** If
  this leaf is building on another leaf's finding, embed that finding
  verbatim in the prompt (read it out of the earlier leaf's
  `.result.json`, or paste the stdout of `moca check`). There is no
  shared memory to pull it from.
- **Describe the deliverable.** Tell the leaf what the response text
  should contain (a diagnosis, a diff, a test outcome, etc.) and in
  what shape.

## Chaining leaves

MOCA has no "on complete, trigger X" primitive. If the operator asks
for a chain (A then B), you do the sequencing:

1. Write leaf 1's prompt to a file; `moca start` leaf 1. Record is
   written. Return to operator.
2. On a later turn (same session or resumed), `moca check` leaf 1. If
   done, capture the printed answer.
3. Write leaf 2's prompt to a file, embedding leaf 1's result
   verbatim.
4. `moca start` leaf 2. Record is written.
5. `moca check` leaf 2 when the operator wants the final result.

Do **not** parallelize leaves whose prompts depend on each other.
Do **not** fan out beyond what the operator asked for.

## What this skill does not do

- Does not provision workspaces. Setup owns that (seeds files into
  sandbox pods at `/workspace/<run-id>/repo` via `kubectl cp`).
- Does not block the turn on a leaf finishing. Dispatch returns
  immediately; collection happens on a later turn.
- Does not prescribe an orchestration shape. The operator's request
  drives how many leaves run and in what order.
