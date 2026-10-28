# Local coding agent driving chained MOCA subagents

A local coding agent (**Claude Code** or **OpenCode** — pick one with
`PARENT=claude|opencode`) runs on your laptop and has no built-in way
to offload work to the cloud. Its in-process subagent tool (`Task` for
Claude, `task` for OpenCode) runs in the same session. This demo
**denies that tool** and delegates instead through a skill that
dispatches an isolated leaf to [MOCA](https://github.com/rossoctl/moca)
via the official client **`mocactl`**.

The pedagogical point is that the choice of parent agent is the
**operator's**, and the delegation seam is the same regardless. The
same `moca-delegate-task` skill, the same `mocactl` commands, the same
four operator prompts work for both. What differs is only the parent
agent's config dir name and format — see the
[parent-agent differences](#parent-agent-differences) table.

The orchestration shape is the **operator's**, not the skill's. For
this demo the operator issues prompts in sequence:

1. *"Dispatch a subagent to diagnose the failing test."* The parent
   packs the scratch dir, creates a workload, spawns a leaf against
   it, and returns. Operator can walk away.
2. Later: *"Check on that subagent and report the diagnosis."* The
   parent collects the result and surfaces the diagnosis.
3. *"Dispatch a fixer with that diagnosis."* Repeat the pattern, this
   time with a `--mount writable` workload so the fix leaf can edit
   and test.

MOCA does not know about the chain; from its perspective each leaf is
an independent, self-contained session. The skill does not know about
the chain either — it describes how to dispatch and collect one leaf,
and the model composes multi-leaf flows from the operator's requests.

## How state flows

Four pieces cooperate:

1. **The `moca-delegate-task` skill** — upstream MOCA's delegation
   skill, staged verbatim from `<moca>/skills/moca-delegate-task/`.
   Tells the parent agent how to pack, dispatch, and collect one
   leaf: pack to `.moca-delegate/repo.context`, dispatch with
   `mocactl spawn`, collect with `mocactl get --out results/`, delete
   the workload, remove `.moca-delegate/`. Chaining and demo-specific
   details (pack `.`, tag every spawn `moca-chained-subagents-demo`)
   come from the operator's prompts, not the skill.
2. **`mocactl`** — the official MOCA client on your `PATH`. Owns all
   auth in `~/.config/mocactl`. Provides `spawn` / `get` / `subagents`
   for sessions, `workloads create / get / delete` for the per-leaf
   context-service bundle, and `promote` / `bundles delete` for config
   bundles.
3. **Two promoted config bundles** — `bundles/public-only/` and
   `bundles/full/`, each a `.claude/skills/` tree uploaded by `mocactl
   promote` as a sha256-pinned bundle. Diagnose dispatches with
   public-only; fix with full. Setup writes both digests to `MOCA.md`;
   teardown deletes them.
4. **A denied in-process subagent tool** — the parent agent's config
   (`.claude/settings.json` for Claude, `.opencode/opencode.jsonc` for
   OpenCode) denies the built-in subagent (`Task` / `task`), forcing
   the model through the skill. Each `mocactl spawn` permission prompt
   is the operator's visual confirmation that work is going to MOCA,
   not running locally.

Per-leaf lifecycle: pack cwd → `workloads create` →
`mocactl spawn … --config $DIGEST --workload $WID --tag
moca-chained-subagents-demo --label <label>` → **stop**. The server
runs the leaf to completion and stores the result before responding,
so there is no client-disconnect abort; results live server-side for
24h. The parent collects with `mocactl get <sid> --out results` and
then deletes the workload, which reaps its StatefulSet and PVC.

Tracking state lives on the mocactl ledger (`mocactl subagents --tag
moca-chained-subagents-demo --json` reads back label, sessionId,
workloadId, bundle digest, state), not in the scratch dir — a
resumed parent-agent session reconstructs the chain from the ledger
alone.

## Prerequisites

### Tools on your PATH

- `kind` ≥ 0.24.0 serving Kubernetes 1.30+ (ValidatingAdmissionPolicy
  is required by the workload provisioner, and NetworkPolicy-enforcing
  CNI is a hard requirement: sandbox isolation **is** NetworkPolicy).
  `kubectl`, `docker` (or podman's `docker` CLI), `jq`, and your choice
  of parent coding agent CLI on PATH: `claude` (Claude Code) or
  `opencode` (OpenCode 1.19.x+ — tested on 1.19.4).
- [`mocactl`](https://github.com/rossoctl/moca/tree/main/packages/mocactl)
  (Node 22+), with the `workloads` subcommand and the flags `--label`,
  `--sandboxes`, `--prompt-file`:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/rossoctl/moca/main/scripts/install-mocactl.sh | MOCACTL_VERSION=edge sh
  ```
  `./setup.sh` probes all four and refuses to run on an older build.
  Tested against `edge-4206293`; pin with
  `MOCACTL_VERSION=edge-4206293` if a newer edge regresses.
- [`contextctl`](https://github.com/rossoctl/context-service) v0.3.0+
  with the `ctx pack` subcommand (build from main — `make build` — until
  a release ships). The upstream `moca-delegate-task` skill assumes
  v0.3.0+ auto-skips `.claude/` and `.gitignore`'d files; verify with
  `contextctl ctx pack --help | grep -q no-ignore`. `make build` writes
  to `<context-service>/bin/contextctl`; put that on `PATH`.

### Checkouts

Clone MOCA and Context Service side-by-side. MOCA needs submodules:

```bash
git clone --recurse-submodules https://github.com/rossoctl/moca
git clone https://github.com/rossoctl/context-service
```

Set `CLONE_DIR` to the parent of both checkouts. The install script and
`./setup.sh` both read it; MOCA is expected at `$CLONE_DIR/moca` and
Context Service at `$CLONE_DIR/context-service`. Required — there is no
default.

### Install the cluster-side pieces

```bash
SH_GITHUB_CLIENT_ID=<your-oauth-client-id> \
CLONE_DIR=<parent-of-both-checkouts> \
  ./prereqs-install.sh
```

The script creates a kind cluster `moca`, runs MOCA's `deploy/k8s/setup.sh`
with `SH_WORKLOAD_SANDBOXES=1` (installs `moca-provisioner` and the
`moca-sandbox` namespace it manages) and
`SH_PUBLIC_HARNESS_URL=http://127.0.0.1:${HARNESS_PORT}` (so the control
plane advertises the demo's port-forward), builds and loads the
context-service image, wires the two together, and backgrounds the three
port-forwards the demo needs (logs under
`~/.local/state/moca-chained-demo/`). Re-runnable on a *clean* cluster:
a partially-completed prior run leaves namespaces behind, and
`kubectl apply` on the manifest then fails with
`namespaces "moca-credentials" already exists`. If that happens, run
`./prereqs-uninstall.sh` (or `kind delete cluster --name moca`) before
re-running. Three things it fixes along the way worth knowing about:

- **Flaky pod DNS on podman.** The Podman-network resolv.conf often
  points at an unreachable IPv6 nameserver first; the script points
  CoreDNS at `1.1.1.1` / `8.8.8.8` to work around it.
- **Context Service image is private.** `ghcr.io/rossoctl/context-service:latest`
  returns 403 anonymously; the script builds locally and loads with
  `kind load docker-image`.
- **Namespace mismatch.** Context Service's upstream manifest ships
  `namespace: serverless-harness`, but MOCA's supervisor egress NetworkPolicy
  only allows the namespace literally named `context-service`. The script
  rewrites the namespace before `kubectl apply`.

The `moca-context-service` Secret's `token` key is required by MOCA but
not currently enforced by Context Service — the script uses a placeholder.
Rotate it once trusted-route auth lands upstream.

### Port-forwards

`prereqs-install.sh` backgrounds the three port-forwards itself —
`moca-supervisor` on `127.0.0.1:${HARNESS_PORT:-18080}`,
`moca-control-plane` on `${CP_PORT:-18090}`, `context-service` on
`${CS_PORT:-19090}`. Logs live at `~/.local/state/moca-chained-demo/`.
Override by exporting those env vars before running
`./prereqs-install.sh` and `./setup.sh`; the control plane is told the
chosen harness port via `SH_PUBLIC_HARNESS_URL`, and the
`moca-context-service` ConfigMap's `public-url` matches `CS_PORT`.

To restart them, re-run `./prereqs-install.sh` (it kills stale
port-forwards against `kind-moca` before relaunching). To kill them
along with the cluster, use `./prereqs-uninstall.sh`.

### Log in (once per machine)

```bash
export SH_CONTROL_PLANE_URL=http://127.0.0.1:18090
mocactl login
# ANTHROPIC_BASE_URL points at an Anthropic-compatible endpoint (e.g. a
# LiteLLM gateway); ANTHROPIC_AUTH_TOKEN is the bearer token for it.
printf %s "$ANTHROPIC_AUTH_TOKEN" | mocactl credentials add anthropic \
  --host "$(printf %s "$ANTHROPIC_BASE_URL" | awk -F/ '{print $3}')" --kind bearer \
  --endpoint "$ANTHROPIC_BASE_URL"
mocactl doctor
```

`--kind bearer` is required for Anthropic-compatible proxies that expect
`Authorization: Bearer` (`--kind api-key` is only validated against
`api.anthropic.com`). To talk directly to `api.anthropic.com` with an
`ANTHROPIC_API_KEY`, swap in `--host api.anthropic.com --kind api-key
--endpoint https://api.anthropic.com` and pipe `$ANTHROPIC_API_KEY`.

`mocactl doctor` must go all-green before `./setup.sh`.

## Setup

From this directory:

```bash
./setup.sh                  # Claude Code (default)
PARENT=opencode ./setup.sh  # OpenCode
```

This:

1. Verifies the tooling (`kubectl`, `jq`, `contextctl`, `mocactl` —
   including probes that `mocactl` has the `workloads` subcommand and
   the flags the demo uses: `--label`, `--sandboxes`, `--prompt-file`)
   and that the `moca` namespace exists.
2. Runs `mocactl doctor` against the port-forwards — reachability,
   login, credential, harness, and an end-to-end scratch session.
3. Stages the scratch dir at `~/tmp/moca-chained-scratch/` **as the
   project**: the fixture flattens into the scratch root alongside the
   parent agent's config (`.claude/settings.json` for Claude Code —
   port-forward URLs injected natively via `env`; `.opencode/opencode.jsonc`
   plus a `run-opencode.sh` wrapper for OpenCode — URLs exported by the
   wrapper), the `moca-delegate-task` skill (upstream SKILL.md,
   verbatim), and a `.gitignore` excluding `MOCA.md`, `.moca-delegate/`,
   and `results/` so `contextctl ctx pack .` captures only the project.
   The two port-forward URLs are recorded in `MOCA.md` and printed by
   `setup.sh` for by-hand shells.

Setup creates **no workload, no session, and seeds nothing per pod** —
the agent packs the scratch dir and runs `mocactl workloads create
--sandboxes 1 --mount read-only|writable` at dispatch (per leaf). Each
workload gets its own sandbox pod and PVC under `moca-sandbox`, seeded
from the frozen revision; `mocactl spawn --workload <id>` creates the
session. The agent deletes the workload after collecting the result.

Environment overrides (set before running):

- `PARENT` — parent coding agent to stage config for: `claude`
  (default) or `opencode`.
- `MOCA_NS` — namespace (default `moca`).
- `HARNESS_PORT` / `CP_PORT` / `CS_PORT` — local port-forward ports
  (default `18080` / `18090` / `19090`). `prereqs-install.sh` passes
  `SH_PUBLIC_HARNESS_URL=http://127.0.0.1:${HARNESS_PORT}` to MOCA's
  `deploy/k8s/setup.sh` so the control plane advertises the chosen
  port. If you override, set the same env vars before running
  `./prereqs-install.sh` and `./setup.sh`.
- `SCRATCH_DIR` — scratch dir path.

> **Re-running setup discards the previous scratch dir.** The demo tag
> is a constant (`moca-chained-subagents-demo`), so `mocactl subagents
> --tag` after a re-run will show both old and new leaves until
> teardown. Collect any results you care about first, and let the
> agent delete any still-live workloads (or run `./teardown.sh` first
> — it reconciles leftover workloads from `mocactl subagents --json`).

## Run a session

Claude Code:

```bash
cd ~/tmp/moca-chained-scratch && claude
```

OpenCode — the wrapper exports `SH_CONTROL_PLANE_URL` /
`SH_HARNESS_URL` into the session (OpenCode has no `settings.json`
`env` equivalent):

```bash
~/tmp/moca-chained-scratch/run-opencode.sh
```

In a side terminal, export the port-forward URLs so `mocactl` can
reach MOCA (also printed by `setup.sh`):

```bash
cd ~/tmp/moca-chained-scratch
export SH_CONTROL_PLANE_URL=http://127.0.0.1:18090
export SH_HARNESS_URL=http://127.0.0.1:18080
```

**Prompt 1 — start the diagnosis.** Paste something like:

> Dispatch a diagnose subagent on its own read-only sandbox
> (`--sandboxes 1 --mount read-only`). Config: `$DIGEST_PUBLIC` (from
> `MOCA.md`), tag `moca-chained-subagents-demo`, label `diagnose`.
> Have the leaf use its `public-research` skill. End the turn after
> `mocactl spawn` — do not call `get`, `subagents`, or `sleep`.

The parent agent re-routes through `moca-delegate-task` (the deny
on its in-process subagent tool fires first) and follows the skill:
pack, workload-create, `mocactl spawn`. Each permission prompt shows
a legible dispatch command.

*Peek at state:* look up the workload from the ledger and watch it
transition:

```bash
WLID=$(mocactl subagents --tag moca-chained-subagents-demo --json \
  | jq -r '[.subagents[] | select(.label=="diagnose")] | sort_by(.submittedAt) | last | .workload')
mocactl workloads get "$WLID" --json | jq '{status,contextType,revision}'
```

`status` progresses `creating → awaiting_upload → ready`; `revision`
is the sha256 of the files.

*Peek at the per-workload pod and PVC:* `mocactl workloads create`
blocks for ~tens of seconds while the provisioner creates the
StatefulSet, seeds the PVC from the frozen revision, and the pod
attaches. During and after that window, in a side terminal:

```bash
kubectl -n moca-sandbox get pods,pvc,sts
```

Expect one pod + one PVC + one StatefulSet per live workload (plus the
shared pool). All disappear when `mocactl workloads delete` runs.

*Optional durability beat.* To show the server owns the result,
quit the parent agent and relaunch it (`claude` or
`./run-opencode.sh`) before prompt 2 — the fresh session re-discovers
the chain from `mocactl subagents --tag moca-chained-subagents-demo
--json`. See [§ Pause and resume](#pause-and-resume).

**Prompt 2 — collect the diagnosis.** When you're ready (seconds to
hours later, same session or a resumed one):

> Check on that subagent and report the diagnosis.

The agent looks up the diagnose leaf's handles from `mocactl
subagents --tag moca-chained-subagents-demo --json` (filtering by
`.label=="diagnose"`), runs `mocactl get <sessionId> --out results
--json`, and branches on `status`: `queued` → "still running", stop;
`responded` → read `results/<sessionId>.text`, surface the diagnosis,
run `mocactl workloads delete "$WORKLOAD_ID"`.

*Peek at state:* same handles, from the operator's shell:

```bash
SID=$(mocactl subagents --tag moca-chained-subagents-demo --json \
  | jq -r '[.subagents[] | select(.label=="diagnose")] | sort_by(.submittedAt) | last | .sessionId')
mocactl get "$SID" --json | jq .
```

`status` progresses `queued → responded` (or `failed` / `paused`).

**Prompt 3 — start the fix.** After reviewing the diagnosis:

> Dispatch a fix subagent on its own writable sandbox (`--sandboxes 1
> --mount writable`). Config: `$DIGEST_FULL` (from `MOCA.md`), tag
> `moca-chained-subagents-demo`, label `fix`. Have the leaf use its
> `full-access-fix` skill, with the previous diagnosis verbatim as its
> prompt (use `--prompt-file` if your shell refuses the inline form).
> End the turn after `mocactl spawn` — do not call `get`, `subagents`,
> or `sleep`.

The fix leaf runs on its own writable-mount workload; edits land on
that PVC.

**Prompt 4 — collect the fix result.**

> Check on it.

The agent collects the fix leaf (filtering ledger by
`.label=="fix"`), surfaces the change and test outcome (`Ran 1 test /
OK`), then deletes the workload. Each leaf is a separate session;
between them, only prompt text flows (via `--prompt-file`).

### Observe the chain

The tag is stable across runs, so `mocactl subagents --tag` shows
every dispatch under it ever. For just the current run (newest
diagnose + anything after), filter by `submittedAt`:

```bash
TAG=moca-chained-subagents-demo
mocactl subagents --tag "$TAG" --json | jq '
  .subagents
  | [.[] | select(.label=="diagnose")] as $diag
  | ($diag | sort_by(.submittedAt) | last | .submittedAt) as $start
  | map(select(.submittedAt >= $start))
'
```

Each row's `bundle` shows which posture that dispatch booted with
(`$DIGEST_PUBLIC` for diagnose, `$DIGEST_FULL` for fix) — the chain's
trust boundary is sha256-pinned, not operator-trust. The demo tag is
operator-side (scopes `subagents --tag` and teardown), not a
server-side identity.

While leaves run, in another terminal:

```bash
kubectl -n moca get pods
kubectl -n moca logs -f deploy/moca-supervisor
```

The supervisor and sandbox pods are **warm** — the work lands in a
sandbox pod your laptop never touches. Control plane and supervisor
emit one JSON audit line per lifecycle event (identifiers only — no
prompt text, file contents, or credentials); grep by sessionId:

```bash
SID=$(mocactl subagents --tag moca-chained-subagents-demo --json \
  | jq -r '[.subagents[] | select(.label=="diagnose")] | sort_by(.submittedAt) | last | .sessionId')
kubectl --context kind-moca -n moca logs deploy/moca-supervisor | \
  jq -c -R "fromjson? | select(.event==\"audit\" and .sessionId==\"$SID\")"
```

Context Service and sandbox pods don't surface per-request detail;
the only transcript-shaped artifact is the subagent's final message
(`results/<sid>.text`), which is why the `full-access-fix` skill
requires verbatim test output in the final report.

## Pause and resume

Because the server completes the run and stores the result before
responding — with no client-disconnect abort — you can quit the
parent agent any time after a dispatch. Nothing local is holding the
leaf open (the detached worker dies with your login session; the
server doesn't care).

To resume: relaunch the parent agent from the scratch dir
(`claude` or `./run-opencode.sh`) and continue the flow — the next
operator prompt (e.g. prompt 2 if you paused after prompt 1) picks up
from the ledger. The parent agent runs `mocactl subagents --tag
moca-chained-subagents-demo --json` to find the leaf and `mocactl get`
to collect; nothing extra is needed.

If you want an explicit inventory check first (useful when you've lost
track of where you are), ask:

> Any subagents still pending from an earlier session?

The agent reads the ledger (each row carries label, sessionId,
workloadId, bundle digest, state) and tells you what's live without
collecting.

To verify from the operator shell directly (readable form):

```bash
mocactl subagents --tag moca-chained-subagents-demo --json | jq .
```

The machine-global mocactl ledger **is** the resumable state;
nothing lives in the parent agent's session identifier.

**What survives and what doesn't:**

| Event | Result collectable? |
| --- | --- |
| Quit the parent agent | Yes |
| Reboot the laptop | Yes — the worker dies, the server finishes the run |
| Wait up to 24h | Yes (server-side result TTL) |
| Wait past 24h | No — the stored result is gone |
| Port-forwards down mid-leaf | Yes — the leaf still completes; restore the port-forward to collect |
| Supervisor restarts mid-leaf | Yes within ~30–100 s — the server reaps the orphan as `failed` / `owner_lost`; re-dispatch under a fresh `--label` |
| Sandbox pod killed mid-leaf | Eventually (minutes) — session reconnects and the leaf reports the mount is gone; re-dispatch |
| `./teardown.sh` | No — deletes the sessions and any leftover workloads |

**Caveats.**

- **The 24h TTL is the only deadline.** `/v1/runs` leaves are not
  swept for inactivity — there is no "unwatched" abort anymore — but
  the stored result expires after 24h regardless of whether it was
  collected.
- **`unknown` is an infrastructure outcome, not a finding.** It means
  the worker died before the server recorded anything (port-forward
  down at dispatch). A supervisor restart mid-run is now reaped as
  `failed` / `owner_lost` within ~30–100 s, not `unknown`. Either way,
  re-dispatch under a fresh `--label`.
- **A leaf that runs longer than five minutes looks failed locally.**
  The spawn worker's sync `POST /v1/runs` carries Node's default
  300-second response timeout, so `subagents` records
  `failed: fetch failed` at the five-minute mark while the run keeps
  going server-side — and stays collectable with `get`. Trust `get`,
  not the ledger state.
- **`teardown.sh` makes stored results unreachable.** It deletes
  this tag's sessions (and any live workloads). Collect what you
  care about first.

## Teardown

```bash
./teardown.sh
```

This deletes every leaf session of this demo's tag
(`mocactl subagents --tag` → `mocactl sessions delete` for each),
deletes any workloads still live from the ledger (normally none —
the agent deletes each workload after collecting its leaf's result),
and removes the scratch directory. It does **not** touch MOCA, Context
Service, your cluster, your `mocactl` login, or the backgrounded
port-forwards. For a full tear-down (demo state + port-forwards + kind
cluster), see `./prereqs-uninstall.sh` below.

## Full uninstall

```bash
./prereqs-uninstall.sh
```

Runs `teardown.sh`, kills the three backgrounded port-forwards (matched
by argv on `kubectl --context kind-moca ... port-forward`), and deletes
the kind cluster `moca` — which takes MOCA, Context Service, loaded
images, the CoreDNS patch, and all namespaces with it in one call. Does
**not** touch your `mocactl` login + credentials or the two source
checkouts; those are yours.

## Parent-agent differences

Both Claude Code and OpenCode drive the same `moca-delegate-task`
skill, same `mocactl` commands, same four operator prompts. Only the
parent-side config dir, config file, and env-injection mechanism
differ:

| Dimension | Claude Code | OpenCode |
| --- | --- | --- |
| Config dir | `.claude/` | `.opencode/` |
| Config file | `settings.json` (jq-merged by setup.sh) | `opencode.jsonc` (cp'd by setup.sh) |
| In-process subagent to deny | `Task` | `task` |
| Env injection | native (`settings.json` `env` key) | wrapper (`run-opencode.sh` exports then execs) |
| Project-level instructions | `CLAUDE.md` (not shipped — operator prompts carry the discipline) | `AGENTS.md` (not shipped — same shape) |
| Tested version | current Claude Code | 1.19.4 |

## Troubleshooting

Known failure modes, how to inspect state in the sandbox, and the
by-hand version of the flow (useful when the agent is stuck or when
verifying the mechanics from a plain terminal) live in
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## Security note

This demo runs against a throwaway local cluster. MOCA's own auth is
enabled, so leaves require a valid login — and the demo itself now
stores **no secret anywhere**: tokens live in mocactl's own config
dir (`~/.config/mocactl`), outside the demo, and setup no longer
modifies any cluster-wide setting. Still: don't point it at anything
you care about.

Each workload gets its own StatefulSet and PVC under the
`moca-sandbox` namespace, so two users' workloads do not share a
sandbox. Writes stay on the workload's PVC until the workload is
deleted. The provisioner holds the RBAC in that namespace; the control
plane and the harness do not.

## Files in this directory

```
README.md                  This file
TROUBLESHOOTING.md         Known failure modes, how to inspect sandbox state, and the
                           by-hand flow (acceptance test + fallback when the agent is stuck)
ARCHITECTURE.md            Components, dispatch/collect sequence, trust boundaries
prereqs-install.sh         Stands up MOCA + Context Service on a local kind cluster and
                           backgrounds the three port-forwards; see Prerequisites
prereqs-uninstall.sh       Runs teardown.sh, kills the port-forwards, deletes the kind cluster
setup.sh                   Verifies prereqs via mocactl doctor, stages the scratch dir
                           (parent-aware), and promotes the two config bundles
teardown.sh                Deletes the demo's leaf sessions, any leftover workloads, and
                           the two config bundles; removes the scratch dir
parents/                   Parent-agent-specific config staged by setup.sh:
  claude/settings.json.example      Claude Code permission policy + env injection
  opencode/opencode.jsonc.example   OpenCode permission policy
  opencode/run-opencode.sh.in       Launcher template — renders to run-opencode.sh with
                                    port-forward URLs substituted at setup time
example_repo/              The project the demo exercises — a stdlib-only Python project
                           with a renamed-API bug. Its contents flatten into the scratch
                           dir at setup time, so the parent's cwd IS the project; the
                           parent packs that cwd at each dispatch.
bundles/                   Two config bundles promoted at setup time: `public-only/`
                           (public-posture skill for the diagnose leaf) and `full/`
                           (full-access skill for the fix leaf). Each is a `.claude/skills/`
                           directory tree passed to `mocactl promote` and referenced by
                           sha256 digest at dispatch. The directory name is historical —
                           both parent agents consume the same bundle format.
```

In the scratch dir after `setup.sh` (Claude Code):

```
~/tmp/moca-chained-scratch/   The fixture is copied here so the parent's cwd is the project to pack.
├── .claude/
│   ├── settings.json      Permission policy + port-forward env for mocactl
│   └── skills/
│       └── moca-delegate-task/SKILL.md   Upstream SKILL.md, verbatim
├── .git/                  So `.gitignore` is honored by `contextctl ctx pack`
├── .gitignore             Keeps MOCA.md, .moca-delegate/, results/ out of each leaf's workload
├── MOCA.md                Written by setup.sh — the two promoted config digests + run facts
├── README.md src/ tests/ vendor/ docs/   The fixture, at the scratch root
├── .moca-delegate/        Created per leaf by the agent — holds the packed .context (and prompt file for --prompt-file); removed after dispatch
└── results/               Created by the agent on `mocactl get --out results` — holds <sid>.text per collected leaf
```

With `PARENT=opencode`: `.claude/` is replaced by `.opencode/opencode.jsonc`
and `.opencode/skills/moca-delegate-task/SKILL.md`, and a `run-opencode.sh`
wrapper is added at the scratch root. Both are listed in `.gitignore` so
`contextctl ctx pack .` keeps them out of each leaf's workload.
