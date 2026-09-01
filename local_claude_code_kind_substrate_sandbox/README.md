# Local Claude Code with a Kind-hosted Substrate Sandbox

A demo where Claude Code runs on your laptop and every shell command it wants
to run is executed inside a per-session sandbox actor on an
[Agent Substrate](https://github.com/agent-substrate/substrate) cluster running
locally in kind. Each Claude session gets its own actor. `--resume` reuses the
same actor, so build caches and installed dependencies survive across days.

## What this demo shows

- **Actor-per-session multiplexing.** Multiple concurrent Claude sessions map
  to multiple actors sharing a small pool of Kubernetes worker pods. Substrate
  handles the packing.
- **State persistence across sessions.** An actor's `/workspace` (uploaded
  source) and any state your commands leave behind (`node_modules`, build
  outputs, `.pytest_cache`, etc.) stay in the actor between commands and
  survive `--resume`.
- **No changes to Claude Code or Substrate.** The demo lives entirely in this
  directory and consumes both upstream projects unchanged.

## How it works

Three mechanisms cooperate:

1. **Lifecycle hooks (`SessionStart`, `SessionEnd`).** These call
   `substrate-sandbox-hook` to create/resume the session's actor on start and
   suspend it on end. `SessionStart` publishes the actor's name to
   `$CLAUDE_ENV_FILE` as `export SUBSTRATE_ACTOR_NAME=<name>`. Claude Code
   sources that file as a preamble before every Bash command, so `exec`
   sees the actor in its environment. The env-file is per-session, which is
   what lets two Claude sessions share a scratch dir without colliding.

2. **A skill (`substrate-sandbox`).** This tells Claude that every shell
   command must be invoked as:

       ~/bin/substrate-sandbox-hook exec -- <command>

   The binary reads the pin file to find the actor, tars up the workspace,
   POSTs to Substrate's `/process` endpoint with the workspace and command
   composed together, and prints the sandbox's stdout/stderr locally. Exit
   code is the sandbox command's exit code.

3. **A `PreToolUse` hook on the Bash tool** (`substrate-sandbox-hook
   check-bash`). This is the enforcement layer. If Claude tries to call the
   built-in Bash tool with a command that isn't routed through
   `substrate-sandbox-hook exec --`, the hook denies the call with a reason
   telling Claude to re-issue through the sandbox binary. Without this hook
   the skill is advisory — Claude can (and did) silently run commands on the
   laptop, which is how you got a `Darwin` from `uname` in earlier runs.

Read/Edit/Grep/Glob still operate on your laptop's local filesystem — only
shell commands are redirected.

There are two flavors of the demo, differing only in the hook wiring:

- **Eager** (default, `settings.json.example`) — `SessionStart` creates
  and resumes the actor up front. Actor stays Running for the whole
  session.
- **Lazy** (`settings.json.lazy.example`) — no `SessionStart`; the actor
  is created on the first shell command and then resumed-per-call and
  suspended-after-each-call, so worker slots are only held while a
  command is actually executing. See "Lazy mode" below.

For the full design, see [PLAN.md](PLAN.md).

## Prerequisites

You need a kind cluster with Substrate installed and both the counter demo
and the sandbox demo deployed. These are prerequisites, not part of this
demo, and are one-time setup for local Substrate work.

From your `substrate/` checkout:

```bash
# 1. Kind cluster + local registry.
./hack/create-kind-cluster.sh

# 2. Substrate itself.
./hack/install-ate-kind.sh --deploy-ate-system

# 3. Counter demo — proves snapshot storage works on kind.
./hack/install-ate-kind.sh --deploy-demo-counter

# 4. Sandbox demo — deploys the WorkerPool and ActorTemplate we reuse.
./hack/install-ate-kind.sh --deploy-demo-sandbox
```

You also need:

- Go 1.22+
- `kubectl` and the `kubectl-ate` plugin (`go install ./cmd/kubectl-ate`
  from `substrate/`)
- Claude Code CLI

## Setup

From this directory:

```bash
./setup.sh
```

This scales the existing `sandbox-workerpool` from 2 to 5 replicas, creates
the `claude-sandbox` atespace, and builds the `substrate-sandbox-hook` binary
into `$HOME/bin/`.

Then, in two separate terminals, start the port-forwards:

```bash
# Terminal A
kubectl port-forward -n ate-system svc/api 8080:443

# Terminal B
kubectl port-forward -n ate-system svc/atenet-router 8000:80
```

## Run a session

Create a **scratch directory**. This is a disposable working directory —
you'll throw it away at will. Do not use one of your real project
directories; every command in this demo tars up the whole scratch dir and
uploads it to the sandbox, so keep it small and disposable.

```bash
mkdir -p ~/tmp/claude-sandbox-scratch/.claude/skills
cp settings.json.example ~/tmp/claude-sandbox-scratch/.claude/settings.json
cp -r skill ~/tmp/claude-sandbox-scratch/.claude/skills/substrate-sandbox
```

Put whatever source you want to hack on into the scratch dir. Fresh
scaffolding, a git clone, or nothing at all — the sandbox has Alpine Linux
with a shell and standard tools; you can also apk-add more.

Start Claude:

```bash
cd ~/tmp/claude-sandbox-scratch
claude
```

Ask Claude to do something with a shell command — build, test, list files,
whatever. It should invoke `substrate-sandbox-hook exec -- ...` under the
hood. Watch the actor appear:

```bash
kubectl ate get actors -a claude-sandbox
```

You should see a `sess-<hash>` actor in `ACTOR_STATE_RUNNING`.

## Verify the sandbox from inside Claude

There are two things to prove:

1. Shell commands actually run in Alpine, not on your Mac.
2. Files you create locally in the scratch dir do reach the sandbox's
   `/workspace`.

### Step 1: prove commands run in Alpine

Paste this into your Claude session:

> Run `uname -a` and `cat /etc/os-release`. Show me the raw output.

On a correctly wired scratch dir:

- Claude's first attempt goes through the built-in Bash tool and is
  denied by the `PreToolUse` hook. You'll see a message in the transcript
  saying the command was blocked because it did not go through the
  sandbox binary, with instructions to re-issue via
  `~/bin/substrate-sandbox-hook exec -- <cmd>`.
- Claude re-issues through the sandbox. Claude Code shows you a
  permission prompt whose command is literally
  `~/bin/substrate-sandbox-hook exec -- uname -a` — read that string,
  it's your visual proof the command is going to the actor, then
  approve.
- Output comes back as `Linux ... 6.x.x ...` (not `Darwin`), and
  `/etc/os-release` says `NAME="Alpine Linux"`.

If you see `Darwin`, or you never get a permission prompt whose command
starts with `substrate-sandbox-hook exec --`, shell commands are running
on your laptop. Fix: re-copy `settings.json.example` into
`.claude/settings.json`, make sure `$HOME/bin/substrate-sandbox-hook` is
up to date (`./setup.sh`), and restart Claude.

### Step 2: prove the local workspace lands in the sandbox

The tar-and-upload happens on every `exec` call, so an `ls` alone won't
tell you much if the workspace was empty when you started. Give it
something to see.

**From your laptop terminal**, in the scratch dir, create two files:

```bash
cd ~/tmp/claude-sandbox-scratch
echo "hello from the laptop" > note.txt
cat > run.sh <<'EOF'
#!/bin/sh
echo "running inside: $(uname -s) $(cat /etc/alpine-release 2>/dev/null || echo not-alpine)"
echo "pwd: $(pwd)"
echo "note.txt says:"
cat note.txt
EOF
chmod +x run.sh
```

Then paste this into Claude:

> List the files in the workspace, then run `./run.sh` and show me the
> output.

You should see:

- `ls` output that includes `note.txt` and `run.sh` — proof the tarball
  from your laptop was extracted into `/workspace` on the actor.
- `run.sh` output showing:
  - `running inside: Linux <version>` (from the Alpine actor)
  - `pwd: /workspace`
  - `note.txt says: hello from the laptop` (proving the *contents* of
    files you created locally are what the sandbox saw, not just their
    names)

If `ls` is empty, the tar upload failed silently — check that
`$HOME/bin/substrate-sandbox-hook` is up to date, that the port-forwards
to `svc/api` and `svc/atenet-router` are running, and that the pinned
actor is in `ACTOR_STATE_RUNNING` (`kubectl ate get actors -a
claude-sandbox`).

## Concurrent sessions

Two concurrent Claude sessions can share a scratch directory or use
separate ones — either works. Each session gets its own actor (the actor
name is derived from Claude's session ID), and the actor name reaches
`exec` through `$CLAUDE_ENV_FILE`, which Claude Code isolates per session.

Same scratch dir:

```bash
# Terminal A
cd ~/tmp/claude-sandbox-scratch && claude

# Terminal B
cd ~/tmp/claude-sandbox-scratch && claude
```

Both sessions share the workspace files but run against different actors.
`kubectl ate get actors -a claude-sandbox` will show two `sess-*` actors.
Note that both sessions upload the same workspace on each `exec` — if one
session writes a file locally, the other will see it on its next command.

## Resume with warm state

Suspend a session by exiting Claude normally (`Ctrl-D` or `/exit`), then
resume it later:

```bash
cd ~/tmp/claude-sandbox-scratch
claude --resume
```

The session's ID (and thus its actor name) is stable across resume — the
hook re-resumes the same actor, and any state it accumulated (installed
packages, build caches) is still there. A second `npm install` should feel
near-instant.

## Lazy mode (alternate)

The default wiring above is **eager**: `SessionStart` creates and resumes
the actor immediately, and the actor stays Running for the whole session —
holding a worker slot even during long stretches where you're reading code,
not shelling out.

**Lazy mode** trades that for holding a worker only when a command is
actually running. It's aimed at the workflow where you come back to a
Claude session every ten minutes to make a bit more progress:

- No actor is created until the first `~/bin/substrate-sandbox-hook exec`
  call. Sessions that never shell out never touch the cluster.
- The actor is created once (lazily), then **resumed before each `exec`
  call and suspended immediately after**. Between calls it's Suspended, so
  it isn't holding a worker.
- `/workspace` state — installed packages, build caches, generated files —
  persists across suspends, so the second `npm install` is still near-
  instant. The only per-call overhead is a `kubectl ate resume` +
  `suspend` pair, which is quick on a local kind cluster.

To use lazy mode, copy `settings.json.lazy.example` into your scratch dir
instead of `settings.json.example`:

```bash
mkdir -p ~/tmp/claude-sandbox-scratch/.claude/skills
cp settings.json.lazy.example ~/tmp/claude-sandbox-scratch/.claude/settings.json
cp -r skill ~/tmp/claude-sandbox-scratch/.claude/skills/substrate-sandbox
cd ~/tmp/claude-sandbox-scratch
claude
```

The wiring difference is small: no `SessionStart` hook, and the
`PreToolUse` and `SessionEnd` entries point at `check-bash-lazy` and
`session-end-lazy` respectively. Both modes share the same `exec` path;
lazy mode is toggled by the `SUBSTRATE_SANDBOX_LAZY` env var that
`check-bash-lazy` writes to `$CLAUDE_ENV_FILE` alongside the actor name.

You can verify it's working by watching `kubectl ate get actors -a
claude-sandbox` while you interact with Claude: the actor should flip to
`ACTOR_STATE_RUNNING` for the duration of each command and back to
`ACTOR_STATE_SUSPENDED` a moment later.

## Cleanup

Suspend or delete individual actors:

```bash
kubectl ate get actors -a claude-sandbox
kubectl ate delete actor sess-xxxxxxxx -a claude-sandbox
```

Nuke everything the demo created:

```bash
./teardown.sh
```

This deletes all `sess-*` actors and scales the workerpool back to 2. It
does **not** touch: the atespace itself, the `substrate-sandbox-hook`
binary in `~/bin/`, or your scratch directory (delete those manually when
you're done).

## Troubleshooting

**"no free workers available"** — More actors are Running than the pool has
worker pods. Suspend or delete idle actors:

```bash
kubectl ate get actors -a claude-sandbox
kubectl ate suspend actor sess-yyyyyyyy -a claude-sandbox
```

Or bump replicas: `kubectl -n ate-demo-sandbox scale workerpool/sandbox-workerpool --replicas=8`.

**"SUBSTRATE_ACTOR_NAME not set in environment"** — `SessionStart`
didn't run, or its `$CLAUDE_ENV_FILE` write didn't reach the Bash preamble.
Check that `.claude/settings.json` in the scratch dir points at the built
binary and that `$HOME/bin/substrate-sandbox-hook` exists. Restarting
Claude re-runs `SessionStart`.

**Confirming a command really ran in the sandbox.** See the "Verify the
sandbox from inside Claude" section above — the sequence is a `uname -a`
smoke test that should return Linux (not Darwin), plus a `run.sh` /
`note.txt` round trip that proves your local workspace files land in
`/workspace` on the actor. If either fails, the `PreToolUse` hook is
probably not wired up: check that `.claude/settings.json` in the scratch
dir includes the `check-bash` entry and that
`$HOME/bin/substrate-sandbox-hook` is up-to-date (re-run `./setup.sh`).

**A local Bash call was denied and I actually wanted it to run locally.** The
`check-bash` hook denies every Bash call that isn't routed through the
sandbox binary. If you have a specific command that genuinely needs to run
on the laptop, the cleanest option is to edit the `check-bash` allow list
in `hook/main.go` (see `isSandboxRouted`) to also accept your command's
prefix, then rebuild. Modifying the hook is preferable to loosening the
enforcement — the whole point of the demo is that shell commands
demonstrably reach the sandbox.

## Security note

This demo is not secured. The sandbox actor executes any command you send it
with no authentication or authorization checks — the same disclaimer that
applies to the upstream sandbox demo applies here. Do not run this
configuration against anything that isn't a throwaway local cluster.

## Files in this directory

```
PLAN.md                            Design doc
README.md                          This file
hook/main.go                       The substrate-sandbox-hook binary
hook/go.mod
skill/SKILL.md                     Skill Claude reads to route shell through the sandbox
settings.json.example              Eager-mode hook wiring (SessionStart + SessionEnd + PreToolUse)
settings.json.lazy.example         Lazy-mode hook wiring (PreToolUse + SessionEnd only)
setup.sh                           Scales workerpool, creates atespace, builds binary
teardown.sh                        Prunes actors, restores workerpool replica count
```
