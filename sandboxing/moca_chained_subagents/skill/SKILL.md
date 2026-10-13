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

This skill is **mechanism only**. It tells you how to dispatch, seed,
and collect one leaf. It does **not** tell you how many leaves to run,
in what order, or with what prompts — those decisions come from the
operator's request. If the operator asks for one leaf, run one. If
they ask for a chain, start them in sequence and feed outputs forward
as they describe.

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

## One leaf, one session, one fresh workspace

Every leaf is its **own** MOCA session, so its own sandbox workspace
at `/workspace/<sessionId>` — and, because you seed it right after
spawn, a fresh copy of the fixture. Three consequences that matter to
you:

- **Leaves are isolated from each other by construction.** A fix leaf
  does not see the files a diagnose leaf saw — it gets a fresh fixture
  plus whatever you inline in its prompt. Never reference one leaf's
  file paths or workspace in another leaf's prompt.
- **No turn sequencing.** Each leaf is a single turn in its own
  session; there is no `409 turn_in_progress` to dodge. Leaves
  *could* run concurrently — fan out only if the operator asks.
- **Session ids are server-generated** (`spawn` prints them). You keep
  short local labels (`diagnose`, `fix`) that name the files in
  `leaves/`.

## Environment

Read `MOCA.md` in the scratch dir first. It holds this run's facts:
the **demo tag**, the sandbox **namespace / pod selector /
container**, the **fixture path** (`./example_repo`), and the
**leaves dir** (`./leaves`). Pull the tag into a shell variable once
per turn:

```bash
TAG="$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
```

The port-forward URLs (`SH_CONTROL_PLANE_URL`, `SH_HARNESS_URL`) are
already injected into your environment by the staged
`.claude/settings.json` — every `mocactl` command you run inherits
them. Run everything from the scratch dir.

Bookkeeping, all in `leaves/`:

- `leaves/<label>.prompt.txt` — the prompt you sent.
- `leaves/<label>.json` — a note you write right after spawn:
  `{label, sessionId, kind, promptFile, dispatchedAt}`. Status is
  never stored — it is always derived fresh from `subagents` / `get`
  at read time.
- `leaves/<sessionId>.text` — the collected result, written by
  `mocactl get --out leaves`.

Labels are local file names; keep them short (`diagnose`, `fix`) and
use a **fresh label** (`fix2`) when re-dispatching, so earlier notes
and prompts are never overwritten.

## Procedure 1: start a leaf

1. Author the leaf's prompt and write it to
   `leaves/<label>.prompt.txt`. Start from a template (below). The
   invariant clauses are not optional: cwd-is-your-private-workspace
   and "do not cd elsewhere"; the wait-for-fixture clause; read-only
   vs apply instructions; and "end your turn with the full report as
   your final message" — the collected result is exactly that text.
   Pass anything the leaf needs from earlier leaves **inline,
   verbatim**.
2. Dispatch:

   ```bash
   mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt \
     --tag "$TAG" --json
   ```

   Quote-substitution keeps the permission prompt legible. `--json`
   prints one line on stdout —
   `{"type":"session","sessionId":"…","pid":…}` — with diagnostics on
   stderr; take the `sessionId` from the stdout line.
3. Write the note `leaves/<label>.json` (shape above).
4. Seed the leaf's workspace, right after spawn — keep the
   dispatch-to-seed window as small as you can:

   ```bash
   SID="<sessionId>"
   for POD in $(kubectl -n moca-sandbox get pods -l app=moca-sandbox -o name); do
     POD="${POD#pod/}"
     kubectl -n moca-sandbox wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null
     kubectl -n moca-sandbox exec "$POD" -c sandbox -- sh -c "mkdir -p '/workspace/$SID'"
     kubectl -n moca-sandbox cp -c sandbox example_repo/. "$POD:/workspace/$SID"
   done
   ```

   (Namespace, selector, and container are this run's values from
   `MOCA.md`; defaults shown.) Every pod gets a copy because a session
   pins to a pod only on its first turn and you cannot know which.
   Both orderings — seed landing before or after the leaf boots — are
   safe: the sandbox worker creates a session's workspace with mkdir
   "use as-is" semantics, and the leaf's prompt tells it to wait for
   `package.json`. One caveat: a leaf quick enough to edit files while
   the copy is still landing can have those edits clobbered by the
   extraction — hence "seed immediately".
5. **Stop.** Report the label and session id to the operator. Do not
   wait, do not poll, do not sleep-and-check — collection is a later
   turn's job.

Failure modes at dispatch:

- `spawn needs a prompt` → the prompt argument came out empty; check
  the prompt file path.
- An immediate connection error → the port-forwards are down (or
  mocactl logged out). `mocactl doctor` says which. Nothing ran; fix
  and retry.
- Prompt over 64 KiB → `spawn` refuses it. The diagnosis is small;
  inline freely, but trim if you hit the cap.

**Manual fallback.** If kubectl is not available to you (or the
operator prefers it), report the session id and the step-4 seed loop
verbatim for the operator to paste. The wait-for-fixture clause makes
seeding untimed — the leaf waits for `package.json` no matter when
the copy lands. The primary path is you-do-it.

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
tool-call transcript. If you need the leaf's reasoning or a diff, ask
for it in the prompt.

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

1. Write leaf 1's prompt; spawn, note, seed (procedure 1). Return to
   the operator.
2. On a later turn (same session or resumed), check leaf 1 with
   procedure 2. If `responded`, Read `leaves/<sessionId>.text`.
3. Write leaf 2's prompt with leaf 1's result **inlined verbatim** —
   never a file path; leaf 2 has a fresh workspace and cannot see
   leaf 1's files.
4. Spawn, note, seed leaf 2 the same way; collect on a later turn.

Posture rules for this demo's fixture: the diagnose leaf is read-only
by prompt; the fix leaf edits `src/` and never `node_modules/`. Keep
the demo a sequential chain unless the operator explicitly asks for
fan-out.

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

A leaf that reports "the fixture never arrived" is the same category:
the seed race went bad (the copy failed on every pod). Check that the
seed loop ran (`kubectl exec … ls /workspace/<sid>`), then re-dispatch
under a new label.

## Leaf prompt templates

Templates for this demo's two-leaf chain. Adapt wording as needed,
but keep the invariant clauses: private workspace, wait-for-fixture,
posture rules, final-message-is-the-deliverable.

### Diagnose (read-only)

```text
You are a subagent leaf running inside a MOCA sandbox. Your current working
directory is your private workspace — do not cd elsewhere. A small Node.js
project is being copied into your workspace right now: if package.json is not
present yet, wait for it (re-check every few seconds; it arrives within a
minute or two).

The project's tests currently fail. Run the test suite (npm test), read the
relevant code and the docs under docs/upstream-refs/, and report:
1. The exact failing assertion and the test command that exercises it.
2. The root cause, with file paths and line references.
3. The minimal change that would fix it, described precisely — another agent
   will apply it on a fresh copy of this project.

If node/npm are not installed in the sandbox, do NOT install or download
anything — no package manager, no Node tarball. Diagnose from the source
and docs alone, and say in your report that the suite could not be run.

Do NOT edit any files: this is a diagnosis-only task. End your turn with the
full diagnosis as your final message.
```

### Fix (apply, then verify)

```text
You are a subagent leaf running inside a MOCA sandbox. Your current working
directory is your private workspace — do not cd elsewhere. A small Node.js
project is being copied into your workspace right now: if package.json is not
present yet, wait for it (re-check every few seconds; it arrives within a
minute or two).

A prior agent diagnosed a test failure in a fresh copy of this project:

------------------------------------------------------------------------
<PASTE leaves/<diagnose sessionId>.text VERBATIM HERE>
------------------------------------------------------------------------

Apply the fix in your workspace copy — edit src/, never node_modules — then
run npm test to confirm the suite passes. If node/npm are not installed in
the sandbox, do NOT install or download anything — no package manager, no
Node tarball: say so in your report, and verify the fix by re-reading the
changed code against the test's assertion instead. Report:
1. The exact change you made (file, line, before/after).
2. The test output after your change — or, if the suite could not be run,
   the reason and your inspection-based verification.

End your turn with the full report as your final message.
```

## Mechanism appendix

What `spawn` does under the hood, for when something surprises you:

- **New session per leaf.** There is no `--session` flag; `spawn`
  always creates one. The leaf's bash cwd is its workspace,
  `/workspace/<sessionId>` (the sandbox always advertises the
  `workspace-subdir` capability), so prompts never need to contain
  the path.
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
  demo tag, and `MOCA.md`; teardown deletes the leaf sessions, their
  workspaces, and the scratch dir.
- Does not block the turn on a leaf finishing. The run is durable
  server-side; collection happens later, on a later turn.
- Does not prescribe an orchestration shape. The operator's request
  drives how many leaves run and in what order.
