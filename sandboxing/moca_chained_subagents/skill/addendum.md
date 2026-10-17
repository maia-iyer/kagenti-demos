
---

## Addendum: this scratch dir

The rules below **override** the upstream flow where they conflict.

### Preconditions

`MOCA.md` holds this run's facts. Pull `TAG` into a shell variable
once per turn:

```bash
TAG="$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
```

`SH_CONTROL_PLANE_URL` and `SH_HARNESS_URL` are injected via
`.claude/settings.json`. If `MOCA.md` is missing, stop and ask the
operator to re-run `setup.sh`.

### The fixture

The directory to pack is `./example_repo` (relative to this scratch
dir, staged by `setup.sh`). Pass it to `contextctl ctx pack` as
`--type workspace`. Do not pack anything else — the demo's leaves are
written against this fixture.

### Per-spawn pack + create, post-collection delete

Each leaf owns its own workload. Upstream's full
pack → create → spawn → get → delete sequence runs **per leaf**, not
once per demo run:

1. Before `mocactl spawn`, pack the fixture and create a workload:

   ```bash
   contextctl ctx pack ./example_repo --type workspace \
     -o leaves/<label>.context
   WORKLOAD_ID="$(mocactl workloads create \
     --context leaves/<label>.context --json | jq -r '.workloadId')"
   ```

   Record `WORKLOAD_ID` on the leaf's note (below). The `.context`
   bundle on disk is a cache you can delete after the workload is up;
   it is not needed again.

2. Spawn with that workload id (and `--writable` if the leaf edits
   files), tagged with `$TAG`.

3. On successful `mocactl get` (terminal status, result written),
   delete the workload:

   ```bash
   mocactl workloads delete "$WORKLOAD_ID"
   ```

   Add `deletedAt` to the note. If `get` is still non-terminal, leave
   the workload alive — delete pairs with **collection**, not with
   dispatch.

### Other overrides

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
- Bundle: `leaves/<label>.context` (transient; delete after create).
- Note: `leaves/<label>.json` with
  `{label, sessionId, workloadId, kind, writable, promptFile, dispatchedAt}`.
- Result: `leaves/<sessionId>.text` via `mocactl get --out leaves --json`.
  Add `collectedAt` and `deletedAt` to the note after collecting and
  deleting the workload.

Use a fresh label when re-dispatching (`fix` → `fix2`).
