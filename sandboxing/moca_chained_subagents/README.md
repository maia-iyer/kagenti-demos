# Local Claude Code driving chained MOCA subagents

Claude Code runs on your laptop. It has **no built-in subagent tool** —
`Task` is denied in `.claude/settings.json`. To delegate, it uses a
skill that knows how to dispatch an isolated leaf to
[MOCA](https://github.com/rossoctl/serverless-harness) by shelling out
to a small `moca` CLI (installed into the scratch dir by `setup.sh`
and put on `$PATH` via the staged settings).

Dispatch is a **detached synchronous turn**. The parent `POST`s to
`/runs` with no `async` field, so MOCA runs the leaf and returns the
answer in that same response. To keep the operator's turn from
blocking on it, `moca start` **detach-executes**: it forks a
background worker (`nohup`, fully redirected, disowned) that owns the
blocking HTTP call and writes the response to disk when it returns.
`moca start` itself returns as soon as that worker is forked.

Because the worker sits outside Claude Code's process group,
**you can quit Claude Code and come back later** — the leaf keeps
running, the worker keeps holding the call, and a resumed Claude
session picks up pending runs from `.moca-runs/` in the scratch dir.

Two independent mechanisms protect the result:

1. The detached worker outlives the Claude session and writes
   `.result.json`.
2. MOCA persists each leaf's result cluster-side **before** it writes
   the sync HTTP response, so if the worker is killed *after the leaf
   finished*, the result is still recoverable via `GET /runs/status`
   for 24h.

`moca check` prefers (1) and falls back to (2). Note (2) only covers a
leaf that ran to completion — if Knative's 300s timeout cuts a leaf off
mid-run, nothing was persisted and the work is lost. See the caveats
under "Pause and resume".

The orchestration shape is the **operator's**, not the skill's. For
this demo the operator issues prompts in sequence:

1. *"Dispatch a subagent to diagnose the failing test."* The parent
   writes a run record, forks the detached worker, and returns the
   session id. Operator can walk away.
2. Later: *"Check on that subagent and report the diagnosis."* The
   parent reads the worker's result file and surfaces the diagnosis.
3. *"Dispatch a fixer with that diagnosis."* Repeat the pattern.

MOCA does not know about the chain; from its perspective each leaf is
an independent `/runs` call that scales to zero when it's done. The
skill does not know about the chain either — it describes how to
start and collect one leaf, and the model composes multi-leaf flows
from the operator's requests.

For the full design, see [PLAN.md](PLAN.md).

## How it works

Three pieces cooperate:

1. **A skill (`moca-dispatch`)** — the mechanism contract. Tells
   Claude how to invoke the `moca` CLI (`start`, `check`, `list`),
   how to compose leaf prompts (workspace path, forward-passed
   context, deliverable shape), and how to sequence a chain. Does
   **not** prescribe how many leaves to run or in what order — that
   comes from the operator's prompts.
2. **A `moca` CLI** — a small shell script staged at
   `<scratch>/bin/moca` by setup. Wraps the sync `POST /runs` (plus
   `GET /runs/status` as a recovery fallback) with the host header,
   forks and tracks the detached worker, parses MOCA's responses, and
   writes/updates run records in `.moca-runs/` so the shape on disk is
   always what the skill expects. Keeps the permission prompt short
   (`moca start r1.diagnose r1-diagnose.prompt.txt`) instead of a long
   curl line.
3. **A denied `Task` tool** — `.claude/settings.json` denies the
   built-in subagent tool, so the model has to route through the skill
   instead of forking in-process. The permission prompt on each
   `moca start …` is the operator's visual confirmation that the leaf
   is being dispatched to MOCA, not run locally.
4. **A seeded sandbox pool** — `setup.sh` copies `example_repo/`
   into every pool-labeled sandbox pod at
   `/workspace/<run-id>/repo` via `kubectl cp`. A leaf leases an
   arbitrary pool pod, so every one needs the fixture. The skill only
   dispatches runs; it never touches `/workspace` at runtime.

The sync `POST /runs` returns the leaf's answer inline to the detached
worker, which writes it to `.result.json`. Run records live in
`.moca-runs/` in the scratch dir — one JSON file per dispatched leaf,
plus its `.prompt.txt`, `.result.json`, and the worker's `.log`. A
resumed Claude session finds in-flight work by reading that directory,
and `moca list` reports whether each pending run's worker is still
alive.

## How state flows

- **Setup time.** `setup.sh` copies `example_repo/` into every
  pool-labeled sandbox pod at `/workspace/<run-id>/repo` via
  `kubectl cp`. The fixture is cluster-side before Claude ever starts.
- **Dispatch.** The only state going from the laptop to MOCA at
  dispatch time is the prompt text and the sessionId. The parent
  embeds any output from prior leaves into the next leaf's prompt as
  plain text; there is no shared memory between leaves.
- **Execution.** MOCA cold-starts the harness revision, which runs the
  agent and exec's into one of the leased pool pods, working against
  `/workspace/<run-id>/repo` on that pod.
- **Return.** The leaf's answer comes back as the `.text` field of the
  sync `POST /runs` response (alongside `status: "responded"` and a
  `usage` block), which the detached worker writes verbatim to
  `.result.json`. Files the leaf wrote stay on the sandbox pod and do
  **not** come back to the laptop. If the operator wants to see a diff
  or a test log, the leaf's prompt must ask for it as text in the
  response.

## Inspecting state in the sandbox

Files a leaf writes stay on the sandbox pod — they do not come back to
the laptop. To see what actually changed, go look:

```bash
# Which run directories exist on a pool pod
kubectl -n default exec sandbox-0 -- ls /workspace

# The fixture for this run
kubectl -n default exec sandbox-0 -- ls -la /workspace/<run-id>/repo

# Did the fixer's rename land?
kubectl -n default exec sandbox-0 -- cat /workspace/<run-id>/repo/src/index.js
```

Two things to keep in mind:

- **A leaf leases an arbitrary pool pod.** If a change isn't on
  `sandbox-0`, check `sandbox-1` and `sandbox-2`. To find it without
  guessing, ask the leaf's prompt to report `hostname` in its answer.
- **The fixture is not a git repo**, so `git diff` won't work in the
  sandbox. If you want a diff, have the leaf's prompt ask for one as
  text in its response.

Local run state — prompts, results, worker logs — lives in
`.moca-runs/` in the scratch dir:

```bash
cd ~/tmp/moca-chained-scratch
moca list                                    # every record + worker liveness
cat .moca-runs/<run-id>-<leaf>.result.json   # full response incl. usage
cat .moca-runs/<run-id>-<leaf>.log           # the detached worker's stderr
```

## What's honest and what isn't

- **Isolation here is prompt-only, not substrate-enforced.** This
  MOCA install exposes a shared pool of sandbox pods and no per-run
  mount-posture controls — `moca start` sends `kind:"prompt"`, and
  there is no `workload` field, no per-run `readOnly` flag, and no
  `/workloads` endpoint to pre-register posture-specific workloads.
  The researcher-vs-fixer split lives in the prompts you write
  ("do not modify files" vs "apply this fix"); a non-compliant leaf
  could ignore it. A later version of this demo may bring back
  substrate-enforced read-only mounts if MOCA grows that surface.

- **Every leaf gets the same tools.** MOCA gives every leaf the same
  seven (`read, write, edit, ls, find, bash, grep`) with no web-fetch
  tool and no per-leaf `tools` allowlist on `LeafEnvelope`. Honest
  capability splits would need an upstream `tools` field.

- **Chaining is parent-side.** MOCA has no "on complete, trigger X"
  primitive; the parent Claude session does the sequencing between
  the operator's two prompts. The skill does not encode the chain
  either — the operator's two prompts and the parent's judgment do.

## Prerequisites

- A kind cluster with [MOCA](https://github.com/rossoctl/moca) deployed via
  its [quick-start](https://github.com/rossoctl/moca#quick-start). That
  flow installs the harness in the `default` namespace behind Kourier and
  brings up the sandbox pool.
- `kubectl` configured for that cluster.

> **No KEDA ScaledJob needed.** The `leaf-worker` ScaledJob drains
> MOCA's async Redis stream. This demo uses the sync run path
> exclusively, where the Knative harness revision runs the agent
> itself and exec's into a leased sandbox pod — so no `leaf-worker`
> Job is ever created and the ScaledJob stays `ACTIVE=False` even
> while leaves are running. If it's installed, it's harmless and idle.
- `curl` and `jq` on your `PATH`.
- Claude Code CLI.

MOCA is reached through Kourier. In another terminal, port-forward the
Kourier gateway and export the Host / Base env vars:

```bash
kubectl port-forward -n kourier-system svc/kourier 8080:80

export HOST="serverless-harness.default.example.com"
export BASE="http://localhost:8080"
```

Every call to MOCA must send `-H "Host: $HOST"` — Kourier routes by Host.
`setup.sh` and the dispatch skill both do this automatically.

**Raise the Knative request timeout before your first dispatch.** The
300s default is not enough for the fixer leaf, which must edit a file,
re-run tests, and report a diff — often after a cold start. Exceeding
it yields `504 activator request timeout` and an unrecoverable result
(see Troubleshooting).

```bash
kubectl -n default patch service.serving.knative.dev serverless-harness \
  --type=merge -p '{"spec":{"template":{"spec":{"timeoutSeconds":1800}}}}'
```

## Setup

From this directory:

```bash
./setup.sh
```

This:

1. Verifies `kubectl`, `curl`, `jq` are on `PATH` and that MOCA is
   reachable at `http://localhost:8080`.
2. Copies `example_repo/` into every pool-labeled sandbox pod at
   `/workspace/<run-id>/repo` via `kubectl cp`.
3. Stages `.claude/settings.json`, `.claude/skills/moca-dispatch/`,
   and `bin/moca` into `~/tmp/moca-chained-scratch/`, and patches
   `settings.json` so the scratch `bin/` is on `$PATH` for the
   Bash tool.
4. Writes `MOCA.md` into the scratch dir with the base URL, host
   header, run id, and workspace path.

Environment overrides (set before running):

- `MOCA_NS` — MOCA namespace (default `default`).
- `MOCA_PORT` — local port the port-forward uses (default `8080`).
- `SANDBOX_POOL_SELECTOR` — label selector for pool pods
  (default `sh.kagenti.io/sandbox-pool=default`).
- `RUN_ID` / `WORKSPACE_REF` — run id and workspace path to seed.
- `SCRATCH_DIR` — scratch dir path.

## Run a session

```bash
cd ~/tmp/moca-chained-scratch && claude
```

The demo flow is **operator prompts, in sequence**. The skill does
not encode the flow; you drive it.

**Prompt 1 — start the diagnosis.** Paste something like:

> There's a Node.js project seeded at `/workspace/<run-id>/repo` on
> MOCA (the exact path is in `MOCA.md`). Dispatch a subagent to
> diagnose why its tests are failing. Tell the leaf to read-only —
> do not modify files, do not run shell commands beyond `npm test`.

Claude should:

1. Read the `moca-dispatch` skill.
2. **Not** invoke `Task` — if it tries, the deny fires and it
   re-routes through the skill.
3. Write the leaf's prompt to a file in `.moca-runs/` and run
   `moca start <run-id>/diagnose <that file>`. The permission prompt
   shows the `moca start …` command — short, legible, and clearly
   not a local shell execution.
4. The CLI writes a record file at
   `.moca-runs/<run-id>-<leaf-label>.json`, forks the detached worker,
   and returns control to you with the sessionId and the worker's pid.
   The leaf is now running on the cluster; this turn is over.

**Prompt 2 — collect the diagnosis.** When you're ready (seconds to
minutes later, same session or a resumed one):

> Check on that subagent and report the diagnosis.

Claude runs `moca check <session-id>`, which reads the
`.result.json` the detached worker wrote and prints the leaf's `.text`
to stdout for Claude to surface to you. If the leaf is still running,
`check` says so and the turn ends — Claude should not sit in a polling
loop.

**Prompt 3 — start the fix.** After reviewing the diagnosis:

> Good. Dispatch another subagent to apply that fix, run the tests,
> and report the diff and outcome.

Claude dispatches a second leaf, embedding the diagnosis from
Prompt 2 verbatim in the new leaf's prompt. Record is written.
Control returns to you.

> **Note on isolation.** On this MOCA install there is no per-run
> read-only mount — both the researcher and the fixer leaves get
> the same substrate posture. The researcher's "don't modify files"
> contract lives in its prompt, not in the mount. See "What's honest
> and what isn't" above.

**Prompt 4 — collect the fix result.**

> Check on it.

Claude polls, surfaces the diff and test outcome.

While leaves run, in another terminal:

```bash
kubectl -n default get pods -w
```

You should see the `serverless-harness-*` revision cold-start on
dispatch and scale back to zero once it goes idle. That's the
MOCA-value visual: the subagent's work ran on infrastructure that
didn't exist before you asked and won't exist after.

You will **not** see `leaf-worker-*` pods — those belong to MOCA's
async queue, which this demo doesn't use. On the sync path the harness
revision runs the agent itself and exec's into a leased `sandbox-*`
pod.

## Pause and resume

Because the blocking call lives in a detached worker rather than in
Claude's turn, you can quit Claude any time after a dispatch has
written its record file in `.moca-runs/`. The worker keeps holding the
call and the leaf keeps running on the cluster.

To resume: just start Claude again from the scratch dir
(`cd ~/tmp/moca-chained-scratch && claude`). On the next turn, ask
Claude to check for pending runs:

> Any subagents still pending from an earlier session?

Claude runs `moca list`, which finds records with `status: "pending"`
and reports whether each one's detached worker is still alive. For
each, `moca check` reads the worker's result file — or, if the worker
was lost, recovers the result from `/runs/status`.

The scratch dir **is** the resumable state. Everything needed to pick
up a dropped session — settings, skill, pending run records,
completed results — is in it. Nothing lives in `$HOME` or in the
Claude Code session identifier.

**Caveats.**

- **Quitting Claude is safe; rebooting your laptop is not.** The
  detached worker is a local process. If it dies, the leaf still
  completes cluster-side and `moca check` recovers the result from
  `/runs/status` — but only within MOCA's retention window.
- **Result retention is 24h by default**
  (`LEAF_RESULT_TTL_SECONDS`). After that, a recovery poll returns
  `{"status":"queued"}` — MOCA cannot distinguish an expired result
  from one that never ran — and the CLI reports `status=lost`.
- **Knative caps a single request at 300s** (`timeoutSeconds` in
  MOCA's `service.yaml`), and this is the most likely way a realistic
  leaf fails. Kourier's activator returns a plain-text `504
  activator request timeout` — not JSON — and `moca check` reports
  `status=gateway-error`.

  **A 300s timeout usually means the result is gone, not recoverable.**
  The "MOCA persists before responding" guarantee only helps once the
  leaf *finished*; a leaf cut off mid-run never got that far, and
  `/runs/status` answers `queued` (which MOCA also returns for "never
  recorded" and "expired", so it cannot be distinguished). `moca check`
  reports `status=lost`.

  Raise `timeoutSeconds` before demoing — see Prerequisites. Keep leaf
  prompts tightly scoped too; narrow deliverables finish faster and are
  less likely to hit the cap.

  **A timed-out leaf may have still done the work.** The 504 kills the
  reporting channel, not the leaf — it can apply its edits on the
  sandbox pod and then lose the connection before answering. `moca
  check` cannot tell this apart from "never ran". Go look at the pod
  (see "Inspecting state in the sandbox") before assuming nothing
  happened.
- **Saturation is retryable, not a failure.** On a full sandbox pool
  MOCA returns 503 and deliberately stores *no* result record, so
  nothing ran. The CLI reports `status=saturated`; re-dispatch under a
  new leaf label.
- Unlike MOCA's async queue, this sync path **works on authenticated
  deployments too** (`async:true` is rejected with 501 whenever a
  token is presented). This demo's cluster is unauthenticated anyway.

## Teardown

```bash
./teardown.sh
```

This removes the seeded fixture from the sandbox pool pods and
deletes the scratch directory. It does **not** touch MOCA or your
cluster. If a `kubectl port-forward` is still running, `Ctrl-C` it.

## Troubleshooting

- **`curl: (7)` / connection refused.** The MOCA port-forward is not
  running. Start it in another terminal.
- **`401` / `403` from `POST /runs`.** Your MOCA deployment has auth
  enabled and the CLI sends no token. The sync path itself supports
  authenticated deployments; this demo just doesn't wire up a token.
- **`moca check` reports `Session id must be non-empty, contain only
  alphanumeric characters, '-', '_', and '.'`.** The session id
  contained an illegal character — almost always a `/`. MOCA rejects
  it at the API boundary, so **nothing ran**; this is not a finding
  about the project under test. Use `<run-id>.<leaf-label>` (e.g.
  `review-123.diagnose`). The CLI now validates this locally before
  dispatching, so you should see it fail at `start` instead. Note the
  "must be non-empty" wording is a red herring when the id was
  non-empty but had a bad character.

- **`moca check` says `status=saturated`.** MOCA's sandbox pool was
  full (HTTP 503) and nothing ran. Wait or scale, then re-dispatch
  under a new leaf label.
- **`moca check` says `status=lost`.** The detached worker is gone and
  MOCA holds no result for that sessionId — either the result aged out
  (24h TTL), MOCA was restarted, or the leaf was never scheduled.
  Re-dispatch under a new leaf label if you still want the work done.
- **A run never seems to finish.** Check whether its worker is alive
  with `moca list`. If the worker is alive but the leaf is slow, check
  `kubectl -n default get pods` for a running `serverless-harness-*`
  pod. Remember Knative cuts any single request at 300s by default —
  the result is still recoverable, but the worker will log a transport
  error.
- **The worker's own errors.** Each run's detached worker logs to
  `.moca-runs/<run>-<leaf>.log`. Read it when `check` can't explain a
  failure.
- **Claude tries `Task` and gets denied, then stops.** The skill
  wasn't found. Confirm
  `~/tmp/moca-chained-scratch/.claude/skills/moca-dispatch/SKILL.md`
  exists; re-run `./setup.sh` if it doesn't.
- **Claude asks "which workload is read-only?" or similar.** The
  operator prompt said "read-only workload" / "read-write workload",
  but this MOCA install exposes no workload catalog and the CLI
  takes no workload argument. Rephrase the prompt without those
  terms — the researcher-vs-fixer split is prompt-only here (see
  "What's honest and what isn't").
- **A diagnosis leaf reads a stale version of the fixture.** The
  sandbox pods weren't re-seeded after you edited `example_repo/`.
  Run `./teardown.sh && ./setup.sh` — setup wipes the per-run
  directory on each pool pod and re-copies.

## Security note

This demo is not secured. MOCA is unauthenticated in the default kind
deployment; anyone with access to the port-forward can dispatch leaves.
Do not run this configuration against anything other than a throwaway
local cluster.

## Files in this directory

```
PLAN.md                    Design doc (trimmed)
README.md                  This file
skill/SKILL.md             Skill Claude reads to dispatch leaves to MOCA
bin/moca                   Small CLI the skill shells out to (start / check / list);
                           start detach-executes the blocking sync call
settings.json.example      Permission policy: denies Task, allows moca start/check/list
setup.sh                   Seeds fixture into sandbox pods, stages scratch (incl. .moca-runs/ and bin/moca)
teardown.sh                Removes seeded fixture and the scratch dir
example_repo/              Vendored fixture — Node.js project with a renamed-API bug
```

> `lib/ctx.sh` is a leftover from an earlier design that used a
> Context Service PVC + per-posture workloads. The current setup
> seeds the sandbox pool directly and does not source it.

In the scratch dir after `setup.sh`:

```
~/tmp/moca-chained-scratch/
├── .claude/
│   ├── settings.json              Allow-list for moca CLI + PATH env pointing at bin/
│   └── skills/moca-dispatch/      Copied from skill/
├── bin/
│   └── moca                       CLI the skill invokes; detach-executes the sync POST /runs
├── .moca-runs/                    Run records (+ *.prompt.txt / *.result.json / *.log siblings)
└── MOCA.md                        Base URL, host header, run-id, workspace path for this session
```

## Appendix: running the flow by hand

What Claude is meant to run for each operator prompt, without the agent
noise. Substitute your run id from `MOCA.md` for `review-123`; leaf
prompt text is illustrative.

```bash
cd ~/tmp/moca-chained-scratch
export PATH="$HOME/tmp/moca-chained-scratch/bin:$PATH"
```

Prompt 1 — dispatch the diagnosis:

```bash
cat > .moca-runs/review-123-diagnose.prompt.txt <<'EOF'
You are a read-only diagnostic agent working in an isolated sandbox.
Your workspace is a Node.js project at /workspace/review-123/repo.

Task: determine why the project's tests are failing.

Constraints:
- Do NOT modify, create, or delete any files.
- The only shell command you may run is `npm test`.

Deliverable — respond in plain text with:
1. The exact error message from the test run.
2. The file and line where the failure originates.
3. The root cause, in one or two sentences.
4. The one-line change that would fix it (describe it; do not apply it).
EOF

moca start "review-123.diagnose" .moca-runs/review-123-diagnose.prompt.txt
```

Prompt 2 — collect the diagnosis:

```bash
moca list
moca check "review-123.diagnose"
```

Prompt 3 — dispatch the fixer, embedding the diagnosis verbatim:

```bash
DIAG="$(moca check "review-123.diagnose" | tail -n +3)"

cat > .moca-runs/review-123-fix.prompt.txt <<EOF
You are a fixer agent working in an isolated sandbox.
Your workspace is a Node.js project at /workspace/review-123/repo.

A previous read-only agent diagnosed the test failure. Its findings:

--- BEGIN DIAGNOSIS ---
${DIAG}
--- END DIAGNOSIS ---

Task: apply the fix described above, then run \`npm test\`.

Deliverable — respond in plain text with:
1. The changed line, before and after, with its file path.
2. Whether the tests now pass.
3. The output of \`hostname\`, so I know which sandbox pod you used.
EOF

moca start "review-123.fix" .moca-runs/review-123-fix.prompt.txt
```

Prompt 4 — collect the fix result:

```bash
moca check "review-123.fix"
```

Watch the harness cold-start and scale to zero (another terminal):

```bash
kubectl -n default get pods -w
```

Confirm the fix landed cluster-side, not locally:

```bash
for p in sandbox-0 sandbox-1 sandbox-2; do
  echo "=== $p ==="
  kubectl -n default exec "$p" -- cat /workspace/review-123/repo/src/index.js
done
```

Inspect a failed leaf:

```bash
cat .moca-runs/review-123.fix.json
cat .moca-runs/review-123.fix.result.json
cat .moca-runs/review-123.fix.log
```

Re-dispatch after a failure (needs a new leaf label):

```bash
cp .moca-runs/review-123-fix.prompt.txt .moca-runs/review-123-fix2.prompt.txt
moca start "review-123.fix2" .moca-runs/review-123-fix2.prompt.txt
```

Re-seed between runs (a fixer leaf mutates its pod):

```bash
kubectl -n default cp example_repo/. sandbox-0:/workspace/review-123/repo
# or, fresh run id across all pods, from the demo dir:
./teardown.sh && ./setup.sh
```
