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
  end-to-end by `mocactl doctor`), a scratch dir staged with the
  example project at `./example_repo/` (not the scratch root — this
  keeps parent-side bookkeeping like `leaves/` and `.claude/` out of
  each leaf's workload bundle), and `mocactl promote` on each of
  `bundles/public-only/` and `bundles/full/` so their sha256 digests
  are in `MOCA.md` for the agent to reference. No workload is created
  yet — the agent packs and creates one per leaf at dispatch.
- **Dispatch.** The parent authors `leaves/<label>.prompt.txt`, packs
  the project subdir (`contextctl ctx pack ./example_repo --type
  workspace -o leaves/<label>.context`), creates a workload for just
  that leaf (`mocactl workloads create --context
  leaves/<label>.context --json`), runs `mocactl spawn "$(cat
  leaves/<label>.prompt.txt)" --kind prompt --config "$DIGEST"
  --workload "$WORKLOAD_ID" [--writable] --tag
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
  with workspace bundles ships). `make build` writes to
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
3. Stages the scratch dir at `~/tmp/moca-chained-scratch/`:
   `.claude/settings.json` (with the port-forward URLs injected as env),
   the `moca-delegate-task` skill (upstream SKILL.md, verbatim),
   `example_repo/` as a subdir (so the agent packs just the project,
   not parent-side bookkeeping), and an empty `leaves/`. By-hand shells
   export the two port-forward URLs themselves — the exact lines are
   printed by `setup.sh` and recorded in `MOCA.md`.

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

**Prompt 1 — start the diagnosis.** Paste something like:

> Dispatch a subagent to diagnose why the project at `./example_repo`
> is failing its tests. Pack `./example_repo`, dispatch with the
> **public-only** config digest from `MOCA.md` (`--config $DIGEST_PUBLIC`),
> read-only (no `--writable`), tag `moca-chained-subagents-demo`.
> Tell the leaf to use its `public-research` skill. `mocactl spawn`
> must be the last tool call of this turn — do not call `get`,
> `subagents`, or `sleep` after it, and do not wait. End the turn as
> soon as the note is written.

Claude should:

1. Read the `moca-delegate-task` skill.
2. **Not** invoke `Task` — if it tries, the deny fires and it
   re-routes through the skill.
3. Write the leaf's prompt to `leaves/diagnose.prompt.txt`, pack the
   project subdir (`contextctl ctx pack ./example_repo --type
   workspace -o leaves/diagnose.context`), create its workload
   (`mocactl workloads create --context leaves/diagnose.context --json`),
   then run `mocactl spawn "$(cat leaves/diagnose.prompt.txt)" --kind
   prompt --config "$DIGEST_PUBLIC" --workload "$WORKLOAD_ID" --tag
   moca-chained-subagents-demo --json`. Each permission prompt shows
   a legible command — clearly a dispatch, not a local execution.
4. Write the note `leaves/diagnose.json` (with `sessionId` and
   `workloadId`), report the session id, and **stop**. The leaf is now
   running on the cluster; this turn is over.

**Prompt 2 — collect the diagnosis.** When you're ready (seconds to
hours later, same session or a resumed one):

> Check on that subagent and report the diagnosis.

Claude runs `mocactl get <sessionId> --out leaves --json` and branches
on the printed `status`: `queued` → report "still running" and stop
(one check per turn — the leaf is durable server-side, no polling);
`responded` → read `leaves/<sessionId>.text`, surface the diagnosis,
run `mocactl workloads delete "$WORKLOAD_ID"` for that leaf, and
record `collectedAt` / `deletedAt` on the note.

**Prompt 3 — start the fix.** After reviewing the diagnosis:

> Good. Dispatch another subagent to apply that fix. Pack
> `./example_repo`, dispatch with the **full** config digest from
> `MOCA.md` (`--config $DIGEST_FULL`) and `--writable`, tag
> `moca-chained-subagents-demo`. Tell the leaf to use its
> `full-access-fix` skill and inline the previous leaf's diagnosis
> verbatim into the prompt. `mocactl spawn` must be the last tool
> call of this turn — do not call `get`, `subagents`, or `sleep`
> after it, and do not wait. End the turn as soon as the note is
> written.

Claude dispatches a second leaf, which packs the project subdir again
and creates its own workload (**with `--writable`**), with the
diagnosis from Prompt 2 embedded verbatim in the new leaf's prompt.
No seeding — the writable copy is served by Context Service into the
sandbox automatically.

**Prompt 4 — collect the fix result.**

> Check on it.

Claude collects and surfaces the change and test outcome, then runs
`mocactl workloads delete "$WORKLOAD_ID"` for the fix leaf's workload.
The fix leaf's final message is the only record of its edits — the
writable copy is discarded when the run ends.

> **Note on isolation.** Each leaf is its own session; the diagnose
> leaf's mount is read-only, and the fix leaf's writable copy is
> isolated to that run. What flows between leaves is prompt text only.

While leaves run, in another terminal:

```bash
kubectl -n moca get pods
kubectl -n moca logs -f deploy/moca-supervisor
```

Both the supervisor and the sandbox pods are **warm**. What you're
watching for is the work landing in a sandbox pod that your laptop
never touches.

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
- **A dispatch fails at `contextctl ctx pack`.** Your `contextctl`
  predates workspace bundles. Rebuild from
  [`rossoctl/context-service`](https://github.com/rossoctl/context-service)
  main (`make build`).
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
                           with a renamed-API bug. Staged into the scratch dir as the
                           `./example_repo/` subdir at setup time; the parent packs that
                           at each dispatch.
bundles/                   Two config bundles promoted at setup time: `public-only/`
                           (public-posture skill for the diagnose leaf) and `full/`
                           (full-access skill for the fix leaf). Each is a `.claude/skills/`
                           directory tree passed to `mocactl promote` and referenced by
                           sha256 digest at dispatch.
```

In the scratch dir after `setup.sh`:

```
~/tmp/moca-chained-scratch/
├── .claude/
│   ├── settings.json      Permission policy + port-forward env for mocactl
│   └── skills/
│       └── moca-delegate-task/SKILL.md   Upstream SKILL.md, verbatim
├── MOCA.md                Written by setup.sh — the two promoted config digests + run facts (also prints the two `export` lines for by-hand shells)
├── example_repo/          src/ tests/ vendor/ docs/ README.md — the project the leaves pack
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

## Appendix: what's honest and what isn't

**What the workloads migration gained:**

- **Fixture delivery is a service, not a hack.** Context Service
  mounts the frozen revision at the leaf's cwd; the parent runs no
  `kubectl cp`, and the demo needs no cluster-admin access on the
  sandbox namespace.
- **Writes are per-run.** The fix leaf's edits are isolated to its
  own copy and discarded when the run ends; a re-dispatched fix (new
  workload, packed again from the scratch dir) starts from the frozen
  revision, not from the previous run's edits.
- **No token plumbing.** mocactl owns all auth; the demo touches no
  token and stores no secret.
- **No local CLI.** The demo is prompt templates and shell snippets
  over the official clients (`mocactl`, `contextctl`).
- **Durability is server-side.** `/v1/runs` completes and stores the
  result regardless of any local process — quit Claude, reboot, it
  doesn't matter (collect within 24h).

**What it lost:**

- **Cancel.** There is no server-side cancel for `/v1/runs` and no
  headless cancel command. A dispatched leaf runs to completion; if
  it went wrong, let it finish and ignore it, or re-dispatch a fresh
  leaf.
- **The streamed transcript.** Results are the leaf's final text
  only — there is no tool-call log. If you need the leaf's reasoning
  or the diff it applied, ask for it in the prompt.

**Standing caveats:**

- **`spawn` / `subagents` / `get` / `workloads` are Preview** upstream,
  not Stable.
- **The sandbox is not a security boundary between users.** Workloads
  are per-user, but the sandboxes themselves are shared. Tasks from
  different users can run on the same sandbox, as the same Linux
  user, one after another. Per-workload sandboxes are
  [rossoctl/moca#476](https://github.com/rossoctl/moca/issues/476)
  (phase-2).
- **Workload content is not durable storage.** The workload's frozen
  revision is read-only, and writable per-run copies are discarded on
  completion. There is no cross-run shared state in phase-1 workloads.
- **Every leaf gets the same tools.** The read-only diagnose leaf is
  read-only because the mount is read-only AND the prompt says so;
  the fix leaf is writable only because `--writable` was passed and
  the prompt says to edit. There is no per-leaf tool allowlist on
  this install.
- **Chaining is parent-side.** MOCA has no "on complete, trigger X"
  primitive; the parent Claude session does the sequencing between
  the operator's prompts.
- **Orphan workloads if the agent dies between `workloads create` and
  the note write.** `teardown.sh` reconciles workload leftovers by
  reading `workloadId` from `leaves/*.json`. A workload created but
  never recorded in a note (because the agent process died in the
  seconds-wide window between `mocactl workloads create` returning
  and the parent writing `leaves/<label>.json`) is unrecoverable by
  teardown — `mocactl workloads` has no `list` subcommand to walk,
  and the orphan sits on the user's quota (5 live workloads by
  default) until it ages out. If `workloads create` starts failing
  with `429 workload_quota_exceeded` after many abandoned runs, that
  is the symptom; `mocactl workloads delete <id>` by id is the only
  remedy today. The structural fix is a `mocactl workloads list`
  subcommand — not yet upstream.

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
contextctl ctx pack ./example_repo --type workspace \
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
contextctl ctx pack ./example_repo --type workspace -o leaves/fix.context
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
contextctl ctx pack ./example_repo --type workspace -o leaves/fix2.context
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

## Appendix: durability — parent Claude Code quits mid-chain

Same four prompts, one interjection between prompts 1 and 2. Arc
ends on `OK`.

1. **Prompt 1** — dispatch diagnose.
2. `exit` Claude (operator "closes the laptop").
3. `cd ~/tmp/moca-chained-scratch && claude` → *"Any subagents still
   pending from an earlier session?"*
4. **Prompt 2** — collect; diagnosis lands.
5. **Prompts 3 and 4** — fix leaf, `Ran 1 test / OK`.

What this shows: the scratch dir plus the mocactl ledger are the
resumable state; the server-side result store carries the work.

**Not shown live: sandbox pod killed mid-leaf.** The session
reconnects to the respawned pod, but the per-session mount is
per-pod-instance and doesn't come back. The leaf eventually
`respond`s with an honest-failure message explaining the context
disappeared, but "eventually" is several minutes while the leaf's
model retries its tools with growing backoff — too slow for a live
beat. The "What survives" table above has the one-line summary.

## Appendix: watching state move during the demo

Three state types travel through this chain. All are reachable with
`mocactl` from the operator's shell — no `kubectl exec`, no admin
access to the cluster. Run these in a side terminal while the main
chain runs.

Set these once (also printed by `./setup.sh`; `MOCA.md` records them):

```bash
cd ~/tmp/moca-chained-scratch
export SH_CONTROL_PLANE_URL=http://127.0.0.1:8090
export SH_HARNESS_URL=http://127.0.0.1:8080
TAG=moca-chained-subagents-demo
SID=$(jq -r .sessionId leaves/diagnose.json)
WLID=$(jq -r .workloadId leaves/diagnose.json)
```

### 1. Subagent config — sha256-pinned skills + commands (control plane)

Each dispatched subagent boots with a **subagent config** (`mocactl
promote` uploads a directory of `.claude/skills/` and `.claude/commands/`
as a content-addressed, sha256-pinned bundle on the control plane).
This demo promotes two at `./setup.sh` time — `public-only` for the
diagnose leaf, `full` for the fix leaf — and spawn carries the digest
on `--config`. `mocactl` has no `bundles list` yet, so the
operator-visible record is the two digests setup wrote into `MOCA.md`,
plus the `bundle` field on each session:

```bash
grep '^Config digest' MOCA.md             # the two promoted digests
mocactl subagents --tag "$TAG" --json \
  | jq -r '.subagents[] | select(.bundle != null) | "\(.sessionId[:12])  \(.bundle)"'
```

The `bundle` field on each row shows the digest that subagent booted
with — tells you which posture it had. After `./teardown.sh`,
`mocactl bundles delete` has freed both.

### 2. Workload — sha256-pinned files (Context Service)

Created per leaf at dispatch, released after collection. Carries the
fixture tree the subagent mounts.

```bash
mocactl workloads get "$WLID" --json | jq '{status,contextType,revision}'
```

The `revision` is the sha256 of the file tree; the `status` moves
`creating` → `awaiting_upload` → `ready` → `deleted`. Watch it
transition during a dispatch by re-running the command.

### 3. Session — the per-subagent join (control plane)

The record that ties this subagent to one subagent config + one
workload + one sandbox pod. 24h TTL on the result.

```bash
mocactl get "$SID" --json | jq .
# status progresses: queued → responded (or failed / paused)
```

Once the subagent has finished:

```bash
mocactl subagents --tag "$TAG"              # ledger view: this run's subagents
cat leaves/"$SID".text | head               # the subagent's final message
```

### What the demo tag scopes

`moca-chained-subagents-demo` is the operator-side handle for *"this
demo's subagents"*. Scopes `mocactl subagents --tag`, teardown's
reconciler, and nothing else — it's not a server-side identity.

### Logs: what you can and can't see while the demo runs

- **Supervisor / control plane / context-service pod logs are silent
  per-request at steady state** (verified: tailed `kubectl logs` on
  all three through a full dispatch cycle, zero bytes of new output).
  Only startup/shutdown events. Projecting log tails would show
  nothing happening.
- **Sandbox pod logs are not useful mid-leaf.** The sandbox pods are
  ephemeral worker containers; they execute tool calls but don't
  stream a transcript. `kubectl logs -n moca-sandbox moca-sandbox-N`
  shows the sandbox-service process, not the subagent's reasoning or
  tool calls.
- **Server has the tool-call history but doesn't expose it.** The
  harness coordinates with the sandbox for every tool call; that
  history is not surfaced through any `mocactl` command today. The
  only transcript-shaped artifact is the subagent's final message
  (`leaves/<sid>.text`) — which is why the `full-access-fix` skill
  requires verbatim test output in the final report: it's the only
  way to see what the subagent did.

### What's NOT visible from the client

- Which sandbox pod the session pinned to (lives in Redis
  `sh:sandbox:affinity:<sid>`; no client-side query today).
- The audit stream (`session_created`, `credential_issued` events).
- Supervisor / control plane / Context Service logs are silent at
  steady state — they emit nothing per-request at default verbosity,
  so there's no useful log tail to project. The visible state surface
  is the three `mocactl` commands above, not log streams.
