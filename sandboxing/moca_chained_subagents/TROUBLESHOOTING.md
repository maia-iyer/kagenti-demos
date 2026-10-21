# Troubleshooting

Known failure modes, plus the by-hand flow — which doubles as the acceptance
test for the mechanics (if this sequence doesn't run clean in a plain
terminal, nothing above it is believable) and as the fallback when the agent
gets stuck.

## Known failure modes

- **`mocactl` can't reach the control plane / connection refused.**
  A port-forward isn't running. `prereqs-install.sh` backgrounds all
  three — supervisor on 8080, control plane on 8090, Context Service on
  9090. Check they are up with
  `pgrep -f 'kubectl --context kind-moca .* port-forward'` (expect
  three PIDs); tail the logs under `~/.local/state/moca-chained-demo/`
  for why one died. To restart them cleanly, re-run
  `./prereqs-install.sh` (it kills stale ones first). Also make sure
  `SH_CONTROL_PLANE_URL` / `SH_HARNESS_URL` are exported (or inherited
  via the staged settings in a Claude session).
- **`setup.sh` fails at doctor.** Follow the fix doctor prints for
  each failing check — it covers reachability, login, credentials,
  and the harness.
- **A dispatch fails at `mocactl workloads create` with "Context
  Service refused the upload".** Context Service's public URL may not
  be reachable from this host. Check the `moca-context-service`
  ConfigMap and that your port-forward (or whatever makes `public-url`
  reachable) is up. Setup probes this once at startup; a mid-run
  outage can trigger the same failure.
- **`get` says `no session`.** Wrong session id, or the session was
  deleted / aged out past 24h.

## Inspecting state in the sandbox

Writable runs discard their copies when the run ends, and read-only
runs do not write to the mount at all, so there is nothing in the
sandbox to inspect after a leaf finishes. The leaf's final message is
the only record of what it did — if you want a diff or test output,
the prompt must ask for it as text (the templates in "Running the flow
by hand" below already do).

If you need to inspect a workload's frozen revision, read the leaf's
note (`leaves/<label>.json`) for its `workloadId` and use
`mocactl workloads get <workloadId>` — but only before the agent runs
`workloads delete` on that leaf's workload after collection.

Local leaf state lives in `leaves/` in the scratch dir:

```bash
cd ~/tmp/moca-chained-scratch
mocactl subagents --tag moca-chained-subagents-demo
cat leaves/diagnose.json          # note: label -> sessionId
cat leaves/<sessionId>.text       # the collected result
```

## Running the flow by hand

What Claude is meant to run for each operator prompt, without the
agent noise — and the acceptance test for the mechanics: this
sequence must run clean in a plain terminal before anything else is
believed. Run it from a fresh `./setup.sh`.

```bash
cd ~/tmp/moca-chained-scratch

# mocactl reaches MOCA through the port-forwards (both must be up).
# Export the two URLs (setup.sh prints these; they're also in MOCA.md):
export SH_CONTROL_PLANE_URL=http://127.0.0.1:8090
export SH_HARNESS_URL=http://127.0.0.1:8080

# Constant tag — scopes `mocactl subagents --tag` and teardown to
# this demo's leaves on the machine-global ledger.
TAG=moca-chained-subagents-demo

# The two config digests promoted at setup time (both are in MOCA.md).
DIGEST_PUBLIC="$(grep -E '^Config digest public:' MOCA.md | awk '{print $NF}')"
DIGEST_FULL="$(grep -E '^Config digest full:'   MOCA.md | awk '{print $NF}')"
```

**1 — author the diagnose leaf's prompt:**

```bash
cat > leaves/diagnose.prompt.txt <<'EOF'
Use the public-research skill. The project's tests currently fail —
diagnose why. The relevant docs are under docs/upstream-refs/.
EOF
```

The `public-research` skill (shipped by the public-only bundle) carries
the posture, the test command, the "no edits / stdlib-only / end with
the full report" rules, and the deliverable shape. The prompt only has
to name the task.

**2 — pack the project subdir and create this leaf's workload:**

```bash
contextctl ctx pack . --type workspace \
  -o leaves/diagnose.context
DIAG_WORKLOAD_ID="$(mocactl workloads create \
  --context leaves/diagnose.context --json | jq -r '.workloadId')"
```

**3 — dispatch it.** Read-only, so just `--workload` (no `--writable`),
and the public-posture config bundle via `--config`. `--json` prints one
line on stdout (`{"type":"session","sessionId":"…","pid":…}`);
diagnostics go to stderr:

```bash
mocactl spawn "$(cat leaves/diagnose.prompt.txt)" --kind prompt \
  --config "$DIGEST_PUBLIC" \
  --workload "$DIAG_WORKLOAD_ID" --tag "$TAG" --json
SID="<paste the sessionId from that line>"
```

**4 — write the note** (this is what a resumed session reads):

```bash
cat > leaves/diagnose.json <<EOF
{"label":"diagnose","sessionId":"$SID","workloadId":"$DIAG_WORKLOAD_ID",
 "kind":"prompt","writable":false,
 "promptFile":"leaves/diagnose.prompt.txt",
 "dispatchedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
```

Then **stop**. The leaf is durable server-side; there is nothing to
babysit. Durability spot-check (worth doing once): Ctrl-C the
supervisor's port-forward while the leaf runs, restore it, and
collect anyway — step 5 still works, because the server finishes the
run no matter what your laptop did.

**5 — collect** (later; re-run every minute or so until done — each
check is free and does not disturb the leaf):

```bash
mocactl get "$SID" --out leaves --json
```

Branch on the printed `status`, not the exit code: `queued` (exit 1)
→ still running; `failed` or `paused` (exit 1) → reason on stderr;
`responded` (exit 0) → read the result and release the workload.
`responded` is the prompt-kind success — `solved` is the solve-kind
twin, and `mocactl subagents` calls both of them `done`:

```bash
cat leaves/"$SID".text
mocactl workloads delete "$DIAG_WORKLOAD_ID"
```

The diagnosis should name the renamed API: `src/greet.py` calls
`lib.old_name` while the vendored `vendor/lib/__init__.py` (v2.0.0)
exports only `new_name`. The sandbox image ships `python3` but no
`pip`; the project is stdlib-only, so `python3 -m unittest` runs
directly.

**6 — chain the fix leaf.** Author its prompt with the diagnosis
inlined **verbatim** (never point one leaf at another leaf's files —
each leaf has its own view / writable copy):

```bash
DIAG="$(cat leaves/"$SID".text)"
cat > leaves/fix.prompt.txt <<EOF
Use the full-access-fix skill. A prior agent produced this diagnosis
of the failing tests:

------------------------------------------------------------------------
$DIAG
------------------------------------------------------------------------

Apply the fix and verify.
EOF
```

The `full-access-fix` skill (shipped by the full bundle) carries the
testing convention, the src/-not-vendor/ rule, the "no pip" rule, and
the verbatim-test-output deliverable. The prompt only has to pass
through the prior leaf's diagnosis.

Pack a fresh workload for the fix leaf, dispatch it with `--writable`,
then collect and release. `get` exit 1 with "has not finished yet"
just means still running:

```bash
contextctl ctx pack . --type workspace -o leaves/fix.context
FIX_WORKLOAD_ID="$(mocactl workloads create \
  --context leaves/fix.context --json | jq -r '.workloadId')"

mocactl spawn "$(cat leaves/fix.prompt.txt)" --kind prompt \
  --config "$DIGEST_FULL" \
  --workload "$FIX_WORKLOAD_ID" --writable --tag "$TAG" --json
FIX_SID="<paste the sessionId>"

cat > leaves/fix.json <<EOF
{"label":"fix","sessionId":"$FIX_SID","workloadId":"$FIX_WORKLOAD_ID",
 "kind":"prompt","writable":true,
 "promptFile":"leaves/fix.prompt.txt",
 "dispatchedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF

mocactl get "$FIX_SID" --out leaves --json
cat leaves/"$FIX_SID".text
mocactl workloads delete "$FIX_WORKLOAD_ID"
```

The report should say `src/greet.py` changed (`old_name` → `new_name`) and
that the tests pass. There is no "inspect the sandbox" fallback: the
writable copy is gone when the run ends.

**7 — see the whole chain:**

```bash
mocactl subagents --tag "$TAG"
```

Both leaves should show `done` — unless one ran longer than five minutes:
the spawn worker's own HTTP request is cut off at the five-minute mark, so
a long leaf shows up here as `failed` / `fetch failed` even though it
completed server-side (see "Pause and resume" in the README). `mocactl get`
is the source of truth: `responded` means it finished.

**8 — tear down:**

```bash
cd -   # back to the demo dir
./teardown.sh
mocactl sessions   # the demo's leaf sessions are gone
```

Re-dispatch after a failure (fresh label, fresh workload — copy the
prompt file and edit as needed):

```bash
cp leaves/fix.prompt.txt leaves/fix2.prompt.txt
contextctl ctx pack . --type workspace -o leaves/fix2.context
FIX2_WORKLOAD_ID="$(mocactl workloads create \
  --context leaves/fix2.context --json | jq -r '.workloadId')"
mocactl spawn "$(cat leaves/fix2.prompt.txt)" --kind prompt \
  --config "$DIGEST_FULL" \
  --workload "$FIX2_WORKLOAD_ID" --writable --tag "$TAG" --json
```

Start a completely fresh chain (new tag, fresh scratch):

```bash
./teardown.sh && ./setup.sh
```
