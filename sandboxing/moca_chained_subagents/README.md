# Local Claude Code driving chained MOCA subagents

Claude Code runs on your laptop. It **does** have a built-in subagent
tool — `Task` — but **no built-in way to offload work to the cloud**:
a `Task` subagent runs in-process on the same laptop, inside the
same session. This demo denies `Task` in `.claude/settings.json` and
delegates instead through a skill that dispatches an isolated leaf to
[MOCA](https://github.com/rossoctl/moca) by shelling out to a small
`moca` CLI (installed into the scratch dir by `setup.sh` and put on
`$PATH` via the staged settings).

Dispatch is a **detachable turn**. `moca start` POSTs to the harness's
`/v1/turn` with `detachable: true`, reads the response stream only long
enough to learn the turn's id, and then walks away. MOCA does not abort
a detachable turn when its client disconnects — it writes every frame
of the turn to a server-side log instead, so the leaf keeps running
with nothing held open on your laptop.

`moca check` collects by **reattaching**: it re-opens the turn's stream,
replays it from the beginning, and follows it if it's still running.

Durability is therefore entirely the server's job. There is no local
background process to keep alive, which means **you can quit Claude
Code, close the laptop, or reboot** and still collect the result. A
finished turn stays collectable for **24 hours**.

The orchestration shape is the **operator's**, not the skill's. For
this demo the operator issues prompts in sequence:

1. *"Dispatch a subagent to diagnose the failing test."* The parent
   writes a run record, starts the turn, and returns. Operator can
   walk away.
2. Later: *"Check on that subagent and report the diagnosis."* The
   parent reattaches to the turn and surfaces the diagnosis.
3. *"Dispatch a fixer with that diagnosis."* Repeat the pattern.

MOCA does not know about the chain; from its perspective each leaf is
one turn in a session. The skill does not know about the chain either —
it describes how to start and collect one leaf, and the model composes
multi-leaf flows from the operator's requests.

For the full design, see [PLAN.md](PLAN.md).

## How it works

Four pieces cooperate:

1. **A skill (`moca-dispatch`)** — the mechanism contract. Tells
   Claude how to invoke the `moca` CLI (`start`, `check`, `list`,
   `cancel`), how to compose leaf prompts (workspace path,
   forward-passed context, deliverable shape), and how to sequence a
   chain. Does **not** prescribe how many leaves to run or in what
   order — that comes from the operator's prompts.
2. **A `moca` CLI** — a small shell script staged at
   `<scratch>/bin/moca` by setup. Mints session tokens, starts
   detachable turns, reattaches to collect them, rebuilds each answer
   from the turn's streamed text frames, and writes run records in
   `.moca-runs/` so the shape on disk is always what the skill expects.
   Keeps the permission prompt short (`moca start diagnose
   diagnose.prompt.txt`) instead of a long curl line.
3. **A denied `Task` tool** — `.claude/settings.json` denies the
   built-in subagent tool, so the model has to route through the skill
   instead of forking in-process. The permission prompt on each
   `moca start …` is the operator's visual confirmation that the leaf
   is being dispatched to MOCA, not run locally.
4. **One session, seeded at setup** — `setup.sh` creates a single MOCA
   session for the whole chain and seeds `example_repo/` into that
   session's workspace on every sandbox pod via `kubectl cp`. The skill
   only dispatches turns; it never touches `/workspace` at runtime.

Run records live in `.moca-runs/` in the scratch dir — one JSON file
per dispatched leaf, plus its `.prompt.txt`, the raw `.sse` transcript,
and the extracted `.answer.txt`. A resumed Claude session finds
in-flight work by reading that directory.

## Two origins, two kinds of token

This is worth understanding before you debug anything:

| Origin | Port-forward | Serves | Needs |
| --- | --- | --- | --- |
| Control plane | `8090` | `/v1/sessions`, `/v1/credentials` | **API token** |
| Supervisor (harness) | **`8080`** | `/v1/turn`, `/v1/turn/cancel` | **Session token** |

- The **API token** is your identity. `mocactl` obtains it via a GitHub
  device-flow login and refreshes it for you.
- A **session token** is scoped to one session and lives about **300
  seconds**. The harness rejects an API token, and the control plane
  rejects a session token.

Because 300s is shorter than any realistic pause, `moca` re-mints a
session token (`POST /v1/sessions/{id}/token`) immediately before every
harness call rather than caching one. You never manage this by hand.

The supervisor's port-forward **must** use local port `8080`: the
control plane advertises the harness to clients as
`http://127.0.0.1:8080`.

## One session, one workspace

Every leaf in a chain is a turn in the **same** session, so every leaf
shares one sandbox workspace at `/workspace/<session-id>`. That is what
lets a fix leaf work on the files a diagnose leaf examined — MOCA
derives the workspace path from the session id, so there is no way to
point two sessions at one directory.

Three consequences:

- **Leaves run sequentially.** A session runs one turn at a time; a
  second concurrent turn is refused with `409 turn_in_progress` and
  nothing starts. The chain this demo shows is sequential anyway.
- **Leaves are not isolated from each other.** The isolation boundary
  is this chain versus everything else, not leaf versus leaf.
- **Session ids are server-generated.** You pass `moca` a short local
  label (`diagnose`, `fix`) that names files in `.moca-runs/`.

## How state flows

- **Setup time.** `setup.sh` creates the session, then `kubectl cp`s
  `example_repo/` into `/workspace/<session-id>` on every sandbox pod.
  The fixture is cluster-side before Claude ever starts. (Seeding
  directly is safe: the sandbox worker creates a session's workspace
  with `mkdir` semantics — a directory that already exists is used
  as-is — and MOCA's idle sweeper only reclaims workspaces that have
  run a tool call. Seeding every pod covers the fact that a session
  pins to a sandbox only on its first turn.)
- **Dispatch.** The only state going from the laptop to MOCA at
  dispatch time is the prompt text and the session id. The parent
  embeds any output from prior leaves into the next leaf's prompt as
  plain text.
- **Execution.** The supervisor hands the turn to a warm worker, which
  runs the agent and executes its tool calls in the sandbox pod,
  working in `/workspace/<session-id>`.
- **Return.** The leaf's prose arrives as a stream of `text` frames,
  each carrying a delta; `moca check` concatenates them into
  `.answer.txt`. Files the leaf wrote stay on the sandbox pod and do
  **not** come back to the laptop. If you want to see a diff or a test
  log, the leaf's prompt must ask for it as text in the response.

## Inspecting state in the sandbox

Files a leaf writes stay on the sandbox pod. To see what actually
changed, go look (substitute the session id and pod from `MOCA.md`):

```bash
# The workspace for this session
kubectl -n moca-sandbox exec moca-sandbox-0 -c sandbox -- \
  ls -la /workspace/<session-id>

# Did the fixer's change land?
kubectl -n moca-sandbox exec moca-sandbox-0 -c sandbox -- \
  cat /workspace/<session-id>/src/index.js
```

Three things to keep in mind:

- **Every sandbox pod is seeded; the session pins to one on its first
  turn.** `MOCA.md` lists the seeded pods. To find the serving pod
  after a leaf has run, list the workspace on each — the serving pod
  is the one showing the leaf's changes, the others only the fixture:

  ```bash
  for POD in moca-sandbox-0 moca-sandbox-1; do
    kubectl -n moca-sandbox exec "$POD" -c sandbox -- \
      ls -la /workspace/<session-id>
  done
  ```
- **`-c sandbox` is required**, and the namespace is `moca-sandbox`,
  not `moca`.
- **The fixture is not a git repo**, so `git diff` won't work in the
  sandbox. If you want a diff, have the leaf's prompt ask for one as
  text.

Local run state lives in `.moca-runs/` in the scratch dir:

```bash
cd ~/tmp/moca-chained-scratch
moca list                              # every record + status
cat .moca-runs/<leaf>.answer.txt       # the extracted answer
cat .moca-runs/<leaf>.sse              # raw frames, incl. tool calls
```

## What's honest and what isn't

- **Isolation here is prompt-only, not substrate-enforced.** `moca
  start` sends a prompt and nothing else — there is no `readOnly` flag
  and no workload catalog on this install. The researcher-vs-fixer
  split lives in the prompts you write ("do not modify files" vs
  "apply this fix"); a non-compliant leaf could ignore it.

- **Leaves in a chain are not isolated from each other.** They share a
  session and therefore a workspace. The real boundary is the sandbox
  pod and its NetworkPolicy, which separate this chain from the rest of
  the cluster — not one leaf from the next.

- **`/workspace/<session-id>` is not a security boundary.** Upstream
  says so explicitly: every session's directory sits under the same
  `/workspace` root, owned by the same user, in the same container. A
  leaf that runs `cd ..` can read another session's files.

- **The workspace is not durable.** It is container-local with no
  volume, so a sandbox pod restart destroys it — taking the fixture
  with it. It is also reclaimed after a period with no tool call
  (`setup.sh` widens that to 8h; the default is 30m). The turn log in
  Redis is unaffected by either, so a *collected answer* survives what
  the *files* don't. If the files vanish mid-chain, re-run `./setup.sh`
  for a fresh session.

- **Every leaf gets the same tools.** There is no per-leaf tools
  allowlist, so honest capability splits would need upstream support.

- **Chaining is parent-side.** MOCA has no "on complete, trigger X"
  primitive; the parent Claude session does the sequencing between the
  operator's prompts.

## Prerequisites

- A kind cluster with [MOCA](https://github.com/rossoctl/moca) deployed
  via `deploy/k8s/setup.sh`. From a MOCA checkout:

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

- `kubectl` configured for that cluster.
- `curl` and `jq` on your `PATH`.
- [`mocactl`](https://github.com/rossoctl/moca/tree/main/packages/mocactl)
  (needs Node 22+), for login and credentials:

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

### Log in and store an inference credential

```bash
export SH_CONTROL_PLANE_URL=http://127.0.0.1:8090
mocactl login
mocactl doctor
```

MOCA issues inference credentials **per user**, and session creation
fails without one. Store your Anthropic key:

```bash
printf %s "$ANTHROPIC_API_KEY" | mocactl credentials add anthropic \
  --host api.anthropic.com --kind api-key \
  --endpoint https://api.anthropic.com
```

With exactly one inference credential stored, MOCA selects it
automatically. If you have several, pass
`MOCA_INFERENCE_CRED=<name>` to `setup.sh`.

> **There is no operator-wide key fallback.**
> `SH_ALLOW_OPERATOR_FALLBACK=true` also requires
> `SH_OPERATOR_INFERENCE_TOKEN`, which this deployment does not wire —
> turning it on makes the control plane refuse to boot. A per-user
> credential is the only supported option here.

## Setup

From this directory:

```bash
./setup.sh
```

This:

1. Verifies the tooling, both namespaces, and both port-forwards.
2. Obtains an API token via `mocactl auth token` (or `MOCA_API_TOKEN`)
   and writes it to `<scratch>/.moca-auth/api.hdr`, mode 0600.
3. Checks you have an inference credential.
4. Widens the sandbox workspace idle timeout to 8h, so a paused demo
   doesn't lose its files.
5. Creates **one** session for the chain and seeds `example_repo/` into
   `/workspace/<session-id>` on every sandbox pod via `kubectl cp`,
   then verifies the files landed on each.
6. Stages `.claude/settings.json`, `.claude/skills/moca-dispatch/`,
   and `bin/moca` into `~/tmp/moca-chained-scratch/`, and patches
   `settings.json` so the scratch `bin/` is on `$PATH`.
7. Writes `MOCA.md` with both URLs, the session id, the workspace path,
   and the sandbox pod.

Environment overrides (set before running):

- `MOCA_NS` / `SANDBOX_NS` — namespaces (default `moca` /
  `moca-sandbox`).
- `SANDBOX_POD_SELECTOR` — label selector matching the sandbox pods
  (default `app=moca-sandbox`).
- `HARNESS_PORT` / `CP_PORT` — local port-forward ports (default
  `8080` / `8090`). Changing `HARNESS_PORT` breaks discovery.
- `MOCA_API_TOKEN` — use this token instead of calling `mocactl`.
- `MOCA_INFERENCE_CRED` — pick a credential when you have several.
- `WORKSPACE_IDLE` — workspace idle timeout (default `8h`).
- `SCRATCH_DIR` — scratch dir path.

> **Tokens are written to header files, never passed on a command
> line.** Anything on a command line is readable by any process on the
> machine via `ps`. `<scratch>/.moca-auth/` is mode 0700, its contents
> 0600, the staged settings deny reading it, and `teardown.sh` removes
> it.

## Run a session

```bash
cd ~/tmp/moca-chained-scratch && claude
```

The demo flow is **operator prompts, in sequence**. The skill does
not encode the flow; you drive it.

**Prompt 1 — start the diagnosis.** Paste something like:

> There's a Node.js project at the workspace path in `MOCA.md` on
> MOCA. Dispatch a subagent to diagnose why its tests are failing.
> Tell the leaf it's read-only — do not modify files, do not run
> shell commands beyond `npm test`.

Claude should:

1. Read the `moca-dispatch` skill.
2. **Not** invoke `Task` — if it tries, the deny fires and it
   re-routes through the skill.
3. Write the leaf's prompt to a file in `.moca-runs/` and run
   `moca start diagnose <that file>`. The permission prompt shows the
   `moca start …` command — short, legible, and clearly not a local
   shell execution.
4. The CLI writes a record at `.moca-runs/diagnose.json`, starts the
   detachable turn, and returns control to you with the session and
   turn ids. The leaf is now running on the cluster; this turn is over.

**Prompt 2 — collect the diagnosis.** When you're ready (seconds to
hours later, same session or a resumed one):

> Check on that subagent and report the diagnosis.

Claude runs `moca check diagnose`, which reattaches to the turn,
rebuilds the answer from its text frames, and prints it. If the leaf is
still running, `check` says so and the turn ends — Claude should not
sit in a polling loop.

**Prompt 3 — start the fix.** After reviewing the diagnosis:

> Good. Dispatch another subagent to apply that fix, run the tests,
> and report the diff and outcome.

Claude dispatches a second leaf, embedding the diagnosis from Prompt 2
verbatim in the new leaf's prompt.

> **Note on isolation.** Both leaves share this chain's session and
> workspace, which is what lets the fixer see the files the researcher
> read. The researcher's "don't modify files" contract lives in its
> prompt, not in the substrate. See "What's honest and what isn't".

**Prompt 4 — collect the fix result.**

> Check on it.

Claude reattaches and surfaces the diff and test outcome.

While leaves run, in another terminal:

```bash
kubectl -n moca get pods
kubectl -n moca logs -f deploy/moca-supervisor
```

Both the supervisor and the sandbox pods are **warm**. What you're
watching for is the work landing in a sandbox pod that your laptop
never touches.

## Pause and resume

Because MOCA owns the turn's durability, you can quit Claude any time
after a dispatch has written its record in `.moca-runs/`. Nothing local
is holding the turn open.

To resume: start Claude again from the scratch dir
(`cd ~/tmp/moca-chained-scratch && claude`) and ask:

> Any subagents still pending from an earlier session?

Claude runs `moca list` and reports each record's status. For anything
`running`, `moca check` reattaches and collects it.

The scratch dir **is** the resumable state. Everything needed to pick
up a dropped session is in it. Nothing lives in `$HOME` or in the
Claude Code session identifier.

**What survives and what doesn't:**

| Event | Result collectable? |
| --- | --- |
| Quit Claude Code | Yes |
| Reboot the laptop | Yes |
| Wait up to 24h | Yes (`SH_TURN_LOG_TTL_S`) |
| Wait past 24h | No — `status=lost` |
| Leaf runs 30min with nobody attached | No — aborted `unwatched` |
| Supervisor pod restarts mid-turn | No — aborted `restarting` |
| Sandbox pod restarts | Answer yes, **files no** |
| `./teardown.sh` | No — deletes the session |

**Caveats.**

- **The 30-minute unwatched abort is the one to watch.** A turn running
  with nobody attached for 30 continuous minutes is aborted with
  `abortReason: unwatched`. Running `moca check` counts as attaching
  and resets that clock, so check in on long leaves rather than
  disappearing for an hour. A **finished** turn is never aborted — it
  just waits out its 24h window.
- **These are infrastructure outcomes, not findings.** `unwatched`,
  `restarting`, `lease_lost`, `owner_lost`, `saturated` and `refused`
  all tell you nothing about the code under review. The CLI explains
  each in plain language; don't let them get reported as a diagnosis.
- **Delete the session last.** `teardown.sh` deletes it, which makes
  its turn logs unreachable. Collect what you care about first.

## Teardown

```bash
./teardown.sh
```

This deletes the demo's session, restores the sandbox workspace idle
timeout, and removes the scratch directory (including the API token).
It does **not** touch MOCA, your cluster, or your `mocactl` login. If
the port-forwards are still running, `Ctrl-C` them.

## Troubleshooting

- **`curl: (7)` / connection refused.** A port-forward isn't running.
  You need **both** — the harness on 8080 and the control plane on
  8090.
- **`setup.sh` says "not logged in".** Run
  `mocactl --control-plane-url http://127.0.0.1:8090 login`.
- **`setup.sh` says "no inference credential stored".** Add one with
  `mocactl credentials add` (see Prerequisites). Session creation fails
  without it, and there is no operator-key fallback.
- **`setup.sh` says "you have N inference credentials".** MOCA
  auto-selects only when there's exactly one. Re-run with
  `MOCA_INFERENCE_CRED=<name> ./setup.sh`.
- **`401` / `403` from the harness.** A session token is required on
  `/v1/turn`, and an API token is rejected there. The CLI mints one per
  call, so this usually means `MOCA.md`'s session id doesn't match the
  token's session — re-run `./setup.sh`.
- **`moca check` says `status=refused (HTTP 409 turn_in_progress)`.**
  Another leaf of this chain is still running. All leaves share one
  session, and a session runs one turn at a time. Collect the running
  leaf first (`moca list`, then `moca check <it>`).
- **`moca check` says `status=running` forever.** Reattaching is free
  and doesn't disturb the leaf, so keep checking. If it has run more
  than 30 minutes, it may have been aborted `unwatched` — `check` will
  say so once the terminal frame lands.
- **`moca check` says `status=lost`.** MOCA holds no turn log: it never
  started, or the 24h window expired. Re-dispatch under a new label.
- **`status=failed` with `abortReason: unwatched`.** Nobody was
  attached for 30 minutes while the leaf ran. Infrastructure, not a
  finding. Re-dispatch and `moca check` sooner.
- **`status=failed` with `abortReason: restarting`.** The supervisor
  rolled mid-turn, which aborts detached turns. Re-dispatch.
- **The fixture is gone from the workspace.** The sandbox pod restarted
  (the workspace has no volume), or it sat idle past the timeout. Run
  `./teardown.sh && ./setup.sh` for a fresh session.
- **`setup.sh` says the fixture is missing on a pod.** The `kubectl cp`
  into that pod failed, or the pod rolled mid-seed. Re-run
  `./setup.sh` — it creates a fresh session and re-seeds every pod.
- **Claude tries `Task` and gets denied, then stops.** The skill wasn't
  found. Confirm
  `~/tmp/moca-chained-scratch/.claude/skills/moca-dispatch/SKILL.md`
  exists; re-run `./setup.sh` if it doesn't.
- **Claude asks "which workload is read-only?"** This install exposes
  no workload catalog and the CLI takes no workload argument. Rephrase
  without those terms — the split is prompt-only here.

## Security note

This demo runs against a throwaway local cluster. MOCA's own auth is
enabled, so leaves require a valid token — but the demo stores an API
token on disk in the scratch dir and widens a cluster-wide workspace
timeout. Don't point it at anything you care about.

## Files in this directory

```
PLAN.md                    Design doc (trimmed)
README.md                  This file
skill/SKILL.md             Skill Claude reads to dispatch leaves to MOCA
bin/moca                   CLI the skill shells out to (start / check / list / cancel);
                           start opens a detachable turn, check reattaches to collect
settings.json.example      Permission policy: denies Task, allows the moca CLI
setup.sh                   Creates the session, seeds the fixture, stages the scratch dir
teardown.sh                Deletes the session, restores settings, removes the scratch dir
example_repo/              Vendored fixture — Node.js project with a renamed-API bug
```

In the scratch dir after `setup.sh`:

```
~/tmp/moca-chained-scratch/
├── .claude/
│   ├── settings.json              Allow-list for moca CLI + PATH env pointing at bin/
│   └── skills/moca-dispatch/      Copied from skill/
├── bin/
│   └── moca                       CLI the skill invokes
├── .moca-auth/                    API token (0600)
├── .moca-runs/                    Run records (+ *.prompt.txt / *.sse / *.answer.txt)
└── MOCA.md                        URLs, session id, workspace path, sandbox pod
```

## Appendix: running the flow by hand

What Claude is meant to run for each operator prompt, without the agent
noise. Leaf prompt text is illustrative.

```bash
cd ~/tmp/moca-chained-scratch
export PATH="$HOME/tmp/moca-chained-scratch/bin:$PATH"
WS="$(grep -E '^Workspace:' MOCA.md | sed -E 's/^Workspace:[[:space:]]+//')"
```

Prompt 1 — dispatch the diagnosis:

```bash
cat > .moca-runs/diagnose.prompt.txt <<EOF
You are a read-only diagnostic agent working in an isolated sandbox.
Your workspace is a Node.js project at ${WS}.

Task: determine why the project's tests are failing.

Constraints:
- Do NOT modify, create, or delete any files.
- The only shell command you may run is \`npm test\`.

Deliverable — respond in plain text with:
1. The exact error message from the test run.
2. The file and line where the failure originates.
3. The root cause, in one or two sentences.
4. The one-line change that would fix it (describe it; do not apply it).
EOF

moca start diagnose .moca-runs/diagnose.prompt.txt
```

Prompt 2 — collect the diagnosis:

```bash
moca list
moca check diagnose
```

Prompt 3 — dispatch the fixer, embedding the diagnosis verbatim:

```bash
DIAG="$(cat .moca-runs/diagnose.answer.txt)"

cat > .moca-runs/fix.prompt.txt <<EOF
You are a fixer agent working in an isolated sandbox.
Your workspace is a Node.js project at ${WS}.

A previous read-only agent diagnosed the test failure. Its findings:

--- BEGIN DIAGNOSIS ---
${DIAG}
--- END DIAGNOSIS ---

Task: apply the fix described above, then run \`npm test\`.

Deliverable — respond in plain text with:
1. The changed line, before and after, with its file path.
2. Whether the tests now pass.
EOF

moca start fix .moca-runs/fix.prompt.txt
```

Prompt 4 — collect the fix result:

```bash
moca check fix
```

Confirm the fix landed cluster-side, not locally:

```bash
SID="$(grep -E '^Session id:' MOCA.md | sed -E 's/^Session id:[[:space:]]+//')"
for POD in $(grep -E '^Sandbox pods:' MOCA.md | sed -E 's/^Sandbox pods:[[:space:]]+//'); do
  echo "-- ${POD}"
  kubectl -n moca-sandbox exec "$POD" -c sandbox -- \
    grep -n 'lib\.' "/workspace/${SID}/src/index.js"
done
```

The serving pod shows `lib.newName`; the pods the session never landed
on still hold the seeded `lib.oldName`.
```

Inspect a failed leaf:

```bash
cat .moca-runs/fix.json        # record: status, turnId, abortReason
cat .moca-runs/fix.sse         # raw frames, incl. every tool call
```

Cancel a leaf that's still running:

```bash
moca cancel fix
```

Re-dispatch after a failure (needs a new label):

```bash
cp .moca-runs/fix.prompt.txt .moca-runs/fix2.prompt.txt
moca start fix2 .moca-runs/fix2.prompt.txt
```

Start a completely fresh chain (new session, re-seeded fixture):

```bash
cd -  # back to the demo dir
./teardown.sh && ./setup.sh
```
