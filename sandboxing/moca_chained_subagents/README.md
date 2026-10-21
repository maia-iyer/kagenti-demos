# Local Claude Code driving chained MOCA subagents

Claude Code runs on your laptop and has no built-in way to offload
work to the cloud — its `Task` subagent runs in-process, in the same
session. This demo denies `Task` and delegates instead through a skill
that dispatches an isolated leaf to [MOCA](https://github.com/rossoctl/moca)
via the official client **`mocactl`**.

The orchestration shape is the **operator's**, not the skill's. For
this demo the operator issues prompts in sequence:

1. *"Dispatch a subagent to diagnose the failing test."* The parent
   packs the scratch dir, creates a workload, spawns a leaf against
   it, and returns. Operator can walk away.
2. Later: *"Check on that subagent and report the diagnosis."* The
   parent collects the result and surfaces the diagnosis.
3. *"Dispatch a fixer with that diagnosis."* Repeat the pattern, this
   time with `--writable` so the fix leaf can edit and test.

MOCA does not know about the chain; from its perspective each leaf is
an independent, self-contained session. The skill does not know about
the chain either — it describes how to dispatch and collect one leaf,
and the model composes multi-leaf flows from the operator's requests.

## How state flows

Four pieces cooperate:

1. **A skill (`moca-delegate-task`)** — upstream MOCA's delegation
   skill, staged verbatim. Tells Claude how to invoke `contextctl ctx
   pack` / `mocactl workloads create` / `mocactl spawn` / `get` /
   `subagents` / `mocactl workloads delete`, how to compose leaf
   prompts (project-is-at-your-cwd, read-only vs writable, "end your
   turn with the full report"), and how to chain leaves by inlining
   the previous leaf's collected text verbatim into the next prompt.
   The two demo-specific details — pack `.` (the scratch dir *is* the
   project), tag every spawn `moca-chained-subagents-demo` so teardown
   can find the leaves — live in the operator's prompts, not the
   skill. The skill does **not** prescribe how many leaves to run or
   in what order — that also comes from the operator's prompts.
2. **`mocactl`** — the official MOCA client, on your `PATH` (never
   staged or wrapped by the demo). It owns **all** auth: the GitHub
   device-flow login, the API token, and the per-session tokens it
   mints itself, all in `~/.config/mocactl` outside this demo. The
   subagent commands it provides: `spawn` (new session per leaf +
   detached worker + a row in the machine-global ledger at
   `~/.local/state/mocactl/subagents.jsonl`), `get` (writes result
   files), `subagents` (lists the ledger joined with live state).
   The `workloads create / get / delete` subcommands manage the
   context-service bundle each leaf mounts — this demo creates one
   workload per leaf at dispatch and deletes it after collection.
   `mocactl promote` / `bundles delete` manage the per-leaf config
   bundles described next.
3. **Two promoted config bundles** — `bundles/public-only/` and
   `bundles/full/`. Each is a directory of `.claude/skills/` content
   that `mocactl promote` uploads as a content-addressed, sha256-pinned
   bundle (**not** `CLAUDE.md`; `promote` only ships skills and
   commands). The diagnose leaf dispatches with the public-posture
   bundle; the fix leaf with the full-access bundle. Different leaf
   behavior, same `mocactl spawn`. Setup promotes both and writes the
   two digests to `MOCA.md` in the scratch dir; teardown deletes them.
4. **A denied `Task` tool** — `.claude/settings.json` denies the
   built-in subagent tool, so the model has to route through the skill
   instead of forking in-process. The permission prompt on each
   `mocactl spawn …` is the operator's visual confirmation that the
   leaf is being dispatched to MOCA, not run locally.

- **Setup time.** `mocactl login` + an inference credential (verified
  end-to-end by `mocactl doctor`), the scratch dir staged **as the
  project** (the fixture flattens into the scratch root; a `.gitignore`
  excludes parent-side bookkeeping like `leaves/` and `MOCA.md`, and
  `contextctl ctx pack` skips `.claude/` directly), and `mocactl
  promote` on each of `bundles/public-only/` and `bundles/full/` so
  their sha256 digests are in `MOCA.md` for the agent to reference. No
  workload is created yet — the agent packs and creates one per leaf
  at dispatch.
- **Dispatch.** The parent authors `leaves/<label>.prompt.txt`, packs
  its cwd (`contextctl ctx pack . --type workspace -o
  leaves/<label>.context`), creates a workload for just that leaf
  (`mocactl workloads create --context leaves/<label>.context --json`),
  runs `mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt
  --config "$DIGEST" --workload "$WORKLOAD_ID" [--writable] --tag
  moca-chained-subagents-demo --json`, writes the note file (with the
  leaf's `workloadId` and `configDigest`), and **stops** — no waiting,
  no polling, no seeding. The diagnose leaf dispatches with
  `--config $DIGEST_PUBLIC` and read-only workload; the fix leaf with
  `--config $DIGEST_FULL --writable`, getting its own per-run copy of
  the files, discarded when the run ends. Each child's identity is
  the triple `(config digest, workload revision, sessionId)` —
  three sha256-pinned handles, server-held.
- **Execution.** The detached worker holds the synchronous
  `POST /v1/runs`; the server runs the leaf to completion and stores
  the result **before** responding, with no client-disconnect abort.
  The leaf's bash cwd is the workload's view (read-only) or its own
  writable copy — the project is at `./`, so leaf prompts never need
  to contain a path.
- **Return.** The result — the leaf's final message — is stored
  server-side for 24h. `mocactl get <sid> --out leaves` writes
  `leaves/<sid>.text`. In a writable run, the per-run copy is already
  gone by the time you collect; if you want a diff or a test log, the
  leaf's prompt must have asked for it as text. Once the result is
  written the parent runs `mocactl workloads delete "$WORKLOAD_ID"`
  for that leaf and records `deletedAt` on the note.

Leaf bookkeeping lives in `leaves/` in the scratch dir, written by the
parent: `leaves/<label>.prompt.txt` (the prompt sent),
`leaves/<label>.context` (the bundle uploaded; a transient cache),
`leaves/<label>.json` (a note mapping label → sessionId → workloadId → configDigest),
and `leaves/<sessionId>.text` (the collected result). A resumed Claude
session reconstructs the picture from those notes plus
`mocactl subagents --tag moca-chained-subagents-demo`.

## Prerequisites

### Tools on your PATH

- `kind` ≥ 0.24.0 (NetworkPolicy-enforcing CNI is a hard requirement:
  sandbox isolation **is** NetworkPolicy), `kubectl`, `docker` (or
  podman's `docker` CLI), `jq`, Claude Code CLI.
- [`mocactl`](https://github.com/rossoctl/moca/tree/main/packages/mocactl)
  (Node 22+), **with the `workloads` subcommand**:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/rossoctl/moca/main/scripts/install-mocactl.sh | MOCACTL_VERSION=edge sh
  ```
  Probe: `mocactl workloads` must say `workloads needs create, get or delete`.
- [`contextctl`](https://github.com/rossoctl/context-service) with the
  `ctx pack` subcommand (build from main — `make build` — until a release
  ships). The pack must honor `.gitignore`; verify with
  `contextctl ctx pack --help | grep -q no-ignore`. `make build` writes to
  `<context-service>/bin/contextctl`; put that on `PATH`.

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

The script creates a kind cluster `moca`, runs MOCA's `deploy/k8s/setup.sh`,
builds and loads the context-service image, wires the two together, and
backgrounds the three port-forwards the demo needs (logs under
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
`moca-supervisor` on `127.0.0.1:8080`, `moca-control-plane` on `8090`,
`context-service` on `9090`. Logs live at
`~/.local/state/moca-chained-demo/`. The MOCA harness **must** be on
local 8080 (the control plane advertises it there); Context Service's
`public-url` in the ConfigMap matches `127.0.0.1:9090`. These ports are
not freely configurable without re-running step 5 of the install.

To restart them, re-run `./prereqs-install.sh` (it kills stale
port-forwards against `kind-moca` before relaunching). To kill them
along with the cluster, use `./prereqs-uninstall.sh`.

### Log in (once per machine)

```bash
export SH_CONTROL_PLANE_URL=http://127.0.0.1:8090
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
./setup.sh
```

This:

1. Verifies the tooling (`kubectl`, `jq`, `contextctl`, `mocactl` —
   including a probe that `mocactl` has the `workloads` subcommand)
   and that the `moca` namespace exists.
2. Runs `mocactl doctor` against the port-forwards — reachability,
   login, credential, harness, and an end-to-end scratch session.
3. Stages the scratch dir at `~/tmp/moca-chained-scratch/` **as the
   project**: the fixture flattens into the scratch root alongside
   `.claude/settings.json` (with the port-forward URLs injected as env),
   the `moca-delegate-task` skill (upstream SKILL.md, verbatim), an
   empty `leaves/`, and a `.gitignore` that excludes `leaves/` and
   `MOCA.md` so `contextctl ctx pack .` captures only the project.
   By-hand shells export the two port-forward URLs themselves — the
   exact lines are printed by `setup.sh` and recorded in `MOCA.md`.

Setup creates **no workload, no session, and seeds nothing per pod** —
the agent packs the scratch dir and runs `mocactl workloads create`
at dispatch (per leaf), and `mocactl spawn --workload <id>` creates
the session. Context Service serves the workload's frozen revision
into whichever sandbox the run lands on, and the agent deletes the
workload after collecting the result.

Environment overrides (set before running):

- `MOCA_NS` — namespace (default `moca`).
- `HARNESS_PORT` / `CP_PORT` — local port-forward ports (default
  `8080` / `8090`). Changing `HARNESS_PORT` breaks discovery.
- `SCRATCH_DIR` — scratch dir path.

> **Re-running setup discards the previous scratch dir** so old notes
> aren't orphaned. The demo tag is a constant
> (`moca-chained-subagents-demo`), so `mocactl subagents --tag` after
> a re-run will show both old and new leaves until teardown. Collect
> any results you care about first, and let the agent delete any
> still-live workloads (or run `./teardown.sh` first — it reconciles
> leftover workloads from `leaves/*.json`).

## Run a session

```bash
cd ~/tmp/moca-chained-scratch && claude
```

The demo flow is **operator prompts, in sequence**. The skill does
not encode the flow; you drive it.

Three state types travel through the chain, and you can peek at each
from the operator's shell:

- **Subagent config** — sha256-pinned skills + commands on the
  control plane. Two were promoted at `./setup.sh` time; their digests
  are in `MOCA.md` (`grep '^Config digest' MOCA.md`).
- **Workload** — sha256-pinned fixture files in Context Service.
  One per leaf, created at dispatch, released after collection.
- **Session** — the per-subagent join of subagent config + workload
  + sandbox pod on the control plane. 24h result TTL.

In a side terminal, export the port-forward URLs so `mocactl` can
reach MOCA (also printed by `setup.sh`):

```bash
cd ~/tmp/moca-chained-scratch
export SH_CONTROL_PLANE_URL=http://127.0.0.1:8090
export SH_HARNESS_URL=http://127.0.0.1:8080
```

**Prompt 1 — start the diagnosis.** Paste something like:

> Dispatch a subagent to diagnose why this project is failing its
> tests. Pack your cwd, dispatch with the **public-only** config digest
> from `MOCA.md` (`--config $DIGEST_PUBLIC`), read-only (no
> `--writable`), tag `moca-chained-subagents-demo`. Tell the leaf to
> use its `public-research` skill. `mocactl spawn` must be the last
> tool call of this turn — do not call `get`, `subagents`, or `sleep`
> after it, and do not wait. End the turn as soon as the note is
> written.

Claude reads the `moca-delegate-task` skill (if it tries `Task`
first, the deny fires and it re-routes), then: writes
`leaves/diagnose.prompt.txt`, packs its cwd (`contextctl ctx pack .`),
creates the workload, and runs `mocactl spawn … --config
"$DIGEST_PUBLIC" --workload "$WORKLOAD_ID" --tag
moca-chained-subagents-demo`. Each permission prompt shows a legible
dispatch command. Claude writes `leaves/diagnose.json` with the
`sessionId` + `workloadId`, reports the id, and stops.

*Peek at state:* grab the handles the agent wrote and watch the
workload transition:

```bash
WLID=$(jq -r .workloadId leaves/diagnose.json)
mocactl workloads get "$WLID" --json | jq '{status,contextType,revision}'
# status: creating → awaiting_upload → ready; revision is the sha256 of the files
```

*Optional durability beat.* To show the server owns the result,
`exit` Claude and restart it (`cd ~/tmp/moca-chained-scratch && claude`)
before prompt 2 — the fresh session re-discovers the chain from
`leaves/*.json`. See [§ Pause and resume](#pause-and-resume).

**Prompt 2 — collect the diagnosis.** When you're ready (seconds to
hours later, same session or a resumed one):

> Check on that subagent and report the diagnosis.

Claude runs `mocactl get <sessionId> --out leaves --json` and branches
on the printed `status`: `queued` → report "still running" and stop
(one check per turn — the leaf is durable server-side, no polling);
`responded` → read `leaves/<sessionId>.text`, surface the diagnosis,
run `mocactl workloads delete "$WORKLOAD_ID"` for that leaf, and
record `collectedAt` / `deletedAt` on the note.

*Peek at state:* same handles, from the operator's shell:

```bash
SID=$(jq -r .sessionId leaves/diagnose.json)
mocactl get "$SID" --json | jq .
# status progresses: queued → responded (or failed / paused)
```

**Prompt 3 — start the fix.** After reviewing the diagnosis:

> Good. Dispatch another subagent to apply that fix. Pack your cwd,
> dispatch with the **full** config digest from `MOCA.md`
> (`--config $DIGEST_FULL`) and `--writable`, tag
> `moca-chained-subagents-demo`. Tell the leaf to use its
> `full-access-fix` skill and inline the previous leaf's diagnosis
> verbatim into the prompt. `mocactl spawn` must be the last tool
> call of this turn — do not call `get`, `subagents`, or `sleep`
> after it, and do not wait. End the turn as soon as the note is
> written.

Claude dispatches a second leaf with its own workload (**with
`--writable`**) and the diagnosis embedded verbatim in the prompt.

**Prompt 4 — collect the fix result.**

> Check on it.

Claude surfaces the change and test outcome (`Ran 1 test / OK` in the
final message), then deletes the workload. The final message is the
only record of the leaf's edits — the writable copy is discarded when
the run ends. What flows between leaves is prompt text only.

### Observe the chain

The whole chain, with each dispatch's subagent config visible:

```bash
TAG=moca-chained-subagents-demo
mocactl subagents --tag "$TAG"
mocactl subagents --tag "$TAG" --json \
  | jq -r '.subagents[] | select(.bundle != null) | "\(.sessionId[:12])  \(.bundle)"'
```

The `bundle` field shows which posture each dispatch booted with.
The demo tag is operator-side (scopes `subagents --tag` and
teardown), not a server-side identity.

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
SID=$(jq -r .sessionId leaves/diagnose.json)
kubectl --context kind-moca -n moca logs deploy/moca-supervisor | \
  jq -c "select(.event==\"audit\" and .sessionId==\"$SID\")"
```

Context Service and sandbox pods don't surface per-request detail;
the only transcript-shaped artifact is the subagent's final message
(`leaves/<sid>.text`), which is why the `full-access-fix` skill
requires verbatim test output in the final report.

## Pause and resume

Because the server completes the run and stores the result before
responding — with no client-disconnect abort — you can quit Claude
any time after a dispatch. Nothing local is holding the leaf open
(the detached worker dies with your login session; the server
doesn't care).

To resume: start Claude again from the scratch dir
(`cd ~/tmp/moca-chained-scratch && claude`) and ask:

> Any subagents still pending from an earlier session?

Claude runs `mocactl subagents --tag moca-chained-subagents-demo` and
reads the `leaves/*.json` notes to reconstruct the picture. For
anything still running, a later `mocactl get` collects it.

The scratch dir **is** the resumable state. Everything needed to pick
up a dropped session is in it (plus the machine-global mocactl
ledger). Nothing lives in the Claude Code session identifier.

**What survives and what doesn't:**

| Event | Result collectable? |
| --- | --- |
| Quit Claude Code | Yes |
| Reboot the laptop | Yes — the worker dies, the server finishes the run |
| Wait up to 24h | Yes (server-side result TTL) |
| Wait past 24h | No — the stored result is gone |
| Port-forwards down mid-leaf | Yes — the leaf still completes; restore the port-forward to collect |
| Supervisor restarts mid-leaf | Possibly never — `subagents` shows `unknown`; re-dispatch |
| Sandbox pod killed mid-leaf | Eventually (minutes) — session reconnects and the leaf reports the mount is gone; re-dispatch |
| `./teardown.sh` | No — deletes the sessions and any leftover workloads |

**Caveats.**

- **The 24h TTL is the only deadline.** `/v1/runs` leaves are not
  swept for inactivity — there is no "unwatched" abort anymore — but
  the stored result expires after 24h regardless of whether it was
  collected.
- **`unknown` is an infrastructure outcome, not a finding.** It means
  the worker died before the server recorded anything (port-forward
  down at dispatch, or a supervisor restart mid-run). Re-dispatch a
  fresh leaf.
- **A leaf that runs longer than five minutes looks failed locally.**
  The spawn worker's sync `POST /v1/runs` carries Node's default
  300-second response timeout, so `subagents` records
  `failed: fetch failed` at the five-minute mark while the run keeps
  going server-side — and stays collectable with `get`. Trust `get`,
  not the ledger state.
- **Delete the sessions last.** `teardown.sh` deletes them and any
  workloads still live, which makes their stored results unreachable.
  Collect what you care about first.

## Teardown

```bash
./teardown.sh
```

This deletes every leaf session of this demo's tag
(`mocactl subagents --tag` → `mocactl sessions delete` for each),
deletes any workloads still live from `leaves/*.json` (normally none —
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

## Troubleshooting

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
- **`setup.sh` says this mocactl is too old.** Your `mocactl` predates
  the `workloads` subcommand. Reinstall from the install script with
  `MOCACTL_VERSION=edge` (see the Prerequisites section).
- **A dispatch fails at `contextctl ctx pack`, or `__pycache__/` ships
  in the bundle.** Your `contextctl` predates workspace bundles or
  `.gitignore` support. Rebuild from
  [`rossoctl/context-service`](https://github.com/rossoctl/context-service)
  main (`make build`); verify with
  `contextctl ctx pack --help | grep -q no-ignore`.
- **A dispatch fails at `mocactl workloads create` with "Context
  Service refused the upload".** Context Service's public URL may not
  be reachable from this host, or the Context Service version may
  predate workspace bundles. Check the `moca-context-service`
  ConfigMap and that your port-forward (or whatever makes `public-url`
  reachable) is up. Setup still probes this once at startup; a mid-run
  outage can trigger the same failure.
- **`get` says "has not finished yet" forever, and `subagents` shows
  `unknown`.** The detached worker died before the server recorded
  anything — typically the port-forward was down at dispatch, or the
  supervisor restarted mid-run. The result will never land;
  re-dispatch a fresh leaf (under a new label). The worker's log, if
  you want the corpse: `~/.local/state/mocactl/spawn-<sessionId>.log`.
- **`subagents` shows `failed` / `fetch failed` right at the five-minute
  mark, but `get` still says `queued`.** Not necessarily a failure: the
  spawn worker's sync `POST /v1/runs` carries Node's default 300-second
  response timeout, so the worker's own fetch is cut off five minutes in
  while the run keeps going on the server. Keep collecting — `get`
  eventually printing `responded` means all is well (only the ledger
  state is wrong, and it is sticky). If `get` stays `queued` well past
  that, the run itself never finished server-side — re-dispatch under a
  fresh label.
- **`get` says `no session`.** Wrong session id, or the session was
  deleted / aged out past 24h.
- **A fix leaf reports edits but you can't find them.** Writable
  per-run copies are **discarded when the run ends.** The leaf's
  final message is the only record. If a prompt forgot to ask for the
  diff and test output verbatim, re-dispatch under a fresh label with
  a prompt that does.
- **Claude tries `Task` and gets denied, then stops.** The skill
  wasn't found. Confirm
  `~/tmp/moca-chained-scratch/.claude/skills/moca-delegate-task/SKILL.md`
  exists; re-run `./setup.sh` if it doesn't.
- **Re-dispatching after a failure.** Use a fresh label (`diagnose2`)
  so the previous note and prompt files aren't overwritten.

## Security note

This demo runs against a throwaway local cluster. MOCA's own auth is
enabled, so leaves require a valid login — and the demo itself now
stores **no secret anywhere**: tokens live in mocactl's own config
dir (`~/.config/mocactl`), outside the demo, and setup no longer
modifies any cluster-wide setting. Still: don't point it at anything
you care about.

The sandbox is also not a security boundary between users. Workloads
are per-user, but the sandboxes themselves are shared — tasks from
different users can run on the same sandbox, as the same Linux user,
one after another. Per-workload sandboxes are
[rossoctl/moca#476](https://github.com/rossoctl/moca/issues/476)
(phase-2).

## Files in this directory

```
README.md                  This file
prereqs-install.sh         Stands up MOCA + Context Service on a local kind cluster and
                           backgrounds the three port-forwards; see Prerequisites
prereqs-uninstall.sh       Runs teardown.sh, kills the port-forwards, deletes the kind cluster
settings.json.example      Permission policy staged into the scratch dir: denies Task and
                           reading mocactl's config dir, allows the mocactl dispatch commands
setup.sh                   Verifies prereqs via mocactl doctor, stages the scratch dir, and
                           promotes the two config bundles (pack + workload create happen
                           per leaf at dispatch time)
teardown.sh                Deletes the demo's leaf sessions, any leftover workloads, and
                           the two config bundles; removes the scratch dir
example_repo/              The project the demo exercises — a stdlib-only Python project
                           with a renamed-API bug. Its contents flatten into the scratch
                           dir at setup time, so the parent's cwd IS the project; the
                           parent packs that cwd at each dispatch.
bundles/                   Two config bundles promoted at setup time: `public-only/`
                           (public-posture skill for the diagnose leaf) and `full/`
                           (full-access skill for the fix leaf). Each is a `.claude/skills/`
                           directory tree passed to `mocactl promote` and referenced by
                           sha256 digest at dispatch.
```

In the scratch dir after `setup.sh`:

```
~/tmp/moca-chained-scratch/   The scratch dir IS the project — the fixture is flattened here.
├── .claude/
│   ├── settings.json      Permission policy + port-forward env for mocactl
│   └── skills/
│       └── moca-delegate-task/SKILL.md   Upstream SKILL.md, verbatim
├── .git/                  So `.gitignore` is honored by `contextctl ctx pack`
├── .gitignore             Keeps `leaves/`, `MOCA.md` out of each leaf's workload
├── MOCA.md                Written by setup.sh — the two promoted config digests + run facts
├── README.md src/ tests/ vendor/ docs/   The fixture, at the scratch root
└── leaves/                Leaf prompts, per-leaf .context bundles, notes (*.json), results (<sid>.text)
```

## Appendix: inspecting state in the sandbox

Writable runs discard their copies when the run ends, and read-only
runs do not write to the mount at all, so there is nothing in the
sandbox to inspect after a leaf finishes. The leaf's final message is
the only record of what it did — if you want a diff or test output,
the prompt must ask for it as text (the templates in "Appendix:
running the flow by hand" already do).

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

## Appendix: running the flow by hand

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
completed server-side (see Troubleshooting). `mocactl get` is the source
of truth: `responded` means it finished.

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

