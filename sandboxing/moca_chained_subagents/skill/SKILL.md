---
name: moca-dispatch
description: Dispatch a subagent to the MOCA harness as an isolated leaf. Use this skill whenever the operator asks you to "use a subagent", "delegate", "run this remotely", "fan out", or anything else that would ordinarily go through the Task tool — Task is denied in this session, so this is the only subagent path. Dispatch starts a detachable MOCA turn: a start call returns immediately and a separate check call collects the result by reattaching. The operator can quit Claude, or reboot, between those two steps and resume later.
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
readable (`moca start …` instead of a many-flag `curl` line), handles
token minting, and guarantees run records on disk are shaped the way a
resumed session expects. If the operator asks you to use `curl`
directly, surface that the CLI exists and prefer it.

This skill is **mechanism only**. It tells you how to run and collect
one leaf. It does **not** tell you how many leaves to run, in what
order, or with what prompts — those decisions come from the operator's
request. If the operator asks for one leaf, run one. If they ask for a
chain, start them in sequence and feed outputs forward as they
describe.

## Dispatch is a detachable turn

`moca start` POSTs to the harness's `/v1/turn` with `detachable: true`,
reads the response stream only long enough to learn the turn's id, and
then **walks away**. MOCA does not abort a detachable turn when its
client disconnects — it writes every frame of the turn to a server-side
log instead. The leaf keeps running cluster-side with nothing held open
on the operator's machine.

`moca check` collects by **reattaching**: it re-opens the turn's stream,
replays it from the beginning, and follows it if it is still running.

This means durability is entirely the server's job. There is no local
background process to keep alive, and the result survives the operator
quitting Claude Code, closing the laptop, or rebooting. A finished
turn stays collectable for **24 hours**.

You do not need to manage any of this — just don't wrap `moca start` in
anything that waits on it.

## One session, one workspace, one turn at a time

Every leaf in this chain is a turn in the **same** MOCA session (its id
is in `MOCA.md`). That session has one sandbox workspace, so every leaf
sees the same files — which is what lets a fix leaf work on the files a
diagnose leaf examined. Three consequences that matter to you:

- **Leaves must run sequentially.** A session runs one turn at a time.
  Dispatching a second leaf while one is still running is refused with
  `turn_in_progress` (HTTP 409) and nothing starts. Collect the leaf in
  flight first.
- **Leaves are not isolated from each other.** The isolation boundary
  is this chain versus everything else, not leaf versus leaf. Don't
  tell the operator a leaf is sandboxed *from its siblings*.
- **Leaf labels are local names, not session ids.** You pass `moca` a
  short label (`diagnose`, `fix`) that names records in `.moca-runs/`.
  MOCA generates the session id itself; you never construct one.

## The CLI

The scratch dir contains `MOCA.md` (the two URLs, the session id, the
workspace path) and a `moca` binary. Run it from the scratch dir — it
reads `MOCA.md` from the current working directory.

Four subcommands:

- `moca start <leaf-label> <prompt-file>` — dispatch a leaf. Writes a
  record in `.moca-runs/` and returns as soon as the turn is running.
- `moca check <leaf-label>` — collect a leaf by reattaching. If done,
  prints the leaf's answer text to stdout. If still running, says so.
- `moca list` — show every run record and its status.
- `moca cancel <leaf-label>` — cancel a leaf still in flight. Only use
  this when the operator asks.

Labels must be alphanumerics plus `-`, `_`, `.`. The CLI validates
locally, so a bad label fails at `start` without consuming anything.

## Procedure 1: start a leaf

1. Write the leaf's prompt text to a file in the scratch dir — e.g.
   `.moca-runs/<leaf-label>.prompt.txt`. (Prompts can be
   multi-paragraph; passing them as a file keeps the shell command
   short and makes the permission prompt readable.)
2. Run:

   ```bash
   moca start "<leaf-label>" .moca-runs/<leaf-label>.prompt.txt
   ```

3. On success the CLI prints `dispatched '<label>' as a detachable
   turn` along with the session id, the turn id, and the record path.
   Report to the operator that the leaf is running and stop.

**Do not block or poll inside this turn.** `moca start` returns as soon
as the turn is running cluster-side; collection is a separate turn. In
particular, do not sleep-and-retry `moca check` in a loop to wait for
the leaf — hand control back to the operator instead.

`moca start` failure modes:

- `cannot find MOCA.md` → you are not in the scratch dir. `cd` first.
- `prompt file not found` → write the prompt file first.
- `invalid leaf label` → use alphanumerics plus `-`, `_`, `.`. Nothing
  was dispatched; retry with a legal label.
- `record already exists for '<label>'` → that leaf was already
  dispatched. Use `moca check <label>` instead.
- `status=refused (HTTP 409 turn_in_progress)` → another leaf of this
  chain is still running. Run `moca list`, collect the running leaf
  with `moca check`, then dispatch this one again. **Nothing started**,
  so this is not a failure of the leaf you were asked to run.
- `status=saturated (HTTP 503)` → no capacity right now and nothing
  ran. Retryable; surface it and stop.

## Procedure 2: check a leaf

```bash
moca check "<leaf-label>"
```

Outcomes:

- `status=done` with the leaf's answer printed on stdout → surface the
  answer to the operator, or embed it verbatim in a follow-up leaf's
  prompt.
- `status=running` → the leaf is still working. Tell the operator it's
  not ready and stop. **Do not loop.** Reattaching does not disturb the
  leaf, so checking again later is free.
- `status=failed` → surface the printed `stopReason` / `message`. If an
  `abortReason` is shown, the CLI explains it in plain language;
  reproduce that explanation rather than inventing one. Do not
  auto-redispatch.
- `status=lost` → MOCA holds no turn log for this session: the turn
  never started, or its log aged out after 24h. The answer is not
  recoverable. Surface it; re-dispatch only if the operator asks, under
  a **new label**.
- `status=saturated` / `status=refused` → nothing ran, so there is
  nothing to collect.

### Infrastructure outcomes are not findings

Some failures say nothing at all about the operator's code:

- `abortReason: unwatched` — the turn ran 30 minutes with nobody
  attached, so MOCA aborted it. Running `moca check` counts as
  attaching and resets that clock, so the fix is to check sooner.
- `abortReason: restarting` — MOCA's supervisor restarted mid-turn.
- `abortReason: lease_lost` / `owner_lost` — MOCA lost ownership of
  the turn.
- `status=lost`, `saturated`, `refused` — nothing ran, or no log
  survives.

When a leaf ends this way, **say so explicitly and do not present it as
a diagnosis.** The operator asked about their code; a dispatch that
never completed tells them nothing about it.

Also note a `note: MOCA trimmed this turn's log` line: the transcript is
partial, so the answer may be missing its beginning. Say so rather than
presenting a fragment as the whole finding.

The CLI writes the full SSE transcript next to the record (`.sse`) and
the extracted answer (`.answer.txt`). Use `Read` on the transcript if
you need the leaf's tool calls rather than just its prose.

## Procedure 3: list runs

At the start of a turn, before accepting the operator's next request
at face value, run:

```bash
moca list
```

Each line is `<status><tab><leaf-label>` plus a short note. A `running`
record is a leaf from an earlier turn (or an earlier Claude session)
that is still working or waiting to be collected. Options:

- If the operator's request references it ("check on that subagent" /
  "did it finish?"), run procedure 2 against it.
- If the request is unrelated, note it briefly ("you have N leaves from
  an earlier dispatch; want me to check on them?") and proceed.
- If you are about to dispatch a new leaf, check first that no other
  leaf is `running` — otherwise the dispatch is refused with 409.

Don't silently discard records — they represent cluster-side work the
operator paid for.

## Writing the leaf prompt

The leaf is a turn in a shared session, but you should still write its
prompt as if it were self-contained: state the task, the deliverable,
and any finding it builds on. In particular:

- **State the workspace path explicitly.** Tell the leaf where its
  files live (the `Workspace` path from `MOCA.md`, which is
  `/workspace/<session-id>`). It is also the leaf's working directory.
- **Pass forward anything the leaf needs from earlier leaves.** Embed
  the earlier finding verbatim in the prompt (paste the stdout of
  `moca check`, or read the `.answer.txt`). Although leaves share a
  session, do not rely on the leaf inferring context — give it the
  finding in writing.
- **Describe the deliverable.** Tell the leaf what the response text
  should contain (a diagnosis, a diff, a test outcome) and in what
  shape.
- **Encode posture rules in the prompt.** There is no `readOnly` flag
  or workload selector on this install. If a leaf must not modify
  files, say so in its prompt text.

## Chaining leaves

MOCA has no "on complete, trigger X" primitive. If the operator asks
for a chain (A then B), you do the sequencing:

1. Write leaf 1's prompt to a file; `moca start` leaf 1. Return to the
   operator.
2. On a later turn (same session or resumed), `moca check` leaf 1. If
   done, capture the printed answer.
3. Write leaf 2's prompt to a file, embedding leaf 1's result verbatim.
4. `moca start` leaf 2 — only after leaf 1 is terminal, or the dispatch
   is refused with 409.
5. `moca check` leaf 2 when the operator wants the final result.

Do **not** parallelize leaves on this install — the shared session
permits one turn at a time. Do **not** fan out beyond what the operator
asked for.

## What this skill does not do

- Does not provision workspaces. Setup owns that: it creates the
  session and seeds the fixture into `/workspace/<session-id>` with a
  bootstrap turn.
- Does not block the turn on a leaf finishing. The turn runs
  cluster-side; collection happens later, by reattaching.
- Does not prescribe an orchestration shape. The operator's request
  drives how many leaves run and in what order.
