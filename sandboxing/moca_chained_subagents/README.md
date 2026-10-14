# Local Claude Code driving chained MOCA subagents

Claude Code runs on your laptop. It **does** have a built-in subagent
tool — `Task` — but **no built-in way to offload work to the cloud**:
a `Task` subagent runs in-process on the same laptop, inside the
same session. This demo denies `Task` in `.claude/settings.json` and
delegates instead through a skill that dispatches an isolated leaf to
[MOCA](https://github.com/rossoctl/moca) by shelling out to the
official client, **`mocactl`** — which is already installed on your
`PATH`; this demo stages no CLI of its own.

Dispatch is **`mocactl spawn`**. It creates a **new session** for the
leaf, prints the session id immediately, and forks a **detached local
worker** that holds a synchronous `POST /v1/runs`. The server runs the
leaf to completion and **persists the result before responding** —
and, unlike a normal turn, `/v1/runs` has **no client-disconnect
abort**. So the leaf keeps running with nothing held open on your
laptop: you can quit Claude Code, close the laptop, or reboot, and the
result is still there.

Collection is **`mocactl get`**: it writes the leaf's final message to
`leaves/<sessionId>.text`. Results live server-side for **24 hours** —
that is the only deadline.

The orchestration shape is the **operator's**, not the skill's. For
this demo the operator issues prompts in sequence:

1. *"Dispatch a subagent to diagnose the failing test."* The parent
   writes the leaf's prompt, spawns it, seeds its workspace, and
   returns. Operator can walk away.
2. Later: *"Check on that subagent and report the diagnosis."* The
   parent collects the result and surfaces the diagnosis.
3. *"Dispatch a fixer with that diagnosis."* Repeat the pattern.

MOCA does not know about the chain; from its perspective each leaf is
an independent, self-contained session. The skill does not know about
the chain either — it describes how to dispatch and collect one leaf,
and the model composes multi-leaf flows from the operator's requests.

For the full design, see [PLAN-mocactl.md](PLAN-mocactl.md).

## How it works

Three pieces cooperate:

1. **A skill (`moca-dispatch`)** — the mechanism contract. Tells
   Claude how to invoke `mocactl spawn` / `get` / `subagents`, how to
   compose leaf prompts (cwd-is-your-workspace, wait-for-fixture,
   read-only vs apply, "end your turn with the full report"), and how
   to chain leaves by inlining the previous leaf's collected text
   verbatim into the next prompt. Does **not** prescribe how many
   leaves to run or in what order — that comes from the operator's
   prompts.
2. **`mocactl`** — the official MOCA client, on your `PATH` (never
   staged or wrapped by the demo). It owns **all** auth (see below).
   The subagent commands it provides: `spawn` (new session per leaf +
   detached worker + a row in the machine-global ledger at
   `~/.local/state/mocactl/subagents.jsonl`), `get` (writes result
   files), `subagents` (lists the ledger joined with live state).
   These commands are marked **Preview** upstream.
3. **A denied `Task` tool** — `.claude/settings.json` denies the
   built-in subagent tool, so the model has to route through the skill
   instead of forking in-process. The permission prompt on each
   `mocactl spawn …` is the operator's visual confirmation that the
   leaf is being dispatched to MOCA, not run locally.

Setup stages a scratch dir (fixture copy, `leaves/`, `MOCA.md` runtime
facts including the demo **tag**, Claude settings) but no longer
creates a session — every session is created at dispatch time by
`spawn`.

Leaf bookkeeping lives in `leaves/` in the scratch dir, written by the
parent:

- `leaves/<label>.prompt.txt` — the prompt that was sent.
- `leaves/<label>.json` — a note: `{label, sessionId, kind,
  promptFile, dispatchedAt}`. Status is never stored; it is always
  derived fresh from `subagents` / `get` at read time.
- `leaves/<sessionId>.text` — the collected result, written by
  `mocactl get --out leaves`.

A resumed Claude session reconstructs the picture from those notes
plus `mocactl subagents --tag "$TAG"`.

## Auth is mocactl's job

`mocactl` owns every token: the GitHub device-flow login, the API
token, and the per-session tokens it mints itself. All of it lives in
`~/.config/mocactl`, outside this demo. The demo never touches a
token — no `.moca-auth/` directory, no `MOCA_API_TOKEN`, no header
files, no re-minting logic. If auth breaks, fix it with `mocactl
login` / `mocactl doctor`; there is nothing demo-side to repair.

## One leaf, one session, one fresh workspace

Every leaf is its **own** MOCA session, so its own sandbox workspace
at `/workspace/<sessionId>`. Right after `spawn` returns, the parent
seeds a fresh copy of `example_repo/` into that workspace on every
sandbox pod via `kubectl cp` (a session pins to a pod only on its
first turn, and the parent cannot know which — so every pod gets it).

Three consequences:

- **Leaves are isolated from each other by construction.** The fix
  leaf does not work on "the same files" the diagnose leaf saw — it
  gets a fresh fixture copy plus the diagnosis as prompt text. The
  isolation boundary is now substrate-enforced (one session, one
  workspace, one fresh fixture), not a promise in a prompt. Context
  flows leaf→leaf via prompt text only.
- **No turn sequencing.** Each leaf is a single turn in its own
  session, so there is no `409 turn_in_progress` to dodge; leaves
  *could* run concurrently (fan-out is possible) — this demo
  deliberately stays a sequential chain.
- **Session ids are server-generated** (`spawn` prints them). The
  parent keeps short local labels (`diagnose`, `fix`) that name the
  files in `leaves/`.

## How state flows

- **Setup time.** `mocactl login` + an inference credential (verified
  end-to-end by `mocactl doctor`), then a staged scratch dir. Nothing
  lands in the cluster at setup time — no session, no fixture.
- **Dispatch.** The parent authors `leaves/<label>.prompt.txt`, runs
  `mocactl spawn "$(cat leaves/<label>.prompt.txt)" --kind prompt
  --tag "$TAG" --json` (quote-substitution keeps the command legible
  in the permission prompt), writes the note file, then seeds the
  workspace with the kubectl cp loop. The seed can land before or
  after the leaf boots — both orderings are safe: the sandbox worker
  creates a session's workspace with mkdir "use as-is" semantics, and
  every leaf prompt carries a wait-for-fixture clause ("if
  tests/ is not present yet, wait for it"). Then the parent
  **stops** — no waiting, no polling.
- **Execution.** The detached worker holds the synchronous
  `POST /v1/runs`; the server runs the leaf to completion and stores
  the result **before** responding, with no client-disconnect abort.
  The leaf's bash cwd is its workspace (`/workspace/<sessionId>` —
  the sandbox always advertises the `workspace-subdir` capability), so
  leaf prompts never need to contain a path.
- **Return.** The result — the leaf's final message — is stored
  server-side for 24h. `mocactl get <sid> --out leaves` writes
  `leaves/<sid>.text`. Files the leaf wrote stay on the sandbox pod
  and do **not** come back to the laptop; if you want to see a diff
  or a test log, the leaf's prompt must ask for it as text.

## Inspecting state in the sandbox

Files a leaf writes stay on the sandbox pod, under that leaf's
`/workspace/<sessionId>`. To see what actually changed, go look
(substitute the session id from `leaves/<label>.json` and the pod
name):

```bash
# Which workspaces exist (one per leaf of this demo)
kubectl -n moca-sandbox exec moca-sandbox-0 -c sandbox -- \
  ls -la /workspace/

# Did the fixer's change land?
kubectl -n moca-sandbox exec moca-sandbox-0 -c sandbox -- \
  cat /workspace/<sessionId>/src/greet.py
```

Things to keep in mind:

- **A leaf's workspace survives until the idle sweeper reclaims it**
  (30 minutes with no tool call, by default) or teardown removes it —
  so the "inspect the sandbox" story works within that window after
  the leaf's last activity.
- **Every sandbox pod was seeded for that leaf; the session pinned to
  one on its first turn.** To find the serving pod, list the workspace
  on each — the serving one shows the leaf's changes, the others only
  the seeded fixture:

  ```bash
  for POD in moca-sandbox-0 moca-sandbox-1; do
    kubectl -n moca-sandbox exec "$POD" -c sandbox -- \
      ls -la /workspace/<sessionId>
  done
  ```
- **`-c sandbox` is required**, and the namespace is `moca-sandbox`,
  not `moca`.
- **The fixture is not a git repo**, so `git diff` won't work in the
  sandbox. If you want a diff, have the leaf's prompt ask for one as
  text.

Local leaf state lives in `leaves/` in the scratch dir:

```bash
cd ~/tmp/moca-chained-scratch
mocactl subagents --tag "$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
cat leaves/diagnose.json          # note: label -> sessionId
cat leaves/<sessionId>.text       # the collected result
```

## What's honest and what isn't

**What the mocactl migration gained:**

- **Leaf isolation is substrate-enforced.** One session, one
  workspace, one fresh fixture per leaf. A leaf physically cannot see
  another leaf's files (within the sandbox's own limits, below).
- **No token plumbing.** mocactl owns all auth; the demo touches no
  token and stores no secret.
- **No local CLI.** The ~500-line `bin/moca` is gone; the demo is
  prompt templates and shell snippets over the official client.
- **Durability is server-side.** `/v1/runs` completes and stores the
  result regardless of any local process — quit Claude, reboot, it
  doesn't matter (collect within 24h).

**What it lost:**

- **Cancel.** There is no server-side cancel for `/v1/runs` and no
  headless cancel command. A dispatched leaf runs to completion; if it
  went wrong, let it finish and ignore it, or re-dispatch a fresh
  leaf.
- **The streamed transcript.** Results are the leaf's final text
  only — there is no tool-call log (the old `.sse` files are gone).
  If you need the leaf's reasoning, ask for it in the prompt.

**Standing caveats:**

- **`spawn` / `subagents` / `get` are Preview** upstream, not Stable.
- **`/workspace/<sessionId>` is not a security boundary.** Every
  session's directory sits under the same `/workspace` root, owned by
  the same user, in the same container. A leaf that runs `cd ..` can
  read another session's files.
- **The workspace is not durable.** It is container-local with no
  volume, so a sandbox pod restart destroys it. The *result text* is
  unaffected — it lives server-side.
- **Every leaf gets the same tools.** The read-only diagnose leaf is
  read-only by prompt, not by capability; there is no per-leaf tool
  allowlist on this install.
- **Chaining is parent-side.** MOCA has no "on complete, trigger X"
  primitive; the parent Claude session does the sequencing between
  the operator's prompts.

## Prerequisites

- A kind cluster with [MOCA](https://github.com/rossoctl/moca) deployed
  via `deploy/k8s/setup.sh`. From a MOCA checkout (clone with
  `--recurse-submodules`, or run `git submodule update --init --recursive`
  before building — otherwise the Docker build fails at `npm ci` inside
  the empty `pi-fork/` dir):

  ```bash
  cd deploy/k8s
  SH_GITHUB_CLIENT_ID=<your-oauth-client-id> ./setup.sh --target kind --build
  ```

  This installs the supervisor, control plane, relay, Redis and the
  sandbox StatefulSet into namespaces `moca` and `moca-sandbox`.

  > **kind ≥ 0.24.0 with a NetworkPolicy-enforcing CNI is a hard
  > requirement.** Isolation between the sandbox namespace and
  > everything else is enforced by NetworkPolicy; a CNI that ignores
  > them silently removes the boundary rather than failing loudly.

- `kubectl` configured for that cluster, and `jq` on your `PATH`.
- [`mocactl`](https://github.com/rossoctl/moca/tree/main/packages/mocactl)
  (needs Node 22+), **≥ `edge-a02b9db` with the subagent commands**.
  Probe your install: `mocactl spawn` with no arguments must complain
  `spawn needs a prompt` (an old build says `unknown command`):

  ```bash
  curl -fsSL https://raw.githubusercontent.com/rossoctl/moca/main/scripts/install-mocactl.sh | sh
  ```

- Claude Code CLI.

### Start both port-forwards

In two other terminals. The harness **must** be on local port 8080:

```bash
kubectl port-forward -n moca svc/moca-supervisor 8080:8080
kubectl port-forward -n moca svc/moca-control-plane 8090:8080
```

### Log in (once per machine)

```bash
export SH_CONTROL_PLANE_URL=http://127.0.0.1:8090
mocactl login
mocactl doctor
```

`doctor` verifies the whole path end to end, including that you have
an inference credential (a leaf's session creation fails without
one). If it reports none, store your Anthropic key:

```bash
printf %s "$ANTHROPIC_API_KEY" | mocactl credentials add anthropic \
  --host api.anthropic.com --kind api-key \
  --endpoint https://api.anthropic.com
```

For an Anthropic-compatible proxy (e.g. a LiteLLM gateway) that expects
`Authorization: Bearer`, use `--kind bearer` and point `--host` /
`--endpoint` at the proxy. `--kind api-key` is only validated against
`api.anthropic.com`:

```bash
printf %s "$PROXY_TOKEN" | mocactl credentials add anthropic \
  --host <proxy-host> --kind bearer \
  --endpoint https://<proxy-host>
```

## Setup

From this directory:

```bash
./setup.sh
```

This:

1. Verifies the tooling (`kubectl`, `jq`, `mocactl` — including a
   probe that `mocactl` has the subagent commands) and that both
   namespaces exist.
2. Runs `mocactl doctor` against the port-forwards — reachability,
   login, credential, harness, and an end-to-end scratch session.
   This replaces all the old hand-rolled health/token/credential
   probes.
3. Stages the scratch dir at `~/tmp/moca-chained-scratch/`:
   `.claude/settings.json` (with the port-forward URLs injected as env and
   the kubectl allow patterns rewritten for the sandbox namespace), the
   `moca-dispatch` skill, a copy of `example_repo/`, an empty `leaves/`,
   and `MOCA.md` with the runtime facts and this run's demo tag.

Setup creates **no session and seeds nothing into the cluster** —
every session is created by `mocactl spawn` at dispatch time, and
every leaf's workspace is seeded right after its spawn.

Environment overrides (set before running):

- `MOCA_NS` / `SANDBOX_NS` — namespaces (default `moca` /
  `moca-sandbox`).
- `SANDBOX_POD_SELECTOR` — label selector matching the sandbox pods
  (default `app=moca-sandbox`).
- `SANDBOX_CONTAINER` — sandbox container name (default `sandbox`).
- `HARNESS_PORT` / `CP_PORT` — local port-forward ports (default
  `8080` / `8090`). Changing `HARNESS_PORT` breaks discovery.
- `SCRATCH_DIR` — scratch dir path.

> **Re-running setup discards the previous scratch dir** (the demo
> tag is per-run, so old notes would be orphaned). Collect any
> results you care about first.

## Run a session

```bash
cd ~/tmp/moca-chained-scratch && claude
```

The demo flow is **operator prompts, in sequence**. The skill does
not encode the flow; you drive it.

**Prompt 1 — start the diagnosis.** Paste something like:

> Dispatch a subagent to diagnose why the fixture project's tests are
> failing. Tell the leaf it's read-only — do not modify files.

Claude should:

1. Read the `moca-dispatch` skill and `MOCA.md` (tag, namespace,
   selector, fixture path).
2. **Not** invoke `Task` — if it tries, the deny fires and it
   re-routes through the skill.
3. Write the leaf's prompt to `leaves/diagnose.prompt.txt` and run
   `mocactl spawn "$(cat leaves/diagnose.prompt.txt)" --kind prompt
   --tag "$TAG" --json`. The permission prompt shows a legible
   command — clearly a dispatch, not a local execution.
4. Write the note `leaves/diagnose.json`, seed the leaf's workspace
   (`kubectl cp` of `example_repo/.` into `/workspace/<sessionId>` on
   every sandbox pod), report the session id, and **stop**. The leaf
   is now running on the cluster; this turn is over.

**Prompt 2 — collect the diagnosis.** When you're ready (seconds to
hours later, same session or a resumed one):

> Check on that subagent and report the diagnosis.

Claude runs `mocactl get <sessionId> --out leaves --json` and branches
on the printed `status`: `queued` → report "still running" and stop
(one check per turn — the leaf is durable server-side, no polling);
`responded` → read `leaves/<sessionId>.text` and surface the diagnosis.

**Prompt 3 — start the fix.** After reviewing the diagnosis:

> Good. Dispatch another subagent to apply that fix, run the tests,
> and report the change and outcome.

Claude dispatches a second leaf — a **fresh session and fresh fixture
copy** — with the diagnosis from Prompt 2 embedded verbatim in the
new leaf's prompt, then seeds its workspace the same way.

**Prompt 4 — collect the fix result.**

> Check on it.

Claude collects and surfaces the change and test outcome.

> **Note on isolation.** Each leaf is its own session with its own
> workspace and a fresh fixture copy; what flows between leaves is
> prompt text only. The diagnose leaf's "don't modify files" contract
> lives in its prompt, not in the substrate — see "What's honest and
> what isn't".

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

Claude runs `mocactl subagents --tag "$TAG"` and reads the
`leaves/*.json` notes to reconstruct the picture. For anything still
running, a later `mocactl get` collects it.

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
| Sandbox pod restarts | Result yes, **workspace files no** |
| `./teardown.sh` | No — deletes the sessions |

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
- **Delete the sessions last.** `teardown.sh` deletes them, which
  makes their stored results unreachable. Collect what you care
  about first.

## Teardown

```bash
./teardown.sh
```

This deletes every leaf session of this demo's tag
(`mocactl subagents --tag` → `mocactl sessions delete` for each),
removes each leaf's `/workspace/<sessionId>` from the sandbox pods
(the idle sweeper would get them within 30 minutes anyway), and
removes the scratch directory. It does **not** touch MOCA, your
cluster, or your `mocactl` login. If the port-forwards are still
running, `Ctrl-C` them.

## Troubleshooting

- **`mocactl` can't reach the control plane / connection refused.**
  A port-forward isn't running. You need **both** — the harness on
  8080 and the control plane on 8090 — and `SH_CONTROL_PLANE_URL` /
  `SH_HARNESS_URL` exported (or the staged settings' env block, in a
  Claude session).
- **`setup.sh` fails at doctor.** Follow the fix doctor prints for
  each failing check — it covers reachability, login, credentials,
  and the harness.
- **`setup.sh` says this mocactl is too old.** Your `mocactl` predates
  the subagent commands. Install ≥ `edge-a02b9db`.
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
  fresh label. Leaves that outrun five minutes are usually working
  around the sandbox image's missing node/npm; the prompt templates
  forbid that.
- **`get` says `no session`.** Wrong session id, or the session was
  deleted / aged out past 24h.
- **A leaf reports the fixture never arrived.** The seed race went
  bad (e.g. kubectl cp failed on every pod). Check the seed loop ran
  (`kubectl exec … ls /workspace/<sid>`), then re-dispatch under a
  new label.
- **The fixture is gone from a workspace you wanted to inspect.** The
  sandbox pod restarted, or the workspace sat idle past 30 minutes
  and the sweeper reclaimed it. The collected result text is
  unaffected.
- **Claude tries `Task` and gets denied, then stops.** The skill
  wasn't found. Confirm
  `~/tmp/moca-chained-scratch/.claude/skills/moca-dispatch/SKILL.md`
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
PLAN-mocactl.md            Implementation plan for the mocactl migration (this README's design)
README.md                  This file
skill/SKILL.md             Skill Claude reads to dispatch leaves to MOCA via mocactl
settings.json.example      Permission policy staged into the scratch dir: denies Task and
                           reading mocactl's config dir, allows the mocactl dispatch and
                           kubectl seed commands
setup.sh                   Verifies prereqs via mocactl doctor, stages the scratch dir
teardown.sh                Deletes the demo's leaf sessions + workspaces, removes the scratch dir
example_repo/              Vendored fixture — Node.js project with a renamed-API bug
```

In the scratch dir after `setup.sh`:

```
~/tmp/moca-chained-scratch/
├── .claude/
│   ├── settings.json      Permission policy + port-forward env for mocactl
│   └── skills/
│       └── moca-dispatch/SKILL.md   The dispatch skill Claude reads
├── example_repo/          Fixture copy the parent seeds every leaf from
├── leaves/                Leaf prompts, notes (*.json), and collected results (<sid>.text)
└── MOCA.md                Runtime facts: tag, URLs, namespace/selector/container
```

## Appendix: running the flow by hand

What Claude is meant to run for each operator prompt, without the
agent noise — and the acceptance test for the mechanics: this
sequence must run clean in a plain terminal before anything else is
believed. Run it from a fresh `./setup.sh`.

```bash
cd ~/tmp/moca-chained-scratch

# mocactl reaches MOCA through the port-forwards (both must be up):
export SH_CONTROL_PLANE_URL=http://127.0.0.1:8090
export SH_HARNESS_URL=http://127.0.0.1:8080

TAG="$(sed -nE 's/^Demo tag:[[:space:]]+//p' MOCA.md)"
```

**1 — author the diagnose leaf's prompt:**

```bash
cat > leaves/diagnose.prompt.txt <<'EOF'
You are a subagent leaf running inside a MOCA sandbox. Your current working
directory is your private workspace — do not cd elsewhere. A small Python
project is being copied into your workspace right now: if tests/ is not
present yet, wait for it (re-check every few seconds; it arrives within a
minute or two).

The project's tests currently fail. Run the test suite
(`python3 -m unittest discover -s tests`), read the relevant code and the
docs under docs/upstream-refs/, and report:
1. The exact failing assertion and the test command that exercises it.
2. The root cause, with file paths and line references.
3. The minimal change that would fix it, described precisely — another agent
   will apply it on a fresh copy of this project.

The project is stdlib-only; do NOT install or download anything (no `pip`,
no package manager). Diagnose from the source and docs alone.

Do NOT edit any files: this is a diagnosis-only task. End your turn with the
full diagnosis as your final message.
EOF
```

**2 — dispatch it.** `--json` prints one line on stdout
(`{"type":"session","sessionId":"…","pid":…}`); diagnostics go to stderr:

```bash
mocactl spawn "$(cat leaves/diagnose.prompt.txt)" --kind prompt --tag "$TAG" --json
SID="<paste the sessionId from that line>"
```

**3 — write the note** (this is what a resumed session reads):

```bash
cat > leaves/diagnose.json <<EOF
{"label":"diagnose","sessionId":"$SID","kind":"prompt",
 "promptFile":"leaves/diagnose.prompt.txt",
 "dispatchedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
```

**4 — seed the leaf's workspace.** Every pod, because the session pins
to one only on its first turn. Both orderings (seed-before-boot,
seed-after-boot) boot the leaf correctly — its prompt tells it to wait
for `tests/` — with one caveat: a leaf quick enough to edit files
while the copy is still landing can have those edits overwritten by it
(this happened once in testing; the leaf noticed and re-applied its
work). Seed right after spawn and the window is small:

```bash
for POD in $(kubectl -n moca-sandbox get pods -l app=moca-sandbox -o name); do
  POD="${POD#pod/}"
  kubectl -n moca-sandbox wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null
  kubectl -n moca-sandbox exec "$POD" -c sandbox -- sh -c "mkdir -p '/workspace/$SID'"
  kubectl -n moca-sandbox cp -c sandbox example_repo/. "$POD:/workspace/$SID"
done
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
`responded` (exit 0) → read the result. `responded` is the prompt-kind
success — `solved` is the solve-kind twin, and `mocactl subagents`
calls both of them `done`:

```bash
cat leaves/"$SID".text
```

The diagnosis should name the renamed API: `src/greet.py` calls
`lib.old_name` while the vendored `vendor/lib/__init__.py` (v2.0.0)
exports only `new_name`. The sandbox image ships `python3` but no
`pip`; the fixture is stdlib-only, so `python3 -m unittest` runs
directly.

**6 — chain the fix leaf.** Author its prompt with the diagnosis
inlined **verbatim** (never point one leaf at another leaf's files —
each leaf has a fresh workspace):

```bash
DIAG="$(cat leaves/"$SID".text)"
cat > leaves/fix.prompt.txt <<EOF
You are a subagent leaf running inside a MOCA sandbox. Your current working
directory is your private workspace — do not cd elsewhere. A small Python
project is being copied into your workspace right now: if tests/ is not
present yet, wait for it (re-check every few seconds; it arrives within a
minute or two).

A prior agent diagnosed a test failure in a fresh copy of this project:

------------------------------------------------------------------------
$DIAG
------------------------------------------------------------------------

Apply the fix in your workspace copy — edit src/, never vendor/ — then run
\`python3 -m unittest discover -s tests\` to confirm the suite passes. The
project is stdlib-only; do NOT install or download anything (no \`pip\`, no
package manager). Report:
1. The exact change you made (file, line, before/after).
2. The full test output after your change (verbatim, including the
   \`Ran N tests\` and \`OK\` / \`FAILED\` lines).

End your turn with the full report as your final message.
EOF
```

Dispatch it exactly like the diagnose leaf, then collect **later** — the
fix leaf takes minutes, and `get` exit 1 with "has not finished yet"
just means still running:

```bash
mocactl spawn "$(cat leaves/fix.prompt.txt)" --kind prompt --tag "$TAG" --json
FIX_SID="<paste the sessionId>"

cat > leaves/fix.json <<EOF
{"label":"fix","sessionId":"$FIX_SID","kind":"prompt",
 "promptFile":"leaves/fix.prompt.txt",
 "dispatchedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF

for POD in $(kubectl -n moca-sandbox get pods -l app=moca-sandbox -o name); do
  POD="${POD#pod/}"
  kubectl -n moca-sandbox wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null
  kubectl -n moca-sandbox exec "$POD" -c sandbox -- sh -c "mkdir -p '/workspace/$FIX_SID'"
  kubectl -n moca-sandbox cp -c sandbox example_repo/. "$POD:/workspace/$FIX_SID"
done

mocactl get "$FIX_SID" --out leaves --json
cat leaves/"$FIX_SID".text
```

The report should say `src/greet.py` changed (`old_name` → `new_name`) and
that the tests pass — or, if the sandbox has no node/npm, that the fix was
verified by inspection.

**7 — see the whole chain:**

```bash
mocactl subagents --tag "$TAG"
```

Both leaves should show `done` — unless one ran longer than five minutes:
the spawn worker's own HTTP request is cut off at the five-minute mark, so
a long leaf shows up here as `failed` / `fetch failed` even though it
completed server-side (see Troubleshooting). `mocactl get` is the source
of truth: `responded` means it finished.

Inspect a leaf's workspace while it survives (within ~30 minutes of
its last tool call; the fix leaf's should show the change):

```bash
kubectl -n moca-sandbox exec moca-sandbox-0 -c sandbox -- \
  cat /workspace/$FIX_SID/src/greet.py
```

**8 — tear down:**

```bash
cd -   # back to the demo dir
./teardown.sh
mocactl sessions   # the demo's leaf sessions are gone
```

Re-dispatch after a failure (fresh label, fresh session, fresh
fixture — copy the prompt file and edit as needed):

```bash
cp leaves/fix.prompt.txt leaves/fix2.prompt.txt
mocactl spawn "$(cat leaves/fix2.prompt.txt)" --kind prompt --tag "$TAG" --json
```

Start a completely fresh chain (new tag, fresh scratch):

```bash
./teardown.sh && ./setup.sh
```
