# Local Claude Code with a Kind-hosted Substrate Sandbox

Claude Code runs on your laptop; every shell command it issues runs inside a
per-session sandbox actor on an
[Agent Substrate](https://github.com/agent-substrate/substrate) cluster in
kind. Each Claude session gets its own actor and `--resume` reuses it, so
build caches and installed dependencies survive across days. Nothing
upstream is modified — everything demo-specific lives in this directory.

## How it works

Three mechanisms cooperate:

1. **Lifecycle hooks (`SessionStart`, `SessionEnd`).** Create/resume the
   session's actor on start, suspend on end. `SessionStart` also writes
   `export SUBSTRATE_ACTOR_NAME=<name>` to `$CLAUDE_ENV_FILE`, which Claude
   sources before every Bash command — that's how `exec` finds its actor.
   The env-file is per-session, so two sessions in one scratch dir don't
   collide.

2. **A skill (`substrate-sandbox`).** Tells Claude that every shell
   command must be invoked as `~/bin/substrate-sandbox-hook exec --
   <command>`. The binary tars the workspace, POSTs to Substrate's
   `/process` endpoint, and prints the sandbox's stdout/stderr locally.

3. **A `PreToolUse` hook on Bash** (`check-bash`). Denies any Bash call
   that isn't routed through the sandbox binary — without this, the skill
   is advisory and Claude can silently run commands on the laptop.

Read/Edit/Grep/Glob still operate locally — only shell is redirected.

There are two flavors:

- **Eager** (default, `settings.json.example`) — actor is created and
  kept Running for the whole session.
- **Lazy** (`settings.json.lazy.example`) — actor is created on first
  shell command, resumed before each `exec` and suspended after, so a
  worker slot is only held while a command is actually running. See
  "Lazy mode" below.

For the full design, see [PLAN.md](PLAN.md).

## When to run on substrate vs. locally (vs. a git worktree)

Substrate execution is worth the overhead when you need something a laptop
can't cheaply provide:

- **Untrusted or risky code** — LLM-generated shell, third-party tools, or
  anything you don't want touching your real filesystem, keychain, or
  network.
- **Reproducible environments** — the task needs a specific OS, kernel, or
  package set. Every actor here starts from the same Alpine image.
- **Long-running or resumable work** — jobs that should outlive your
  terminal or survive laptop sleep. `--resume` re-attaches to the same
  warm actor.
- **Parallel fan-out** — many concurrent sessions without them fighting
  over the same working tree, ports, or caches.
- **Resource limits** — memory, CPU, or disk that you don't want tied up
  locally.

Stay local when the task is fast, trusted, and benefits from your
dotfiles, credentials, or direct access to your working tree.

**Git worktree is not a substitute.** Worktree solves exactly one thing
on that list — filesystem isolation between parallel branches on the same
machine — and even that only partially, since worktrees still share your
kernel, user, network, and credentials. It does nothing for untrusted
code, environment reproducibility, resource limits, or detached
long-running jobs. Worktree and substrate compose: an agent can work in
its own worktree *and* execute risky commands in its own sandbox actor.

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

One flow proves three things: shell runs on Alpine, laptop files land in
`/workspace`, and two sessions keep independent sandbox state.

**On the laptop**, drop a file into the scratch dir so there's something
to see:

```bash
cd ~/tmp/claude-sandbox-scratch
echo "hello from the laptop" > note.txt
```

**Open two Claude sessions in the same scratch dir** (Terminal A and
Terminal B, both `cd ~/tmp/claude-sandbox-scratch && claude`). Each gets
its own actor — `kubectl ate get actors -a claude-sandbox` will show two
`sess-*` actors.

In **session A**, paste:

> Run `uname -a` and `cat /etc/os-release`. Then `ls` the workspace,
> `cat note.txt`, and `touch only-in-A.txt`. Show me the raw output.

In **session B**, paste the same thing but with `only-in-B.txt`.

You should see, in each session:

- The first attempt goes through the built-in Bash tool and is **denied**
  by the `PreToolUse` hook. Claude re-issues via
  `~/bin/substrate-sandbox-hook exec -- ...` — the permission prompt
  literally shows that string, which is your visual proof.
- `uname -a` returns `Linux ...` (not `Darwin`); `/etc/os-release` says
  `NAME="Alpine Linux"`.
- `ls` includes `note.txt` — proof the laptop tarball extracted into
  `/workspace`. `cat note.txt` prints `hello from the laptop`.

Then, in **each session**, paste:

> `ls` the workspace again.

- Session A sees `only-in-A.txt` but **not** `only-in-B.txt`.
- Session B sees `only-in-B.txt` but **not** `only-in-A.txt`.
- Neither file exists on the laptop (`ls ~/tmp/claude-sandbox-scratch`).

The last part is the demo's key state property: each `exec` re-uploads
the laptop scratch dir over `/workspace`, but tar overwrites matching
paths without deleting unmatched ones — so files a session created inside
its own actor survive, and the other session's actor never sees them.
Laptop-side edits are shared across sessions; sandbox-side writes are
per-session.

**If any of this fails** (`Darwin` instead of `Linux`, empty `ls`, no
permission prompt starting with `substrate-sandbox-hook exec --`): re-run
`./setup.sh`, re-copy `settings.json.example` into
`.claude/settings.json`, confirm the port-forwards are up, and restart
Claude.

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

Eager mode (the default) keeps the actor Running for the whole session,
holding a worker slot even when you're just reading code. **Lazy mode**
only holds a worker while a command is running — aimed at the workflow
where you come back to a Claude session every ten minutes.

- `SessionStart` does no cluster work; it just publishes the actor name
  and `SUBSTRATE_SANDBOX_LAZY=1`. Sessions that never shell out never
  touch the cluster.
- The actor is created on the first `exec`, then resumed before each
  `exec` and suspended after. `/workspace` state persists across
  suspends, so the second `npm install` is still near-instant.

To use it, copy `settings.json.lazy.example` in place of
`settings.json.example`:

```bash
cp settings.json.lazy.example ~/tmp/claude-sandbox-scratch/.claude/settings.json
```

Verify by watching `kubectl ate get actors -a claude-sandbox` as you
interact with Claude — the actor flips to `RUNNING` for each command and
back to `SUSPENDED` a moment later.

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

**A local Bash call was denied and I actually wanted it to run locally.**
The `check-bash` hook denies any Bash call not routed through the sandbox
binary. To exempt a specific command, edit the allow list in
`hook/main.go` (see `isSandboxRouted`) and rebuild — better than
loosening the enforcement, since the whole point is that shell commands
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
settings.json.lazy.example         Lazy-mode hook wiring (SessionStart writes env only; no cluster work up front)
setup.sh                           Scales workerpool, creates atespace, builds binary
teardown.sh                        Prunes actors, restores workerpool replica count
```
