# Local Claude Code driving chained MOCA subagents

Claude Code runs on your laptop. It has **no built-in subagent tool** —
`Task` is denied in `.claude/settings.json`. To delegate, it uses a
skill that knows how to dispatch an isolated leaf to
[MOCA](https://github.com/rossoctl/serverless-harness) by shelling out
to a small `moca` CLI (installed into the scratch dir by `setup.sh`
and put on `$PATH` via the staged settings).

Dispatch is **asynchronous**. The parent `POST`s to `/runs` and MOCA
returns a run handle immediately; the leaf keeps running on the
cluster. Collection is a separate `GET /runs/status` call on a later
turn. In between, **you can quit Claude Code and come back later** —
the leaf doesn't care, the result is held cluster-side, and a resumed
Claude session picks up pending runs from `.moca-runs/` in the scratch
dir.

The orchestration shape is the **operator's**, not the skill's. For
this demo the operator issues prompts in sequence:

1. *"Dispatch a subagent to diagnose the failing test."* The parent
   starts a leaf, writes a run record, and returns the handle.
   Operator can walk away.
2. Later: *"Check on that subagent and report the diagnosis."* The
   parent polls `/runs/status`, writes the result, surfaces the
   diagnosis.
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
   `<scratch>/bin/moca` by setup. Wraps `POST /runs` /
   `GET /runs/status` with the host header, parses MOCA's responses,
   and writes/updates run records in `.moca-runs/` so the shape on
   disk is always what the skill expects. Keeps the permission prompt
   short (`moca start r1/diagnose r1-diagnose.prompt.txt`) instead of
   a long curl line.
3. **A denied `Task` tool** — `.claude/settings.json` denies the
   built-in subagent tool, so the model has to route through the skill
   instead of forking in-process. The permission prompt on each
   `moca start …` is the operator's visual confirmation that the leaf
   is being dispatched to MOCA, not run locally.
4. **A seeded sandbox pool** — `setup.sh` copies `example_repo/`
   into every pool-labeled sandbox pod at
   `/workspace/<run-id>/repo` via `kubectl cp`. The KEDA ScaledJob
   leases any pool pod per leaf, so every one needs the fixture.
   The skill only dispatches runs; it never touches `/workspace` at
   runtime.

`POST /runs` returns a run handle immediately; the leaf's answer is
collected via `GET /runs/status?sessionId=…` on a later turn. Run
records live in `.moca-runs/` in the scratch dir — one JSON file per
dispatched leaf. A resumed Claude session finds in-flight work by
reading that directory.

## How state flows

- **Setup time.** `setup.sh` copies `example_repo/` into every
  pool-labeled sandbox pod at `/workspace/<run-id>/repo` via
  `kubectl cp`. The fixture is cluster-side before Claude ever starts.
- **Dispatch.** The only state going from the laptop to MOCA at
  dispatch time is the prompt text and the sessionId. The parent
  embeds any output from prior leaves into the next leaf's prompt as
  plain text; there is no shared memory between leaves.
- **Execution.** MOCA cold-starts a leaf-worker that leases one of
  the pool pods and runs the agent against `/workspace/<run-id>/repo`
  on that pod.
- **Return.** The leaf's answer comes back as the `.text` field of
  the `/runs/status` response. Files the leaf wrote stay on the
  sandbox pod and do **not** come back to the laptop. If the operator
  wants to see a diff or a test log, the leaf's prompt must ask for it
  as text in the response.

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
  brings up `sandbox-0`.
- The KEDA ScaledJob for leaf workers applied once from the MOCA repo:

  ```bash
  kubectl apply -f deploy/knative/leaf-scaledjob.yaml
  ```

  Without it, `POST /runs` is accepted but no worker pod ever starts and
  `GET /runs/status` hangs forever. The ScaledJob does not survive a
  `kind delete`, so re-apply on a fresh cluster.
- `kubectl` configured for that cluster.
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
- `SCALEDJOB_NAME` — KEDA ScaledJob name (default `leaf-worker`).
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
   `.moca-runs/<run-id>-<leaf-label>.json` and returns control to you
   with the sessionId. The leaf is now running on the cluster; this
   turn is over.

**Prompt 2 — collect the diagnosis.** When you're ready (seconds to
minutes later, same session or a resumed one):

> Check on that subagent and report the diagnosis.

Claude runs `moca check <session-id>`, which polls `/runs/status`,
writes the completed body to `.result.json`, and prints the leaf's
`.text` to stdout for Claude to surface to you.

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

You should see `leaf-worker-*` pods cold-start, run, and drop to
`Completed`. That's the MOCA-value visual.

## Pause and resume

Because dispatch is async, you can quit Claude any time after a
dispatch has written its record file in `.moca-runs/`. The leaf keeps
running on the cluster.

To resume: just start Claude again from the scratch dir
(`cd ~/tmp/moca-chained-scratch && claude`). On the next turn, ask
Claude to check for pending runs:

> Any subagents still pending from an earlier session?

Claude reads `.moca-runs/`, finds records with `status: "pending"`,
and polls `/runs/status` for each. Completed results get written
alongside; still-pending ones stay pending.

The scratch dir **is** the resumable state. Everything needed to pick
up a dropped session — settings, skill, pending run records,
completed results — is in it. Nothing lives in `$HOME` or in the
Claude Code session identifier.

**Caveats.**

- MOCA has its own idea of how long to retain a completed run before
  the result goes away. If you quit for long enough that the leaf's
  result ages out of MOCA, a later poll will come back 404 and the
  skill will mark the record `failed`. The exact TTL depends on your
  MOCA install.
- Async is only available on **unauthenticated** MOCA deployments. If
  your install has auth on, `POST /runs` will return 401/403 and the
  skill will stop and tell you. There is no graceful fallback to sync
  in this demo — if your deployment is sync-only, dispatching
  effectively blocks the turn and Ctrl-C discards the result.

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
  enabled; async dispatch is not available. See the "async only on
  unauthenticated deployments" caveat under Pause and resume.
- **`503 Retry-After` from `/runs`.** MOCA's sandbox pool is saturated.
  Wait or scale.
- **`GET /runs/status` returns 404 for a pending record.** The leaf's
  result aged out of MOCA (or MOCA was restarted). The skill marks
  the record `failed`. Re-dispatch if you still want the work done.
- **`.moca-runs/` has records that never seem to complete.** Check
  `kubectl -n default get pods` — if there's no `leaf-worker-*` pod
  for the sessionId, MOCA may have never scheduled it, or it crashed
  before reporting. Delete the stale record file after confirming no
  leaf is running.
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
bin/moca                   Small CLI the skill shells out to (start / check / list)
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
│   └── moca                       CLI the skill invokes; wraps POST /runs and GET /runs/status
├── .moca-runs/                    Run records (and *.prompt.txt / *.result.json siblings)
└── MOCA.md                        Base URL, host header, run-id, workspace path for this session
```
