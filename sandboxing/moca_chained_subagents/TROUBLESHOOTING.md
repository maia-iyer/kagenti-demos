# Troubleshooting

Known failure modes, plus the by-hand flow — which doubles as the acceptance
test for the mechanics (if this sequence doesn't run clean in a plain
terminal, nothing above it is believable) and as the fallback when the agent
gets stuck.

## Known failure modes

- **`mocactl` can't reach the control plane / connection refused, or
  `mocactl login` fails with "the control plane closed the connection
  (a proxy idle timeout?)".** A port-forward isn't running, or its
  pinned pod rotated and the forward died mid-flight (common after any
  cluster-side restart). `prereqs-install.sh` backgrounds all three —
  supervisor on 8080, control plane on 8090, Context Service on 9090.
  Check they are up with
  `pgrep -f 'kubectl --context kind-moca .* port-forward'` (expect
  three PIDs) and that something is listening on each port
  (`lsof -nP -iTCP:8090 -sTCP:LISTEN`); tail the logs under
  `~/.local/state/moca-chained-demo/` for why one died — a `kubectl
  port-forward` process whose pod was replaced logs `error forwarding
  port … failed to find sandbox` and `lost connection to pod`, and may
  leave the local port in a half-closed state that blocks a naive
  restart. To restart cleanly, re-run `./prereqs-install.sh` (it kills
  stale forwards first); if a port is still bound,
  `lsof -nP -iTCP:<port> -sTCP:LISTEN -t | xargs -r kill -9` and
  re-run. Also make sure `SH_CONTROL_PLANE_URL` / `SH_HARNESS_URL` are
  exported (Claude Code inherits them via `.claude/settings.json`'s
  `env`; OpenCode inherits them only when launched via
  `./run-opencode.sh`).
- **`setup.sh` fails at doctor.** Follow the fix doctor prints for
  each failing check — it covers reachability, login, credentials,
  and the harness.
- **A dispatch fails at `mocactl workloads create` with "Context
  Service refused the upload".** Context Service's public URL may not
  be reachable from this host. Check the `moca-context-service`
  ConfigMap and that your port-forward (or whatever makes `public-url`
  reachable) is up. Setup probes this once at startup; a mid-run
  outage can trigger the same failure.
- **Port conflict with Rancher Desktop's lima SSH mux on `*:8080`.**
  The demo defaults the three port-forwards to `18080` / `18090` /
  `19090` to avoid this, and `prereqs-install.sh` passes
  `SH_PUBLIC_HARNESS_URL=http://127.0.0.1:${HARNESS_PORT}` to
  `deploy/k8s/setup.sh` so the control plane advertises the matching
  port. If you've set `HARNESS_PORT=8080` and see
  `the harness refused: 404 http_404` with `server: istio-envoy`,
  that's the mux — unset the override or pick a different port.
- **A supervisor restart mid-run.** The run is reaped as
  `failed` / `owner_lost` within ~30–100 s and `mocactl get` surfaces
  that terminal state; re-dispatch under a fresh `--label`.
- **`get` says `no session`.** Wrong session id, or the session was
  deleted / aged out past 24h.

## OpenCode-specific (`PARENT=opencode`)

- **OpenCode launched directly, mocactl fails with "missing
  control-plane URL".** OpenCode has no `settings.json` `env`
  equivalent; the staged `run-opencode.sh` wrapper exports
  `SH_CONTROL_PLANE_URL` / `SH_HARNESS_URL` before execing opencode.
  Either launch via `./run-opencode.sh` from the scratch dir, or
  `export` the two URLs by hand first (recorded in `MOCA.md`).
- **A compound shell command is auto-rejected under `opencode run`**
  with `permission requested: external_directory (/var/folders/...)`.
  The upstream `moca-delegate-task` skill tells the agent to use
  `mktemp -d`, and OpenCode gates any shell operation on paths outside
  the project root. Workaround: tell the agent to use `leaves/` for
  packs and results (e.g. "write to `leaves/<name>.result` — not
  `/tmp` or `/var/folders`").

## Inspecting state in the sandbox

Writable runs discard their copies when the run ends, and read-only
runs do not write to the mount at all, so there is nothing in the
sandbox to inspect after a leaf finishes. The leaf's final message is
the only record of what it did — if you want a diff or test output,
the prompt must ask for it as text (the templates in "Running the flow
by hand" below already do).

If you need to inspect a workload's frozen revision, look up its id
from the ledger and use `mocactl workloads get <workloadId>` — but only
before the agent runs `workloads delete` on that leaf's workload after
collection.

```bash
cd ~/tmp/moca-chained-scratch
mocactl subagents --tag moca-chained-subagents-demo
mocactl subagents --tag moca-chained-subagents-demo --json \
  | jq -r '.subagents[] | select(.label=="diagnose") | .workload'
cat leaves/<sessionId>.text       # the collected result
```

## Running the flow by hand

What the parent agent is meant to run for each operator prompt,
without the agent noise — and the acceptance test for the mechanics:
this sequence must run clean in a plain terminal before anything else
is believed. Run it from a fresh `./setup.sh`.

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
the public-posture config bundle via `--config`, and `--label diagnose`
so a resumed session can find it by name. `--json` prints one line on
stdout (`{"type":"session","sessionId":"…","pid":…}`); diagnostics go
to stderr:

```bash
mocactl spawn "$(cat leaves/diagnose.prompt.txt)" --kind prompt \
  --config "$DIGEST_PUBLIC" \
  --workload "$DIAG_WORKLOAD_ID" --tag "$TAG" --label diagnose --json
```

Then **stop**. The leaf is durable server-side; no sidecar note needed
— `mocactl subagents --tag "$TAG" --json` reads back the label,
sessionId, workloadId, bundle digest, and state. Durability spot-check
(worth doing once): Ctrl-C the supervisor's port-forward while the
leaf runs, restore it, and collect anyway — step 4 still works, because
the server finishes the run no matter what your laptop did.

**4 — collect** (later; re-run every minute or so until done — each
check is free and does not disturb the leaf). Look up the sessionId
and workloadId from the ledger by label:

```bash
SID=$(mocactl subagents --tag "$TAG" --json \
  | jq -r '.subagents[] | select(.label=="diagnose") | .sessionId')
WLID=$(mocactl subagents --tag "$TAG" --json \
  | jq -r '.subagents[] | select(.label=="diagnose") | .workload')
mocactl get "$SID" --out leaves --json
```

Branch on the printed `status`, not the exit code: `queued` (exit 1)
→ still running; `failed` or `paused` (exit 1) → reason on stderr;
`responded` (exit 0) → read the result and release the workload.
`responded` is the prompt-kind success — `solved` is the solve-kind
twin, and `mocactl subagents` calls both of them `done`:

```bash
cat leaves/"$SID".text
mocactl workloads delete "$WLID"
```

The diagnosis should name the renamed API: `src/greet.py` calls
`lib.old_name` while the vendored `vendor/lib/__init__.py` (v2.0.0)
exports only `new_name`. The sandbox image ships `python3` but no
`pip`; the project is stdlib-only, so `python3 -m unittest` runs
directly.

**5 — chain the fix leaf.** Author its prompt with the diagnosis
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

Pack a fresh workload for the fix leaf, dispatch it with `--writable`
and `--label fix`, then collect and release. `get` exit 1 with "has
not finished yet" just means still running:

```bash
contextctl ctx pack . --type workspace -o leaves/fix.context
FIX_WORKLOAD_ID="$(mocactl workloads create \
  --context leaves/fix.context --json | jq -r '.workloadId')"

mocactl spawn "$(cat leaves/fix.prompt.txt)" --kind prompt \
  --config "$DIGEST_FULL" \
  --workload "$FIX_WORKLOAD_ID" --writable --tag "$TAG" --label fix --json

FIX_SID=$(mocactl subagents --tag "$TAG" --json \
  | jq -r '.subagents[] | select(.label=="fix") | .sessionId')
mocactl get "$FIX_SID" --out leaves --json
cat leaves/"$FIX_SID".text
mocactl workloads delete "$FIX_WORKLOAD_ID"
```

The report should say `src/greet.py` changed (`old_name` → `new_name`) and
that the tests pass. There is no "inspect the sandbox" fallback: the
writable copy is gone when the run ends.

**6 — see the whole chain:**

```bash
mocactl subagents --tag "$TAG"
```

Both leaves should show `done` — unless one ran longer than five minutes:
the spawn worker's own HTTP request is cut off at the five-minute mark, so
a long leaf shows up here as `failed` / `fetch failed` even though it
completed server-side (see "Pause and resume" in the README). `mocactl get`
is the source of truth: `responded` means it finished.

**7 — tear down:**

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
  --workload "$FIX2_WORKLOAD_ID" --writable --tag "$TAG" --label fix2 --json
```

Start a completely fresh chain (new tag, fresh scratch):

```bash
./teardown.sh && ./setup.sh
```
