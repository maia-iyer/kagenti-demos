
---

## Addendum: this scratch dir

### Preconditions

`MOCA.md` holds this run's facts:

```bash
TAG="$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
```

`SH_CONTROL_PLANE_URL` / `SH_HARNESS_URL` come from
`.claude/settings.json`. If `MOCA.md` is missing, stop and ask the
operator to re-run `setup.sh`.

### Per-leaf workload: pack/create/spawn, then (later) get/delete

Fixture is `./example_repo`. Each leaf owns its own workload.

**Dispatch turn:**

```bash
contextctl ctx pack ./example_repo --type workspace -o leaves/<label>.context
WORKLOAD_ID="$(mocactl workloads create --context leaves/<label>.context --json | jq -r '.workloadId')"
mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt \
  --workload "$WORKLOAD_ID" [--writable] --tag "$TAG" --json
```

Record `workloadId` on the note.

**Collection turn:** `mocactl get <sessionId> --out leaves --json`
once. On `responded` / `failed` / `paused`, surface the outcome and
`mocactl workloads delete "$WORKLOAD_ID"`. On `queued`, report "still
running" and stop. Delete pairs with collection, not dispatch.

### Notes

- `Task` is denied — this skill is the only subagent path.
- `get` beats `subagents`: the ledger shows long leaves as
  `failed: fetch failed` while the run continues.
- `unknown` / `paused` / 5-minute `failed` are infrastructure
  outcomes, not findings.
- No cancel. Let a bad leaf finish and re-dispatch under a fresh label
  (`fix` → `fix2`).

### `leaves/` bookkeeping

- `<label>.prompt.txt`, `<label>.context` (transient).
- `<label>.json`: `{label, sessionId, workloadId, kind, writable,
  promptFile, dispatchedAt}`; add `collectedAt` / `deletedAt` on
  collection.
- `<sessionId>.text` via `mocactl get`.
