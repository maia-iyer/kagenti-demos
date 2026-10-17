
---

## Addendum: this scratch dir

Everything above is the upstream `moca-delegate-task` skill, verbatim. The
rules below are the deltas this demo adds, and they **override** the
upstream flow where they conflict.

### Preconditions

`MOCA.md` in this directory holds this run's facts. Read it first; pull
`WORKLOAD_ID` and `TAG` into shell variables once per turn:

```bash
TAG="$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
WORKLOAD_ID="$(sed -nE 's/^Workload id:[[:space:]]+//p' MOCA.md)"
```

The port-forward URLs (`SH_CONTROL_PLANE_URL`, `SH_HARNESS_URL`) are
injected into your environment by the staged `.claude/settings.json`;
every `mocactl` command inherits them.

### Overrides on the upstream flow

- **Skip pack + workload create + workload delete.** `setup.sh` already
  packed `example_repo/` and created the workload; its id is in
  `MOCA.md`. `teardown.sh` deletes it. Do not run `contextctl ctx pack`,
  `mocactl workloads create`, or `mocactl workloads delete`. If
  `MOCA.md` is missing or empty, stop and ask the operator to re-run
  `setup.sh` — do not self-heal by packing.
- **`Task` is denied here.** The permission layer refuses it; this skill
  is the only subagent path. Do not shell out to `curl` against MOCA's
  HTTP API directly — `mocactl` owns auth, and its config dir
  (`~/.config/mocactl`) is read-denied in this session.
- **Dispatch-and-stop, not watch-and-wait.** This overrides upstream's
  "watch until none is `running`" step. After `mocactl spawn`, write
  the note (below), report the session id to the operator, and **end
  the turn**. Do not poll, do not `sleep`, do not loop on `subagents`.
  The run is durable server-side (24h TTL); the operator can quit
  Claude, close the laptop, reboot — the result survives. Collection
  is a later turn's job.
- **`get` is the source of truth, not the ledger.** The detached worker's
  own HTTP fetch dies at the five-minute mark (Node/undici's default
  `headersTimeout`), so `subagents` may show a long-running leaf as
  `failed: fetch failed` while the run continues server-side. Trust
  `mocactl get --json`'s `status`, not the ledger.
- **Infrastructure outcomes aren't findings.** `unknown` (worker died
  before the server recorded anything), `paused` (an infra pause, not
  the leaf's choice), and the 5-minute fetch-timeout `failed` all say
  nothing about the operator's code. Say so explicitly; do not present
  these as a diagnosis.
- **There is no cancel.** No server-side cancel exists for `/v1/runs`,
  and no headless cancel command. A dispatched leaf runs to completion.
  If it went wrong, let it finish and ignore its result, or re-dispatch
  a fresh leaf under a fresh label.

### Bookkeeping in `leaves/`

Each dispatch:

- Prompt: `leaves/<label>.prompt.txt`.
- Note: `leaves/<label>.json` with
  `{label, sessionId, kind, writable, promptFile, dispatchedAt}`.
  Include `"writable": true` when you passed `--writable`.
- Collected result: `leaves/<sessionId>.text`, written by
  `mocactl get --out leaves --json`. After collecting, add a
  `collectedAt` timestamp to the note.

Labels are short (`diagnose`, `fix`); use a **fresh label** (`fix2`)
when re-dispatching so earlier notes and prompts are never overwritten.

### Dispatch commands for this demo

Read-only leaf:

```bash
mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt \
  --workload "$WORKLOAD_ID" --tag "$TAG" --json
```

Writable leaf (edits allowed; the per-run copy is discarded on
completion):

```bash
mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt \
  --workload "$WORKLOAD_ID" --writable --tag "$TAG" --json
```

Collect:

```bash
mocactl get "<sessionId>" --out leaves --json
```

Branch on the `status` field, not on the exit code:

- `queued` → still running. Tell the operator and stop. One check per
  turn.
- `responded` → done. Read `leaves/<sessionId>.text`; surface it to the
  operator or inline it verbatim in the next leaf's prompt.
- `failed` / `paused` → surface the reason. Do not auto-redispatch.

List this run's leaves:

```bash
mocactl subagents --tag "$TAG"
```

### Posture for this fixture

- **Diagnose leaf** — read-only. Dispatch without `--writable`.
- **Fix leaf** — writable. Dispatch with `--writable`, edit `src/` only,
  never `vendor/`. The writable copy is discarded when the run ends, so
  the prompt must ask for the diff and the test output as part of the
  final message.
- Keep the demo a sequential chain unless the operator explicitly asks
  for fan-out.

### Chaining

MOCA has no "on complete, trigger X" primitive. Leaf 2 is an independent
session with its own view; it cannot see leaf 1's files. So leaf 2's
prompt must inline leaf 1's collected text **verbatim** — never a path,
never a sessionId.

### Leaf prompt templates

#### Diagnose (read-only)

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

#### Fix (apply, then verify)

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
