---
name: moca-chained-demo
description: Dispatch a subagent to the MOCA harness as an isolated leaf against this demo's pre-created workload. Use this skill whenever the operator asks you to "use a subagent", "delegate", "run this remotely", "fan out", or anything else that would ordinarily go through the Task tool — Task is denied in this session, so this is the only subagent path. This is a demo overlay on top of the upstream `moca-delegate-task` skill: the upstream SKILL.md is staged under `references/moca-delegate-task.md` as a *mechanism reference* only — do not invoke it as a separate skill, and do not follow its numbered steps blindly; the preconditions below override them. The workload is pre-created by setup, so skip the upstream flow's steps 1 (`contextctl ctx pack`), 2 (`mocactl workloads create`), and 6 (`mocactl workloads delete`) — setup owns 1 and 2, teardown owns 6.
---

# MOCA chained-subagents demo (overlay)

This skill wraps the upstream `moca-delegate-task` mechanism with the
invariants this demo depends on. The upstream SKILL.md is in
`references/moca-delegate-task.md` as a reference doc; it describes the
general command flags and failure modes, but the procedure below is what
you follow in this scratch dir.

## Preconditions — read first, every turn

`MOCA.md` in this directory is the source of this run's facts: the
**demo tag** and the pre-created **workload id**. Pull them into shell
variables once per turn:

```bash
TAG="$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
WORKLOAD_ID="$(sed -nE 's/^Workload id:[[:space:]]+//p' MOCA.md)"
```

The port-forward URLs (`SH_CONTROL_PLANE_URL`, `SH_HARNESS_URL`) are
injected into your environment by the staged `.claude/settings.json`;
every `mocactl` command inherits them.

**Hard overrides on the upstream flow** (upstream's own step numbers,
from `references/moca-delegate-task.md`):

- **Skip upstream step 1** (`contextctl ctx pack`): setup packed the
  fixture already.
- **Skip upstream step 2** (`mocactl workloads create`): setup created
  the workload and wrote its id to `MOCA.md`. Do not create another
  one. If `MOCA.md` is missing or empty, stop and ask the operator to
  re-run `setup.sh` — do not try to self-heal by packing.
- **Skip upstream step 6** (`mocactl workloads delete`): `teardown.sh`
  owns the lifecycle. Leave the workload alone.
- **Override upstream step 4** ("watch until none is running"): this
  demo is dispatch-and-stop. See below.

## `Task` is denied — this is the only subagent path

The permission layer denies `Task` in this session. If you try it,
you will get a refusal; re-route through this skill rather than asking
the operator to lift the deny. **Do not shell out to `curl` against
MOCA's HTTP API directly** — `mocactl` is the official client and owns
all auth. Its tokens live in `~/.config/mocactl`, which this session is
denied from reading.

## Dispatch is a durable server-side run

`mocactl spawn` creates a **new MOCA session** for the leaf, records
it in a machine-global ledger, and forks a **detached local worker**
that holds a synchronous `POST /v1/runs`. The server runs the leaf to
completion and **persists the result before responding** — and
`/v1/runs` has **no client-disconnect abort**. The leaf keeps running
with nothing held open on the operator's machine: quit Claude Code,
close the laptop, reboot — the result is still there.

A stored result stays collectable for **24 hours**. That is the only
deadline.

One wrinkle: the detached worker's own HTTP fetch dies at the
five-minute mark (Node/undici's default `headersTimeout`), so
`subagents` may show a long-running leaf as `failed: fetch failed`
while the run continues server-side. **Trust `get`, not the ledger.**

## Procedure 1: start a leaf

1. Author the leaf's prompt and write it to
   `leaves/<label>.prompt.txt`. Start from a template below. The
   invariant clauses are not optional: cwd-is-the-project-root and
   "do not cd elsewhere"; read-only vs apply instructions; and "end
   your turn with the full report as your final message" — the
   collected result is exactly that text. Pass anything the leaf
   needs from an earlier leaf **inline, verbatim**.
2. Dispatch. For a **read-only** leaf (diagnose, inspection):

   ```bash
   mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt \
     --workload "$WORKLOAD_ID" --tag "$TAG" --json
   ```

   For a **writable** leaf (fix, build, anything that edits files),
   add `--writable`:

   ```bash
   mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt \
     --workload "$WORKLOAD_ID" --writable --tag "$TAG" --json
   ```

   `--json` prints `{"type":"session","sessionId":"…","pid":…}` on
   stdout; take the `sessionId` from that line.
3. Write the note `leaves/<label>.json`:
   `{label, sessionId, kind, writable, promptFile, dispatchedAt}`.
   Include `"writable": true` when you passed `--writable`.
4. **Stop.** Report the label and session id to the operator. Do not
   wait, do not poll, do not sleep-and-check. Collection is a later
   turn's job. This is the override of upstream step 4.

Labels are local file names; keep them short (`diagnose`, `fix`) and
use a **fresh label** (`fix2`) when re-dispatching, so earlier notes
and prompts are never overwritten.

## Procedure 2: check a leaf

```bash
mocactl get "<sessionId>" --out leaves --json
```

Branch on the printed `status`, **not** on the exit code — exit 1
covers both "still running" and "failed":

- `queued` → still running. Tell the operator it's not ready and
  stop. **One check per user turn.** The leaf is durable server-side;
  checking again on a later turn is free.
- `responded` → done. The result is in `leaves/<sessionId>.text`.
  Read it, surface it to the operator (or inline it verbatim in the
  next leaf's prompt), and add a `collectedAt` timestamp to the note
  file.
- `failed` / `paused` → surface the reason. Do not auto-redispatch.

If `mocactl subagents` shows the leaf as `failed: fetch failed` but
`get` still says `queued`, the leaf has merely outrun the worker's
five-minute HTTP timeout — it is still running server-side. Keep
checking on later turns; `get` is the source of truth.

A result **is** the leaf's final message only. There is no tool-call
transcript, and in a writable run the per-run copy is already gone by
the time you collect — so if the operator wants a diff or the test
output, the leaf's prompt must have asked for it as part of the final
message.

## Procedure 3: list leaves

```bash
mocactl subagents --tag "$TAG"
```

Honest states: `running`, `done`, `failed`, `paused`, `unknown`. Use
this when resuming — a `running` leaf from an earlier turn is still
working or waiting to be collected. Cross-reference `leaves/*.json`
notes to map session ids back to labels.

`unknown` means the detached worker died before the server recorded
anything (port-forward down at dispatch, or a supervisor restart
mid-run). The result will never land; re-dispatch under a fresh label
if the operator wants that work done.

## Infrastructure outcomes are not findings

Some terminal states say nothing at all about the operator's code:

- `failed` with a fetch error right at the five-minute mark → the
  worker's own HTTP timeout; the run continues server-side.
- `unknown` → the worker died before the server recorded anything.
- `paused` → an infrastructure pause, not the leaf's choice.

When a leaf ends this way, **say so explicitly and do not present it
as a diagnosis.** The operator asked about their code; a dispatch
that never completed tells them nothing about it.

## Chaining leaves

MOCA has no "on complete, trigger X" primitive. If the operator asks
for a chain (A then B):

1. Write leaf 1's prompt; spawn, note (procedure 1). Return to the
   operator.
2. On a later turn, check leaf 1 with procedure 2. If `responded`,
   read `leaves/<sessionId>.text`.
3. Write leaf 2's prompt with leaf 1's result **inlined verbatim** —
   never a file path, never a sessionId; leaf 2 is an independent
   session with its own view and cannot see leaf 1's files.
4. Spawn, note; collect on a later turn.

### Posture rules for this demo's fixture

The diagnose leaf is read-only (dispatch without `--writable`); the
fix leaf is writable (dispatch with `--writable`) and edits `src/`
only, never `vendor/`. The fix leaf's prompt must ask for the diff
and the test output as part of its final message, because its
writable copy is discarded when the run ends. Keep the demo a
sequential chain unless the operator explicitly asks for fan-out.

## There is no cancel

No server-side cancel exists for `/v1/runs`, and no headless cancel
command. A dispatched leaf runs to completion. If a leaf went wrong,
let it finish and ignore its result, or re-dispatch a fresh leaf
under a fresh label. Do not tell the operator you can stop a running
leaf — you cannot.

## Leaf prompt templates

Adapt wording as needed, but keep the invariant clauses:
project-is-at-your-cwd, posture rules, final-message-is-the-deliverable
(and, for writable leaves, the diff and test output must be in that
message).

### Diagnose (read-only)

```text
You are a subagent leaf running inside a MOCA sandbox. Your current working
directory is this run's view of a small Python project — do not cd elsewhere.
The files are mounted read-only.

The project's tests currently fail. Run the test suite
(`python3 -m unittest discover -s tests`), read the relevant code and the
docs under docs/upstream-refs/, and report:
1. The exact failing assertion and the test command that exercises it.
2. The root cause, with file paths and line references.
3. The minimal change that would fix it, described precisely — another agent
   will apply it on its own writable copy of this project.

The project is stdlib-only; do NOT install or download anything (no `pip`,
no package manager). Diagnose from the source and docs alone.

Do NOT edit any files: this is a diagnosis-only task, and the mount is
read-only anyway. End your turn with the full diagnosis as your final
message.
```

### Fix (apply, then verify)

```text
You are a subagent leaf running inside a MOCA sandbox. Your current working
directory is this run's own writable copy of a small Python project — do not
cd elsewhere. The copy is discarded when this run ends, so anything you want
to return must be in your final message.

A prior agent diagnosed a test failure in a fresh copy of this project:

------------------------------------------------------------------------
<PASTE leaves/<diagnose sessionId>.text VERBATIM HERE>
------------------------------------------------------------------------

Apply the fix — edit src/, never vendor/ — then run
`python3 -m unittest discover -s tests` to confirm the suite passes. The
project is stdlib-only; do NOT install or download anything (no `pip`, no
package manager). Report:
1. The exact change you made (file, line, before/after).
2. The full test output after your change (verbatim, including the
   `Ran N tests` and `OK` / `FAILED` lines).

End your turn with the full report as your final message. There will be no
other record of your edits — the writable copy will be gone.
```

## Pointer to the mechanism doc

See `references/moca-delegate-task.md` for the upstream description of
the pack / create / spawn / subagents / get / delete flow, bundle
limits, and the detached-worker mechanism. That doc is a **reference**;
this file is the **procedure**. Do not treat the upstream numbered
steps as orders to execute — the preconditions at the top override
them.
