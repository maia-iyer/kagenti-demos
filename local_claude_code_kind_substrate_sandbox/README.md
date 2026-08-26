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

Two mechanisms cooperate:

1. **Lifecycle hooks (`SessionStart`, `SessionEnd`).** These call
   `substrate-sandbox-hook` to create/resume the session's actor on start and
   suspend it on end. `SessionStart` writes the actor's name to a pin file
   at `<scratch>/.claude/substrate-sandbox-actor`.

2. **A skill (`substrate-sandbox`).** This tells Claude that every shell
   command must be invoked as:

       ~/bin/substrate-sandbox-hook exec -- <command>

   The binary reads the pin file to find the actor, tars up the workspace,
   POSTs to Substrate's `/process` endpoint with the workspace and command
   composed together, and prints the sandbox's stdout/stderr locally. Exit
   code is the sandbox command's exit code.

Read/Edit/Grep/Glob still operate on your laptop's local filesystem — only
shell commands are redirected.

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
./hack/install-ate.sh --deploy-ate-system

# 3. Counter demo — proves snapshot storage works on kind.
./hack/install-ate.sh --deploy-demo-counter

# 4. Sandbox demo — deploys the WorkerPool and ActorTemplate we reuse.
./hack/install-ate.sh --deploy-demo-sandbox
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
directories; the hook rewrites files under `.claude/` there.

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

## Concurrent sessions

Two concurrent Claude sessions must use **different** scratch directories.
The pin file lives in the scratch dir, so two sessions in the same scratch
dir would fight over it — `SessionStart` refuses to overwrite a pin file
pointing at a different actor, so the conflict is loud (an error at session
start), not silent.

Simplest pattern:

```bash
# Session A
mkdir -p ~/tmp/scratch-a/.claude/skills
cp settings.json.example ~/tmp/scratch-a/.claude/settings.json
cp -r skill ~/tmp/scratch-a/.claude/skills/substrate-sandbox
cd ~/tmp/scratch-a && claude

# Session B (in another terminal)
mkdir -p ~/tmp/scratch-b/.claude/skills
cp settings.json.example ~/tmp/scratch-b/.claude/settings.json
cp -r skill ~/tmp/scratch-b/.claude/skills/substrate-sandbox
cd ~/tmp/scratch-b && claude
```

Both sessions run in parallel, each backed by its own actor.

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

**"read pin file: no such file"** — `SessionStart` didn't run. Check that
`.claude/settings.json` in the scratch dir points at the built binary and
that `$HOME/bin/substrate-sandbox-hook` exists.

**Claude is running commands locally instead of through the skill.** The
skill's description tells Claude when to use it, but Claude has discretion.
If it's ignoring the skill, remind it in the prompt ("use the substrate-sandbox
skill for all shell commands") — or, more robust, add a short note to
`.claude/CLAUDE.md` in the scratch dir saying the same thing.

**"another substrate-sandbox session is active in this scratch dir"** —
You started a second Claude session in a scratch dir that already has an
active session. Use a different scratch dir, or if the prior session ended
abnormally, delete the pin file:

```bash
rm ~/tmp/scratch/.claude/substrate-sandbox-actor
```

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
settings.json.example              Hook wiring (SessionStart + SessionEnd)
setup.sh                           Scales workerpool, creates atespace, builds binary
teardown.sh                        Prunes actors, restores workerpool replica count
```
