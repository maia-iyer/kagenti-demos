# Local Claude Code driving chained MOCA subagents

Claude Code runs on your laptop. It has **no built-in subagent tool** —
`Task` is denied in `.claude/settings.json`. To delegate, it uses a
skill that knows how to dispatch an isolated leaf to
[MOCA](https://github.com/rossoctl/serverless-harness) over HTTP.

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
   starts a leaf against the read-only workload and returns the run
   handle. Operator can walk away.
2. Later: *"Check on that subagent and report the diagnosis."* The
   parent polls `/runs/status`, writes the result, surfaces the
   diagnosis.
3. *"Dispatch a fixer against the read-write workload with that
   diagnosis."* Repeat the pattern.

MOCA does not know about the chain; from its perspective each leaf is
an independent `/runs` call that scales to zero when it's done. The
skill does not know about the chain either — it describes how to
start and collect one leaf, and the model composes multi-leaf flows
from the operator's requests.

For the full design, see [PLAN.md](PLAN.md).

## How it works

Three pieces cooperate:

1. **A skill (`moca-dispatch`)** — the mechanism contract. Tells
   Claude how to shape the `POST /runs` and `GET /runs/status` calls,
   which workloads exist in this scratch dir and their mount posture,
   how to write and read run records in `.moca-runs/`, and how to
   extract `.text` from a completed result. Does **not** prescribe
   how many leaves to run or in what order — that comes from the
   operator's prompts.
2. **A denied `Task` tool** — `.claude/settings.json` denies the
   built-in subagent tool, so the model has to route through the skill
   instead of forking in-process. The permission prompt on each `curl`
   is the operator's visual confirmation that the leaf is being
   dispatched to MOCA, not run locally.
3. **Pre-provisioned MOCA workloads** — `setup.sh` creates a PVC in
   the MOCA namespace, copies `example_repo/` into it via a
   short-lived loader pod, then creates two MOCA workloads bound to
   that PVC: `workload-a` (read-only) for the researcher, `workload-b`
   (read-write) for the fixer. The skill only dispatches runs; it
   never touches the PVC or `/workloads` at runtime.

   The workspace-publishing step is factored through
   [`lib/ctx.sh`](lib/ctx.sh) — a thin `kubectl`-only shim whose
   functions mirror the subset of `contextctl` verbs this demo would
   otherwise use (`ctx create`, `ctx artifact publish`,
   `ctx sync push`, `ctx get`, `ctx delete`). If you later get
   `contextctl` working in your environment, swap the function bodies
   in `lib/ctx.sh` for `contextctl` invocations — the call sites in
   `setup.sh` / `teardown.sh` do not change.

`POST /runs` returns a run handle immediately; the leaf's answer is
collected via `GET /runs/status?sessionId=…` on a later turn. Run
records live in `.moca-runs/` in the scratch dir — one JSON file per
dispatched leaf. A resumed Claude session finds in-flight work by
reading that directory.

## How state flows

- **Setup time.** `setup.sh` provisions a PVC in the MOCA namespace,
  copies `example_repo/` into it via a short-lived loader pod, then
  `POST`s to `/workloads` to register `workload-a` (read-only) and
  `workload-b` (read-write) against that PVC. The fixture is
  cluster-side before Claude ever starts.
- **Dispatch.** The only state going from the laptop to MOCA at
  dispatch time is the prompt text (plus the sessionId and workload
  name). The parent embeds any output from prior leaves into the next
  leaf's prompt as plain text; there is no shared memory between
  leaves.
- **Execution.** MOCA cold-starts a leaf pod in the chosen workload.
  The pod mounts the PVC at `/workspace` with the workload's
  `readOnly` setting. Any files the leaf writes land on the PVC (if
  the mount allows) and stay there.
- **Return.** The leaf's answer comes back as the `.text` field of
  the `/runs/status` response. Files on the PVC do **not** come back
  to the laptop. If the operator wants to see a diff or a test log,
  the leaf's prompt must ask for it as text in the response.

## What's honest and what isn't

- **A's read-only workspace is substrate-enforced.** The Context Service
  PVC is mounted with `readOnly: true` on `workload-a`, so A physically
  cannot modify `/workspace` — writes fail at the filesystem. You can
  verify this directly: while an A leaf is live,
  `kubectl exec` in and `touch /workspace/x` → `Read-only file system`.

- **The researcher's "no exec / no network" is prompt-only.** MOCA
  today gives every leaf the same seven tools (`read, write, edit,
  ls, find, bash, grep`) and has no web-fetch tool at all. There is
  no per-leaf `tools` allowlist on `LeafEnvelope`. The operator's
  diagnosis prompt says "do not run shell commands"; a non-compliant
  leaf could. Honest substrate-enforced capability splits would need
  an upstream `tools` field, which is out of scope for this demo.

- **The fixer needs a writable workspace.** `workload-b` mounts the
  same PVC read-write so a fixer leaf can apply the fix and run the
  tests. Both workloads see the same `example_repo/` tree.

- **Chaining is parent-side.** MOCA has no "on complete, trigger X"
  primitive; the parent Claude session does the sequencing between
  the operator's two prompts. The skill does not encode the chain
  either — the operator's two prompts and the parent's judgment do.

## Prerequisites

- A kind (or any) cluster with
  [MOCA](https://github.com/rossoctl/serverless-harness) deployed. Follow
  MOCA's own `setup-kind.sh` or equivalent.
- `kubectl` configured for that cluster.
- `curl` and `jq` on your `PATH`.
- Claude Code CLI.

Context Service / `contextctl` is **not** required — `setup.sh` provisions
the workspace PVC directly via `kubectl` through `lib/ctx.sh`. See the
note on the shim under "How it works" above.

MOCA's HTTP service must be reachable from your laptop. In another
terminal:

```bash
kubectl -n moca-system port-forward svc/<harness-svc> 8080:<port>
```

The service name and port depend on your MOCA install — check
`kubectl -n moca-system get svc`.

## Setup

From this directory:

```bash
./setup.sh
```

This:

1. Verifies `kubectl`, `curl`, `jq` are on `PATH` and that MOCA is
   reachable at `http://localhost:8080`.
2. Creates a PVC in the MOCA namespace and copies `example_repo/`
   into it via a short-lived loader pod.
3. Creates `workload-a` (read-only) and `workload-b` (read-write)
   bound to that PVC.
4. Stages `.claude/settings.json` and `.claude/skills/moca-dispatch/`
   into `~/tmp/moca-chained-scratch/`.
5. Writes `WORKLOADS.md` into the scratch dir so the skill has a
   handy reference to the names.

Environment overrides (set before running):

- `MOCA_NS` — MOCA namespace (default `moca-system`).
- `MOCA_PORT` — local port the port-forward uses (default `8080`).
- `WORKLOAD_A` / `WORKLOAD_B` — workload names.
- `SCRATCH_DIR` — scratch dir path.
- `LOADER_IMAGE` — image for the short-lived PVC loader pod
  (default `busybox:1.36`).
- `CTX_STORAGE_CLASS` — PVC storage class (default: cluster default).
- `CTX_PVC_SIZE` — PVC size (default `128Mi`).

## Run a session

```bash
cd ~/tmp/moca-chained-scratch && claude
```

The demo flow is **operator prompts, in sequence**. The skill does
not encode the flow; you drive it.

**Prompt 1 — start the diagnosis.** Paste something like:

> There's a Node.js project in `example_repo` on MOCA. Dispatch a
> subagent against the read-only workload to diagnose why its tests
> are failing.

Claude should:

1. Read the `moca-dispatch` skill.
2. **Not** invoke `Task` — if it tries, the deny fires and it
   re-routes through the skill.
3. Issue one `curl` to `POST /runs` targeting `workload-a` with a
   diagnosis prompt the model composes from your request. The
   permission prompt literally shows the curl command — this is your
   visual proof the leaf is being dispatched to MOCA, not run
   in-process.
4. Write a record file at `.moca-runs/<run-id>-<leaf-label>.json` and
   return control to you with the sessionId. The leaf is now running
   on the cluster; this turn is over.

**Prompt 2 — collect the diagnosis.** When you're ready (seconds to
minutes later, same session or a resumed one):

> Check on that subagent and report the diagnosis.

Claude polls `GET /runs/status?sessionId=…`, writes the completed
result alongside the record, and surfaces `.text` to you.

**Prompt 3 — start the fix.** After reviewing the diagnosis:

> Good. Dispatch another subagent against the read-write workload to
> apply that fix, run the tests, and report the diff and outcome.

Claude dispatches a second leaf against `workload-b`, embedding the
diagnosis from Prompt 2 in the new leaf's prompt. Record is written.
Control returns to you.

**Prompt 4 — collect the fix result.**

> Check on it.

Claude polls, surfaces the diff and test outcome.

While leaves run, in another terminal:

```bash
kubectl -n moca-system get pods -w
```

You should see leaf pods from both workloads cold-start, run, and drop
to zero. That's the MOCA-value visual.

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

## Verify substrate-enforced isolation

While a `workload-a` leaf is still live (or spin one up with a trivial
prompt):

```bash
POD=$(kubectl -n moca-system get pods -l workload=workload-a \
       -o jsonpath='{.items[0].metadata.name}')
kubectl -n moca-system exec "$POD" -- touch /workspace/x
#   touch: cannot touch '/workspace/x': Read-only file system
```

Same command against a `workload-b` pod succeeds. The isolation is in
the mount, not the prompt.

## Teardown

```bash
./teardown.sh
```

This deletes `workload-a`, `workload-b`, the workspace PVC, and the
scratch directory. It does **not** touch MOCA or your cluster. If a
`kubectl port-forward` is still running, `Ctrl-C` it.

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
  `kubectl -n moca-system get pods` — if there's no leaf pod for the
  sessionId, MOCA may have never scheduled it, or it crashed before
  reporting. Delete the stale record file after confirming no leaf
  is running.
- **Claude tries `Task` and gets denied, then stops.** The skill
  wasn't found. Confirm
  `~/tmp/moca-chained-scratch/.claude/skills/moca-dispatch/SKILL.md`
  exists; re-run `./setup.sh` if it doesn't.
- **`POST /workloads` fails with `claimName not found`.** The PVC
  isn't in the MOCA namespace (sync didn't complete, or MOCA watches
  a different namespace). Verify `kubectl -n moca-system get pvc`
  and re-run `./setup.sh`.
- **A fixer leaf reports "Read-only file system" when writing.**
  Either `workload-b` was somehow created with `readOnly: true`, or
  the model dispatched the fixer leaf to `workload-a` by mistake.
  Check which workload was in the curl permission prompt. If the
  workload spec is wrong, run `./teardown.sh && ./setup.sh`.
- **A diagnosis leaf reads a stale version of the fixture.** The PVC
  wasn't re-synced after you edited `example_repo/`. Run
  `./teardown.sh && ./setup.sh` — the shim wipes the PVC contents on
  each `ctx_sync_push`, so re-running setup re-publishes.

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
settings.json.example      Permission policy: denies Task, allows POST /runs and GET /runs/status
setup.sh                   Publishes fixture, creates workloads, stages scratch (incl. .moca-runs/)
teardown.sh                Deletes workloads, PVC, scratch
lib/ctx.sh                 kubectl-only shim that mirrors contextctl verbs
example_repo/              Vendored fixture — Node.js project with a renamed-API bug
```

In the scratch dir after `setup.sh`:

```
~/tmp/moca-chained-scratch/
├── .claude/
│   ├── settings.json              Copied from settings.json.example
│   └── skills/moca-dispatch/      Copied from skill/
├── .moca-runs/                    Run records; one JSON per dispatched leaf
└── WORKLOADS.md                   Names and mount posture of provisioned workloads
```
