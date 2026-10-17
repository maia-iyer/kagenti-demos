
---

## Addendum: this scratch dir

Everything above is the upstream `moca-delegate-task` skill, verbatim. The
rules below are the deltas this scratch dir adds, and they **override** the
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
  packed the fixture and created the workload; its id is in `MOCA.md`.
  `teardown.sh` deletes it. Do not run `contextctl ctx pack`,
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

Use a **fresh label** when re-dispatching (e.g. `fix` → `fix2`) so earlier
notes and prompts are never overwritten.
