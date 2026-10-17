
---

## Addendum: this scratch dir

The rules below **override** the upstream flow where they conflict.

### Preconditions

`MOCA.md` holds this run's facts. Pull `WORKLOAD_ID` and `TAG` into shell
variables once per turn:

```bash
TAG="$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
WORKLOAD_ID="$(sed -nE 's/^Workload id:[[:space:]]+//p' MOCA.md)"
```

`SH_CONTROL_PLANE_URL` and `SH_HARNESS_URL` are injected via
`.claude/settings.json`.

### Overrides

- **Skip pack + workload create + workload delete.** `setup.sh` /
  `teardown.sh` own them. If `MOCA.md` is missing, stop and ask the
  operator to re-run `setup.sh`.
- **`Task` is denied.** This skill is the only subagent path. Do not
  shell out to `curl` against MOCA's HTTP API.
- **Dispatch-and-stop.** After `mocactl spawn`, write the note, report
  the session id, and end the turn. Do not poll, `sleep`, or loop on
  `subagents`. Collection is a later turn's job.
- **`get` is the source of truth, not the ledger.** Trust
  `mocactl get --json`'s `status`; `subagents` may show a long-running
  leaf as `failed: fetch failed` while the run continues server-side.
- **Infrastructure outcomes aren't findings.** `unknown`, `paused`, and
  the 5-minute fetch-timeout `failed` say nothing about the operator's
  code. Say so explicitly.
- **There is no cancel.** A dispatched leaf runs to completion. Let it
  finish and ignore its result, or re-dispatch under a fresh label.

### Bookkeeping in `leaves/`

- Prompt: `leaves/<label>.prompt.txt`.
- Note: `leaves/<label>.json` with
  `{label, sessionId, kind, writable, promptFile, dispatchedAt}`.
- Result: `leaves/<sessionId>.text` via `mocactl get --out leaves --json`.
  Add `collectedAt` to the note after collecting.

Use a fresh label when re-dispatching (`fix` → `fix2`).
