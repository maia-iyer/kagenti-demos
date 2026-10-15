---
name: moca-dispatch
description: Dispatch a subagent to the MOCA harness as an isolated leaf, via the official mocactl client. Use this skill whenever the operator asks you to "use a subagent", "delegate", "run this remotely", "fan out", or anything else that would ordinarily go through the Task tool — Task is denied in this session, so this is the only subagent path. Dispatch (mocactl spawn) creates a fresh session per leaf and returns immediately; the leaf runs to completion server-side, and a separate check (mocactl get) collects the result, which is stored for 24h. The operator can quit Claude, or reboot, between those two steps and resume later.
---

# MOCA dispatch

This session has **no access to the built-in `Task` tool** — it is denied
in `.claude/settings.json`. To run a subagent, dispatch a MOCA leaf via
`mocactl` as described below. If you try `Task` the permission layer
will refuse; re-route through this skill instead of asking the operator
to lift the deny.

**Do not shell out to `curl` against MOCA's HTTP API directly.**
`mocactl` is the official client and owns all auth — its tokens live
in `~/.config/mocactl`, which this session is denied from reading.
Using mocactl keeps permission prompts short and readable
(`mocactl spawn …` instead of a many-flag `curl` line) and keeps the
leaf bookkeeping shaped the way a resumed session expects. If the
operator asks you to use `curl` directly, surface that mocactl is the
supported path and prefer it.

This skill is **mechanism only**. It tells you how to dispatch and
collect one leaf against this demo's shared workload. It does **not**
tell you how many leaves to run, in what order, or with what prompts —
those decisions come from the operator's request. If the operator asks
for one leaf, run one. If they ask for a chain, start them in sequence
and feed outputs forward as they describe.

## Dispatch is a durable server-side run

`mocactl spawn` creates a **new MOCA session** for the leaf, records
it in a machine-global ledger, and forks a **detached local worker**
that holds a synchronous `POST /v1/runs`. The server runs the leaf to
completion and **persists the result before responding** — and, unlike
a normal turn, `/v1/runs` has **no client-disconnect abort**. The leaf
keeps running with nothing held open on the operator's machine: quit
Claude Code, close the laptop, reboot — the result is still there.

A stored result stays collectable for **24 hours**. That is the only
deadline.

You do not need to manage any of this — just don't wrap `spawn` in
anything that waits on it. One wrinkle inherited from the worker: its
own HTTP request dies at the five-minute mark, so `subagents` may show
a long-running leaf as `failed: fetch failed` while the run continues
server-side. Trust `get`, not the ledger (see the mechanism appendix).

## One shared workload, one session per leaf

Setup packed `./example_repo` into a workspace `.context` bundle and
created one **workload** from it. Both leaves of this demo share that
workload — its id lives in `MOCA.md`. Each dispatch creates its own
session; the workload is what the session mounts, not something the
session owns.

Three consequences that matter to you:

- **Fixture seeding is done.** Context Service serves the workload's
  frozen revision into whichever sandbox the leaf lands on, mounted at
  the leaf's cwd. You do not run `kubectl cp`, nor any seed loop; the
  leaf's `pwd` is already the project.
- **Read-only by default.** Diagnose-shaped leaves pass just
  `--workload <id>`; the mount is a read-only view of the revision.
- **Opt-in writable.** A fix-shaped leaf passes `--workload <id>
  --writable` and gets its **own per-run copy** of the workload's
  files. Edits land in that copy; the copy is **discarded when the
  run ends.** Nothing persists across runs — durable, shared,
  mutable storage is the phase-2 workloads design
  ([rossoctl/moca#476](https://github.com/rossoctl/moca/issues/476)),
  not shipped. Whatever the fix leaf wants to return — a diff, test
  output — must be inlined in its final message.

Session ids are server-generated (`spawn` prints them). You keep
short local labels (`diagnose`, `fix`) that name the files in
`leaves/`.

## Environment

Read `MOCA.md` in the scratch dir first. It holds this run's facts:
the **demo tag**, the **workload id**, the **context bundle** path,
and the **leaves dir** (`./leaves`). Pull them into shell variables
once per turn:

```bash
TAG="$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
WORKLOAD_ID="$(sed -nE 's/^Workload id:[[:space:]]+//p' MOCA.md)"
DIGEST_PUBLIC="$(sed -nE 's/^Config digest public:[[:space:]]+//p' MOCA.md)"
DIGEST_FULL="$(sed -nE 's/^Config digest full:[[:space:]]+//p' MOCA.md)"
```

The two digests name promoted **config bundles** (skills + commands —
not CLAUDE.md). The diagnose leaf runs with `$DIGEST_PUBLIC`, which
carries a public-posture research skill. The fix leaf runs with
`$DIGEST_FULL`, which carries a skill with the organization's testing
conventions. Each child's identity is the triple **(configRef digest,
workload revision, sessionId)** — three sha256-pinned handles.

The port-forward URLs (`SH_CONTROL_PLANE_URL`, `SH_HARNESS_URL`) are
already injected into your environment by the staged
`.claude/settings.json` — every `mocactl` command you run inherits
them. Run everything from the scratch dir.

Bookkeeping, all in `leaves/`:

- `leaves/<label>.prompt.txt` — the prompt you sent.
- `leaves/<label>.json` — a note you write right after spawn:
  `{label, sessionId, kind, writable, promptFile, dispatchedAt}`.
  Status is never stored — it is always derived fresh from
  `subagents` / `get` at read time.
- `leaves/<sessionId>.text` — the collected result, written by
  `mocactl get --out leaves`.

Labels are local file names; keep them short (`diagnose`, `fix`) and
use a **fresh label** (`fix2`) when re-dispatching, so earlier notes
and prompts are never overwritten.

## Procedure 1: start a leaf

1. Author the leaf's prompt and write it to
   `leaves/<label>.prompt.txt`. Start from a template (below). The
   invariant clauses are not optional: cwd-is-the-project-root and
   "do not cd elsewhere"; read-only vs apply instructions; and "end
   your turn with the full report as your final message" — the
   collected result is exactly that text. Pass anything the leaf
   needs from earlier leaves **inline, verbatim**.
2. Dispatch. For the **diagnose** leaf (read-only, public posture):

   ```bash
   mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt \
     --config "$DIGEST_PUBLIC" \
     --workload "$WORKLOAD_ID" --tag "$TAG" --json
   ```

   For the **fix** leaf (writable, full-access posture):

   ```bash
   mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt \
     --config "$DIGEST_FULL" \
     --workload "$WORKLOAD_ID" --writable --tag "$TAG" --json
   ```

   The two leaves pair different skill bundles with the **same**
   workload: the project files are shared, but the leaf's instructions
   and posture are not. Quote-substitution keeps the permission
   prompt legible. `--json` prints one line on stdout —
   `{"type":"session","sessionId":"…","pid":…}` — with diagnostics on
   stderr; take the `sessionId` from the stdout line.
3. Write the note `leaves/<label>.json` (shape above; include
   `"writable": true` when you passed `--writable`, and the `config`
   digest you dispatched with).
4. **Stop.** Report the label and session id to the operator. Do not
   wait, do not poll, do not sleep-and-check — collection is a later
   turn's job.

Failure modes at dispatch:

- `spawn needs a prompt` → the prompt argument came out empty; check
  the prompt file path.
- `--writable needs --workload ID` → `--writable` only applies to
  workload runs; make sure `$WORKLOAD_ID` is set from `MOCA.md`.
- `a bundle digest is sha256:<64 lowercase hex>` → `$DIGEST_PUBLIC`
  or `$DIGEST_FULL` is empty; re-read `MOCA.md`.
- An immediate connection error → the port-forwards are down (or
  mocactl logged out). `mocactl doctor` says which. Nothing ran; fix
  and retry.
- A workload-not-ready / workload-not-found error → setup did not
  finish, or the workload was deleted. Surface it; don't retry blind.
- Prompt over 64 KiB → `spawn` refuses it. The diagnosis is small;
  inline freely, but trim if you hit the cap.

## Procedure 2: check a leaf

```bash
mocactl get "<sessionId>" --out leaves --json
```

Branch on the printed `status`, **not** on the exit code — exit 1
covers both "still running" and "failed":

- `queued` → still running. Tell the operator it's not ready and
  stop. **Do not loop.** One check per user turn — the leaf is durable
  server-side, and checking again on a later turn is free and
  disturbs nothing.
- `responded` (prompt kind; `solved` is the solve-kind twin) → done.
  The result is in `leaves/<sessionId>.text`. Read it, surface it to
  the operator (or inline it verbatim in the next leaf's prompt), and
  add a `collectedAt` timestamp to the note file.
- `failed` / `paused` → surface the reason (stderr / `.detail`). Do
  not auto-redispatch.

If `mocactl subagents` shows the leaf as `failed: fetch failed` but
`get` still says `queued`, the leaf has merely outrun the worker's
five-minute HTTP timeout — it is still running server-side. Keep
checking on later turns; `get` is the source of truth.

Note what a result **is**: the leaf's final message only. There is no
tool-call transcript, and in a writable run the per-run copy is
already gone by the time you collect — so if the operator wants a
diff or the test output, the leaf's prompt must have asked for it as
part of the final message.

## Procedure 3: list leaves

```bash
mocactl subagents --tag "$TAG"
```

Honest states: `running`, `done` (either success kind), `failed`,
`paused`, `unknown`. Use this when resuming — a `running` leaf from an
earlier turn (or an earlier Claude session) is still working or
waiting to be collected. Cross-reference the `leaves/*.json` notes to
map session ids back to labels. Options:

- If the operator's request references a leaf ("check on that
  subagent" / "did it finish?"), run procedure 2 against it.
- If the request is unrelated, note briefly what is pending ("you
  have N leaves from an earlier dispatch; want me to check on
  them?") and proceed.

Don't silently discard notes — they represent cluster-side work the
operator paid for.

`unknown` means the detached worker died before the server recorded
anything (port-forward down at dispatch, or a supervisor restart
mid-run). The result will never land; re-dispatch under a fresh label
if the operator wants that work done.

## Chaining leaves

MOCA has no "on complete, trigger X" primitive. If the operator asks
for a chain (A then B), you do the sequencing:

1. Write leaf 1's prompt; spawn, note (procedure 1). Return to the
   operator.
2. On a later turn (same session or resumed), check leaf 1 with
   procedure 2. If `responded`, Read `leaves/<sessionId>.text`.
3. Write leaf 2's prompt with leaf 1's result **inlined verbatim** —
   never a file path, never a sessionId; leaf 2 is an independent
   session with its own view and cannot see leaf 1's files.
4. Spawn, note; collect on a later turn.

Posture rules for this demo's fixture: the diagnose leaf dispatches
with `--config "$DIGEST_PUBLIC"` and no `--writable` (read-only, public
posture); the fix leaf dispatches with `--config "$DIGEST_FULL"
--writable` (writable, full-access posture) and edits `src/` only,
never `vendor/`. The fix leaf's prompt must ask for the diff and the
test output as part of its final message, because its writable copy
is discarded when the run ends. Keep the demo a sequential chain
unless the operator explicitly asks for fan-out.

## The chain receipt

When the operator asks for "the receipt" or "proof of the chain" (or
anything about which bundle / workload / session a leaf ran against),
read `MOCA.md` and `leaves/*.json`, then surface the triples:

```text
Parent session: <current Claude session>
Child A (diagnose):
  config:   <DIGEST_PUBLIC>
  workload: <WORKLOAD_ID>  (read-only)
  session:  <sidA>
Child B (fix):
  config:   <DIGEST_FULL>
  workload: <WORKLOAD_ID>  (writable per-run copy)
  session:  <sidB>

# Reproduce either child's full report:
mocactl get <sidA> --out leaves
mocactl get <sidB> --out leaves
```

The point is that each child's identity — what instructions it ran
with, what files it saw, and the session that recorded it — is three
sha256-pinned handles, all server-held. The operator can walk back
from any triple on their own (or hand them to someone else) and get
the exact text back as long as the 24h result TTL hasn't lapsed.

## There is no cancel

No server-side cancel exists for `/v1/runs`, and no headless cancel
command. A dispatched leaf runs to completion. If a leaf went wrong,
let it finish and ignore its result, or re-dispatch a fresh leaf under
a fresh label. Do not tell the operator you can stop a running leaf —
you cannot.

## Infrastructure outcomes are not findings

Some terminal states say nothing at all about the operator's code:

- `failed` with a fetch error right at the five-minute mark → the
  worker's own HTTP timeout; the run continues server-side. Not a
  finding, and not even a real failure.
- `unknown` → the worker died before the server recorded anything
  (port-forward down at dispatch; supervisor restart mid-run).
- `paused` → an infrastructure pause, not the leaf's choice.

When a leaf ends this way, **say so explicitly and do not present it
as a diagnosis.** The operator asked about their code; a dispatch
that never completed tells them nothing about it.

## Leaf prompt templates

Templates for this demo's two-leaf chain. Adapt wording as needed,
but keep the invariant clauses: project-is-at-your-cwd, posture
rules, final-message-is-the-deliverable (and, for writable leaves,
the diff and test output must be in that message).

### Diagnose (read-only, public-posture skill)

```text
You are a subagent leaf running inside a MOCA sandbox. You have the
`public-research` skill loaded — follow its posture: cite only what the
project itself ships, do not assume insider conventions.

Your current working directory is this run's view of a small Python project
— do not cd elsewhere. The files are mounted read-only.

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

### Fix (apply, then verify — full-access skill)

```text
You are a subagent leaf running inside a MOCA sandbox. You have the
`full-access-fix` skill loaded — follow its posture: apply the diagnosed fix
and verify against the organization's testing conventions.

Your current working directory is this run's own writable copy of a small
Python project — do not cd elsewhere. The copy is discarded when this run
ends, so anything you want to return must be in your final message.

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

## Mechanism appendix

What `spawn` does under the hood, for when something surprises you:

- **Three sha256-pinned handles per leaf.** `--config` names a config
  bundle (skills + commands, promoted via `mocactl promote`);
  `--workload` names a workload (project files, uploaded via
  `mocactl workloads create`); the server mints the sessionId. Each
  handle is content-addressed, server-held, and reconstructable from
  `MOCA.md` + the ledger.
- **New session per leaf.** There is no `--session` flag; `spawn`
  always creates one. With `--workload`, the leaf's bash cwd is the
  workload's view (read-only) or writable copy (`--writable`), so the
  project is at `./` — prompts never need to contain the mount path.
- **The detached worker** — forked by `spawn`, its log at
  `~/.local/state/mocactl/spawn-<sessionId>.log` — holds the
  synchronous `POST /v1/runs`. The server runs the leaf to completion
  and stores the result **before responding**; nothing about the
  worker's survival affects the run. Results live server-side for 24h.
- **The worker's own fetch dies at five minutes** — Node/undici's
  default 300-second `headersTimeout`, not a run failure. The ledger
  then records a terminal, sticky `failed: fetch failed` while the
  server finishes the run anyway; `get` still collects. Trust `get`
  over the ledger state.
- **The ledger** is machine-global:
  `~/.local/state/mocactl/subagents.jsonl`. `subagents` joins it with
  live server state; successes are normalized to `done` and terminal
  states are sticky. The demo tag is what scopes a run's leaves —
  always pass `--tag "$TAG"`.
- **`get` is the source of truth.** Honest statuses: `queued`,
  `failed`, `paused`, `responded` (prompt kind), `solved` (solve
  kind). Exit codes are ambiguous; branch on `--json`'s `status`.

## What this skill does not do

- Does not stand up the substrate. Setup owns the scratch dir, the
  demo tag, the workload, and `MOCA.md`; teardown deletes the leaf
  sessions, the workload, and the scratch dir.
- Does not block the turn on a leaf finishing. The run is durable
  server-side; collection happens later, on a later turn.
- Does not prescribe an orchestration shape. The operator's request
  drives how many leaves run and in what order.
