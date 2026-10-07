---
name: moca-dispatch
description: Dispatch a subagent to the MOCA serverless harness as an isolated leaf. Use this skill whenever the operator asks you to "use a subagent", "delegate", "run this remotely", "fan out", or anything else that would ordinarily go through the Task tool — Task is denied in this session, so this is the only subagent path. Dispatch detach-executes a synchronous MOCA turn: a start call forks a detached worker and returns immediately, and a separate check call returns the result when the leaf finishes. The operator can quit Claude between those two steps and resume later.
---

# MOCA dispatch

This session has **no access to the built-in `Task` tool** — it is denied
in `.claude/settings.json`. To run a subagent, dispatch a MOCA leaf via
the `moca` CLI described below. If you try `Task` the permission layer
will refuse; re-route through this skill instead of asking the operator
to lift the deny.

**Do not shell out to `curl` against MOCA directly.** The scratch dir
ships a `moca` CLI (on `PATH`) that wraps dispatch, result collection,
and record-keeping. Using the CLI keeps permission prompts short and
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

## No workload catalog on this install

This MOCA install exposes **no workload selector**. `moca start` sends
`kind:"prompt"` only — there is no `workload`, `workspaceRef`, or
`readOnly` field in the envelope. If the operator says "dispatch to
the read-only workload" or "use the read-write workload", that
phrasing is historical: just dispatch, and encode any
posture/behavior rules (e.g. "do not modify files") inside the leaf
prompt text itself. Do **not** stop to ask which workload to target —
there is only one path.

## Dispatch is a detached synchronous turn

This install uses MOCA's **synchronous** run path: `POST /runs` with no
`async` field blocks until the leaf finishes and returns the answer in
the same response. MOCA's async queue (`async:true` + polling) is
**not** used here.

A blocking HTTP call would normally pin your turn open and die with the
session. So `moca start` **detach-executes**: it forks a local
background process (via `nohup`, fully redirected and disowned) that
owns the blocking call and writes the response to disk when it
returns. `moca start` returns as soon as that process is forked.

This local process is called the **courier** in this skill. It is just
a detached `curl` on the operator's laptop holding one HTTP
connection — it does no agent work. All the actual work happens
cluster-side inside MOCA. (Don't confuse it with MOCA's `leaf-worker`
ScaledJob pods, which belong to MOCA's async queue and never appear on
this sync path.)

The courier is outside Claude Code's process group, so **the run
continues if the operator quits Claude.** Two independent things
protect the result:

1. The courier outlives the session and writes `.result.json`.
2. MOCA persists the leaf's result cluster-side *before* it writes the
   sync response, so if the courier is killed **after the leaf
   finished**, the result is recoverable via `/runs/status` for 24h.

`moca check` uses (1) and falls back to (2). You do not need to
manage any of this — just don't wrap `moca start` in anything that
waits on it.

Caveat on (2): it only covers a leaf that ran to completion. If
Knative's request timeout cuts a leaf off mid-run, MOCA persisted
nothing and the work is genuinely lost.

## The CLI

The scratch dir contains `MOCA.md` (base URL, host header, run-id,
workspace path) and a `moca` binary. Run it from the scratch dir —
it reads `MOCA.md` from the current working directory.

Three subcommands:

- `moca start <session-id> <prompt-file>` — dispatch a leaf. Writes a
  record file in `.moca-runs/` and forks the detached worker. Returns
  immediately.
- `moca check <session-id>` — collect a leaf. If done, prints the
  leaf's answer text to stdout. If the worker is still holding the
  call, says so. If the worker was lost, recovers the result from
  MOCA.
- `moca list` — show every run record, its status, and whether its
  detached worker is still alive.

There is a fourth subcommand, `moca __exec`, which is the detached
worker body. **Never call it yourself** — `moca start` calls it.

Session ids are `<run-id>.<leaf-label>`, e.g. `review-123.diagnose`.
Reuse `<run-id>` from `MOCA.md` across leaves in the same operator
request so they share a run identity. `<leaf-label>` is a short
identifier within the run (e.g. `diagnose`, `fix`, `review`).

**MOCA validates session ids server-side:** alphanumerics plus `-`,
`_`, `.` only, and the first and last character must be alphanumeric.
Use `.` as the run/leaf separator — a `/` is rejected at the API
boundary before the leaf runs. The CLI checks this locally too, so an
illegal id fails at `start` without consuming the leaf label.

## Procedure 1: start a leaf

1. Write the leaf's prompt text to a file in the scratch dir — e.g.
   `.moca-runs/<run-id>-<leaf-label>.prompt.txt`. (Prompts can be
   multi-paragraph; passing them as a file keeps the shell command
   short and makes the permission prompt readable.)
2. Run:

   ```bash
   moca start "<run-id>.<leaf-label>" .moca-runs/<run-id>-<leaf-label>.prompt.txt
   ```

3. On success the CLI prints
   `dispatched <session-id> (sync turn, detached pid N)` and the path
   to the record file it wrote. Report the session id to the operator
   and stop.

**Do not block or poll inside this turn.** `moca start` returns as
soon as the detached worker is forked; collection is a separate turn.
In particular, do not sleep-and-retry `moca check` in a loop to wait
for the leaf — hand control back to the operator instead.

Because the HTTP call is now owned by the detached worker, dispatch
errors that used to surface at `start` time (saturation, auth) now
surface at `check` time instead. `moca start` only fails for local
reasons:

- `cannot find MOCA.md` → you are not in the scratch dir. `cd` first.
- `prompt file not found` → write the prompt file first.
- `invalid session id` → you used a character MOCA rejects (most
  likely `/`). Rebuild the id as `<run-id>.<leaf-label>` and retry
  under the **same** leaf label — nothing was dispatched.
- `record already exists for <session-id>` → that leaf was already
  dispatched. Use `moca check <session-id>` instead.

The worker's own stderr goes to `.moca-runs/<run>-<leaf>.log`. Read
that file if a leaf fails in a way `check` can't explain.

## Procedure 2: check a leaf

```bash
moca check "<run-id>.<leaf-label>"
```

Outcomes:

- `status=done` with the leaf's answer printed on stdout → surface the
  answer to the operator, or embed it verbatim in a follow-up leaf's
  prompt. (`status=done (recovered via /runs/status …)` means the same
  thing; the worker was lost but MOCA still had the result.)
- `status=running` → the detached worker is still holding the sync
  call. Tell the operator it's not ready and stop. Do not loop.
- `status=failed` → surface the printed reason (and `message` if
  shown). Do not auto-redispatch.
- `status=saturated` → MOCA's sandbox pool was full and **nothing
  ran**. Retryable. Surface it and stop; re-dispatch only if the
  operator asks, under a new leaf label.
- `status=paused` → the leaf hit an approval gate. Surface the gate
  summary; this demo has no resume path.
- `status=gateway-error` → the HTTP request died in the gateway
  (usually Knative's 300s `activator request timeout`) and the
  response wasn't even JSON. The CLI automatically tries
  `/runs/status` next and prints that outcome too. Report this as an
  **infrastructure timeout, not a finding about the code under test** —
  the leaf may have done no work at all.
- `status=lost` → MOCA holds no result for that sessionId. Surface it;
  re-dispatch only if the operator asks, and use a **new leaf label**
  (the old record still occupies the old one).

When a leaf fails for an infrastructure reason — invalid session id,
gateway timeout, saturation — say so explicitly and do **not** present
it as a diagnosis. The operator asked about their code; a dispatch
that never ran tells them nothing about it.

Note that **HTTP 200 from MOCA does not mean the leaf succeeded** —
failed, aborted, and paused leaves all come back 200 with the real
outcome in `.status`. The CLI already branches on that for you; don't
re-interpret the raw result file as success just because it exists.

The CLI writes the full response body to the record's `.result.json`
sibling once the leaf is terminal; use `Read` on that file if you need
more than the answer text (e.g. `usage` counters). Note `usage` is
only present when the result came back through the sync response, not
when it was recovered via `/runs/status`.

## Procedure 3: list pending runs

At the start of a turn, before accepting the operator's next request
at face value, run:

```bash
moca list
```

Each line is `<status><tab><sessionId>`, and a `pending` record is
annotated with whether its detached worker is still alive
(`(worker alive)`) or not (`(worker gone — check to recover)`). If
there are records with status `pending`, they are leaves from an
earlier turn (or an earlier Claude session). Options:

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
- Does not block the turn on a leaf finishing. The sync call is held by
  a detached worker, not by your turn; collection happens later.
- Does not prescribe an orchestration shape. The operator's request
  drives how many leaves run and in what order.
