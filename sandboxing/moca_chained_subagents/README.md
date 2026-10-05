# Local Claude Code driving chained MOCA subagents

Claude Code runs on your laptop. It has **no built-in subagent tool** —
`Task` is denied in `.claude/settings.json`. To delegate, it uses a
skill that knows how to dispatch an isolated leaf to
[MOCA](https://github.com/rossoctl/serverless-harness) over HTTP.

The orchestration shape is the **operator's**, not the skill's. For
this demo the operator issues two prompts in sequence:

1. First prompt: *"Diagnose the failing test in `example_repo`."* The
   parent dispatches a leaf against the read-only workload; the leaf
   reads the fixture and reports a diagnosis. The parent surfaces that
   diagnosis to the operator and stops.
2. Second prompt: *"Apply that fix."* The parent dispatches a second
   leaf against the read-write workload with the diagnosis from step
   1 embedded in its prompt; the leaf edits the fixture, runs the
   tests, and reports the diff and outcome.

MOCA does not know about the chain; from its perspective each leaf is
an independent `/runs` call that scales to zero when it's done. The
skill does not know about the chain either — it describes how to
dispatch one leaf, and the model composes multi-leaf flows from the
operator's requests.

For the full design, see [PLAN.md](PLAN.md).

## How it works

Three pieces cooperate:

1. **A skill (`moca-dispatch`)** — the mechanism contract. Tells
   Claude how to shape the `/runs` HTTP call, which workloads exist in
   this scratch dir and their mount posture, and how to extract
   `.text` from the response. Does **not** prescribe how many leaves
   to run or in what order — that comes from the operator's prompts.
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

Each `/runs` call is synchronous — the response body contains the leaf's
answer. No polling, no `kubectl exec`, no PVC read-back.

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

The demo flow is **two operator prompts, in sequence**. The skill does
not know about the two steps; the operator drives them.

**Prompt 1 — diagnose.** Paste something like:

> There's a Node.js project in `example_repo` on MOCA. Dispatch a
> subagent against the read-only workload to diagnose why its tests
> are failing. Report the subagent's diagnosis back to me — don't fix
> anything yet.

Claude should:

1. Read the `moca-dispatch` skill.
2. **Not** invoke `Task` — if it tries, the deny fires and it
   re-routes through the skill.
3. Issue one `curl` to `/runs` targeting `workload-a` with a diagnosis
   prompt the model composes from your request. The permission prompt
   literally shows the curl command — this is your visual proof the
   leaf is being dispatched to MOCA, not run in-process.
4. Receive the leaf's diagnosis as `.text` on the response body and
   report it to you.

**Prompt 2 — fix.** After reviewing the diagnosis, paste something
like:

> Good. Now dispatch another subagent against the read-write workload
> to apply that fix, run the tests, and report the diff and outcome.

Claude should dispatch a second `curl` to `/runs` targeting
`workload-b`, embedding the diagnosis from the previous turn in the
new leaf's prompt, and report the diff and test outcome.

If you'd rather issue a single-prompt variant ("diagnose and fix"),
that also works — Claude will dispatch two leaves in sequence within
one turn. The two-prompt split is what shows the chain visibly to the
operator, which is the point of the demo.

While the leaves run, in another terminal:

```bash
kubectl -n moca-system get pods -w
```

You should see leaf pods from both workloads cold-start, run, and drop
to zero. That's the MOCA-value visual.

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
- **`503 Retry-After` from `/runs`.** MOCA's sandbox pool is saturated.
  Wait or scale.
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
settings.json.example      Permission policy: denies Task, allows the /runs curl
setup.sh                   Publishes fixture, creates workloads, stages scratch
teardown.sh                Deletes workloads, contexts, scratch
lib/ctx.sh                 kubectl-only shim that mirrors contextctl verbs
example_repo/              Vendored fixture — Node.js project with a renamed-API bug
```
