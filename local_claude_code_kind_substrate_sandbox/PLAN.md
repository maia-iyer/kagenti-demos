# Plan: Local Claude Code with a Kind-hosted Substrate Sandbox

## Goal

A demo where Claude Code runs locally on the developer's laptop and executes shell commands (builds, tests, scripts) inside an Agent Substrate sandbox actor running in a local kind cluster. Each Claude Code session gets its own actor, so many sessions can run concurrently and each one's build/tool state persists across `--resume`.

Claude Code stays the source of truth for source files: it reads and edits them locally with its built-in tools. The sandbox is a remote exec target that receives an upload of the current workspace on every command.

## Where things live

**Nothing changes upstream.** The `agent-substrate` sandbox image is used as-is via its existing `/process` endpoint. The user's `--deploy-demo-sandbox` (run once, as part of their kind prep) already deploys everything sandbox-server-side that we need.

**In `kagenti-demos/local_claude_code_kind_substrate_sandbox/` (this repo):**
- Everything that is demo-specific: the hook binary source, the skill markdown, the `.claude/settings.json` example, the setup and teardown scripts, and the docs.
- We reuse the existing `ate-demo-sandbox/sandbox-template` ActorTemplate. The setup script scales the existing `sandbox-workerpool` to 5 replicas; no template of our own needed.

**On the developer's laptop, per session:**
- A **scratch project directory** the user creates (e.g. `~/tmp/claude-sandbox-scratch/`) is where `claude` runs. This directory holds:
  - `.claude/settings.json` — wires the SessionStart and SessionEnd lifecycle hooks.
  - `.claude/skills/substrate-sandbox/SKILL.md` — instructs Claude to invoke the sandbox binary for every shell operation.
  Everything Claude does — including its uploaded workspace — is scoped to this scratch dir. The user throws it away and recreates it at will.
- The hook binary lives at a stable installed path (default `~/bin/substrate-sandbox-hook`, configurable in setup.sh). The skill and settings reference that absolute path.

### Workspace upload via the existing `/process` endpoint

The existing sandbox server exposes only `POST /process`, which runs an arbitrary shell command in the actor. The binary composes workspace-upload + command-execution into a single `/process` call:

```
sh -c 'mkdir -p /workspace \
     && printf %s "$B64" | base64 -d | tar -xzf - -C /workspace \
     && cd /workspace \
     && <user command>'
```

The base64-encoded gzipped tar is passed via `ProcessRequest.EnvVars["B64"]` rather than inlined in the command string — cleaner and avoids shell-escaping headaches. `EnvVars` is already supported by the existing `/process` handler (see `demos/sandbox/main.go` lines 86-91), no server changes needed.

Actor filesystems persist across suspend/resume, so unmatched paths (`node_modules/`, `target/`, `.pytest_cache/`) survive between calls. Only paths present in the current tar are overwritten.

Tradeoff accepted: base64-in-JSON adds ~33% wire overhead. Fine at demo workspace sizes (single-digit MB gzipped). If any real project pushes this uncomfortably, we split into two `/process` calls — one uploads via a heredoc to a scratch file, second executes — still against the unchanged server.

## Approach: skill for redirect, hooks for lifecycle

The initial design used `PreToolUse` hooks to transparently intercept and redirect the built-in `Bash` tool. Schema verification showed `PreToolUse` supports only `permissionDecision: allow | deny | ask` — there is no documented way to substitute synthetic tool output. Rather than build on a `deny`-with-output hack (every transcript entry would read as denied) or gamble on undocumented behavior, we split the concern:

- **Skill (redirect):** A Markdown skill at `.claude/skills/substrate-sandbox/SKILL.md` tells Claude that in this session, every shell operation must go through `~/bin/substrate-sandbox-hook exec -- <command>` instead of the built-in Bash tool. Claude invokes the binary via its normal Bash tool. The binary prints real stdout/stderr; Claude sees them exactly like any other command output. No hook protocol involved for the redirect path.
- **Hooks (lifecycle):** A `SessionStart` hook calls `ateapi.CreateActor` (or `ResumeActor` on `AlreadyExists`). A `SessionEnd` hook calls `SuspendActor`. These are pure lifecycle — no output substitution, so the `PreToolUse` schema question doesn't apply.

Invocation style is **explicit tool-shape**: SKILL.md tells Claude "every Bash operation in this session runs through `substrate-sandbox-hook exec`." The demo's story is "look how seamless it is to redirect all execution to a sandbox actor"; selective per-command judgment would muddle it. If the user genuinely needs a purely-local Bash call, they can bypass the skill by asking explicitly.

## Non-goals

- Transparent `PreToolUse` interception of the built-in Bash tool.
- Making the sandbox the workspace (Read/Edit stay local; only shell commands are redirected).
- Bidirectional sync of build artifacts back to the laptop (upload-only; artifacts stay in the actor for reuse on the next call).
- Any changes to Claude Code itself.
- Any MCP server or long-running subprocess.
- Any changes to `agent-substrate`.

## Prerequisites the demo assumes are already done

The kind cluster and Substrate install are **not** set up by this demo. The user runs the existing counter demo first, which does all of that:

1. `substrate/hack/create-kind-cluster.sh` — creates the kind cluster and local registry.
2. `substrate/hack/install-ate.sh --deploy-ate-system` — installs Substrate.
3. `substrate/hack/install-ate.sh --deploy-demo-counter` — deploys the counter WorkerPool and ActorTemplate, which also proves the snapshot-storage story works on kind.

In addition to counter, the user runs `substrate/hack/install-ate.sh --deploy-demo-sandbox` once — this deploys the existing `ate-demo-sandbox` namespace, WorkerPool, and `sandbox-template` ActorTemplate. Our demo reuses that template directly.

Then the user runs `setup.sh` from this directory, which does the following:

4. `kubectl -n ate-demo-sandbox scale workerpool/sandbox-workerpool --replicas=5` — scale to hold multiple concurrent sessions.
5. `kubectl ate create atespace claude-sandbox` — one-time atespace creation for our per-session actors (idempotent; script tolerates AlreadyExists).
6. `go build -o ~/bin/substrate-sandbox-hook ./hook` — builds the local binary to a stable installed path.
7. Print instructions telling the user to:
   - Start port-forwards for `ateapi` (8080) and `atenet-router` (8000) in separate terminals.
   - Create a scratch directory, e.g. `mkdir -p ~/tmp/claude-sandbox-scratch/.claude/skills`.
   - Copy `settings.json.example` from this repo into `~/tmp/claude-sandbox-scratch/.claude/settings.json`.
   - Copy the `skill/` directory into `~/tmp/claude-sandbox-scratch/.claude/skills/substrate-sandbox/`.
   - `cd ~/tmp/claude-sandbox-scratch && claude`.

The scratch directory is the workspace the binary will tar and upload on each command. The user can put whatever they want in it — a git clone of some project, a fresh scaffolded app, or nothing at all.

## Architecture

```
  ┌─────────────────────────┐         ┌──────────────────────────────┐
  │  Laptop                 │         │  kind cluster                │
  │                         │         │                              │
  │  ┌───────────────────┐  │         │  ┌────────────────────────┐  │
  │  │  Claude Code CLI  │  │         │  │  ateapi (gRPC)         │  │
  │  │                   │  │         │  │  Create/Resume/Suspend │  │
  │  │  Read/Edit/Grep   │──┼─ local  │  └────────────────────────┘  │
  │  │  Bash ─┐          │  │         │              ▲               │
  │  └────────┼──────────┘  │         │              │               │
  │           │             │         │  ┌───────────┴────────────┐  │
  │           │ invokes     │         │  │  atenet-router (HTTP)  │  │
  │           ▼             │         │  │  routes by Host header │  │
  │  ┌───────────────────┐  │         │  │                        │  │
  │  │  substrate-       │──┼──HTTP───┼─▶│                        │  │
  │  │  sandbox-hook     │  │         │  └───────────┬────────────┘  │
  │  │   exec  (skill)   │  │         │              │               │
  │  │   session-start ◀─┼──┼─hooks───┼──gRPC─┐      ▼               │
  │  │   session-end   ◀─┼──┼─hooks   │       │  ┌────────────────┐  │
  │  └───────────────────┘  │         │       │  │ sandbox actor  │  │
  │                         │         │       │  │ (one/session)  │  │
  │                         │         │       │  │ POST /process  │  │
  │                         │         │       │  └────────────────┘  │
  │                         │         │       ▼                      │
  │                         │         │  ateapi processes            │
  │                         │         │  lifecycle calls             │
  └─────────────────────────┘         └──────────────────────────────┘
```

### What's local vs remote

**Local (untouched by this demo):**
- Claude Code process, its config, `~/.claude/`, project `CLAUDE.md`, `.mcp.json`, skills, agents, memory, transcripts.
- All source files. Read/Edit/Grep/Glob hit the local filesystem.

**Local (new, part of this demo):**
- `substrate-sandbox-hook` binary — a short-lived CLI invoked by (a) Claude via the skill for `exec`, and (b) Claude Code hooks for lifecycle. No daemon, no long-running process.
- A `.claude/settings.json` fragment wiring the binary into `SessionStart` and `SessionEnd`.
- A `.claude/skills/substrate-sandbox/SKILL.md` telling Claude to route all shell operations through the binary.

**Remote (kind cluster):**
- One actor per Claude session, named `sess-<8-char-session-hash>`.
- The actor's `/workspace` directory, which accumulates uploaded source plus any state the tools leave behind (build caches, `node_modules`, `.pytest_cache`, etc.).

### Session ID plumbing (the pin file)

Schema verification confirmed `CLAUDE_SESSION_ID` is **not** an environment variable. The session ID is delivered only via stdin JSON to hooks. Consequences:

- **SessionStart / SessionEnd hooks:** read stdin, parse the JSON, extract `session_id`.
- **`exec` subcommand (invoked by the skill via Claude's Bash tool):** does NOT have access to the session ID — it's a regular subprocess and Claude Code passes no session identifier to tool subprocesses via env or stdin. To connect an exec call to the right actor, `SessionStart` writes the derived actor name into a **pin file** at `$CLAUDE_PROJECT_DIR/.claude/substrate-sandbox-actor`. The `exec` subcommand reads this file to know which actor to target. `SessionEnd` deletes the pin file.

Actor name: `sess-<first-8-hex-chars-of-sha256(session_id)>`.

**Concurrent-session semantics.** The pin file's location is scoped to `CLAUDE_PROJECT_DIR`. Two concurrent Claude sessions running in *different* scratch dirs each have their own pin file — no interaction. Two concurrent sessions in the *same* scratch dir would fight over one pin file, so `SessionStart` refuses to overwrite a pin file whose contents disagree with the new session's derived actor name. The user gets a clear error telling them to use a different scratch dir. This is the demo's normal shape: one scratch dir per concurrent session. `--resume` within the same scratch dir is fine — the session ID (and thus the actor name) is stable, so SessionStart's check passes.

### Lifecycle hooks

`.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "$HOME/bin/substrate-sandbox-hook session-start"}]}
    ],
    "SessionEnd": [
      {"hooks": [{"type": "command", "command": "$HOME/bin/substrate-sandbox-hook session-end"}]}
    ]
  }
}
```

`$HOME` expands in shell-form commands (no `args` field), confirmed by the docs.

**SessionStart flow:**
1. Read hook input JSON from stdin, extract `session_id`.
2. Compute actor name.
3. Call `ateapi.CreateActor(name, template=ate-demo-sandbox/sandbox-template, atespace=claude-sandbox)`.
4. On `AlreadyExists`, call `ateapi.ResumeActor(name)` instead. This handles `--resume`, which the docs confirm fires SessionStart with `source: "resume"` and the same `session_id`.
5. Write the actor name to `<CLAUDE_PROJECT_DIR>/.claude/substrate-sandbox-actor`.
6. Exit 0. On any failure, exit non-zero with stderr — Claude Code surfaces this to the user.

**SessionEnd flow:**
1. Read hook input JSON from stdin, extract `session_id`.
2. Compute actor name.
3. Call `ateapi.SuspendActor(name)`.
4. Delete the pin file.
5. Exit 0. Suspend failure is logged but not fatal (session is already ending).

Actor cleanup (delete, not suspend) is manual: `kubectl ate delete actor sess-xxxx -a claude-sandbox`. The teardown script prunes all `sess-*` actors in the atespace.

### The skill: redirecting shell operations

`.claude/skills/substrate-sandbox/SKILL.md` frontmatter + body tells Claude that in this session, **every** shell operation runs through the sandbox binary. Rough shape:

```markdown
---
name: substrate-sandbox
description: In this session, ALL shell/Bash operations run in a remote Agent Substrate sandbox actor. Use for every command — builds, tests, ls, cat, everything.
---

# Substrate Sandbox

This session is configured to execute all shell operations in a remote sandbox actor
running on Agent Substrate. **Do not use the built-in Bash tool for shell commands.**

To run any shell command, invoke:

    ~/bin/substrate-sandbox-hook exec -- <command>

... (etc.)
```

The frontmatter's `description` is what Claude reads when deciding to invoke the skill. Because the desired UX is "all shell goes through the sandbox," we make the description broad and unambiguous.

**Note on `exec` mechanics.** Claude invokes `substrate-sandbox-hook exec -- <command>` via its normal Bash tool. That Bash tool runs the binary as a local subprocess, so the redirect is: Claude → local Bash → local binary → HTTP → remote actor → process. Claude sees the binary's stdout/stderr as if any other local command produced them — real, uncolored, uncomplicated by any hook protocol.

Per-invocation behavior of `exec`:
1. Parse argv: everything after `--` is the user command.
2. Read the actor name from `$CLAUDE_PROJECT_DIR/.claude/substrate-sandbox-actor`. If missing, print a helpful error to stderr and exit non-zero — this means SessionStart didn't run or failed.
3. Determine workspace root = `$CLAUDE_PROJECT_DIR` (the scratch dir).
4. Tar+gzip the workspace root, skipping:
   - `.git/`
   - `node_modules/`, `.venv/`, `venv/`, `__pycache__/`, `.pytest_cache/`, `.mypy_cache/`, `.tox/`
   - `target/`, `dist/`, `build/`, `bin/`
   - v1 uses this hard-coded list; v2 shells out to `git ls-files --cached --others --exclude-standard` if the project is a git repo.
5. Base64-encode the tar bytes.
6. Take a `flock` on `/tmp/substrate-sandbox-hook-<actor>.lock` — serializes concurrent `exec` calls in one session (Claude can run tools in parallel).
7. Compose a single `/process` request:
   - `Command`: `["sh", "-c", "mkdir -p /workspace && printf %s \"$B64\" | base64 -d | tar -xzf - -C /workspace && cd /workspace && <user command>"]`
   - `EnvVars`: `{"B64": "<base64-blob>"}`
   - `Host` header: `resources.ActorDNSName(actorRef)` for the atenet-router.
8. POST to `http://localhost:8000/process`, decode the `ProcessResponse`.
9. Print `resp.Stdout` to the binary's stdout, `resp.Stderr` to its stderr.
10. Exit with `resp.ExitCode`. A non-zero exit code from the sandboxed command is a normal command failure — Claude reads exit code, stdout, and stderr just like any other Bash run.

Transport errors (couldn't reach atenet, pin file missing, actor not resumed) cause the binary to exit non-zero with a diagnostic on stderr. Claude sees these as command failures and surfaces them to the user.

**Wire-size mitigation.** The base64 blob lives in the `EnvVars` map. At demo workspace sizes (single-digit MB gzipped) this is fine. If a workspace pushes uncomfortably large, we split into two `/process` calls: first uses a heredoc to write the tar into a scratch file on the actor, second extracts and runs. Still zero server-side changes.

### WorkerPool sizing

The existing `sandbox-workerpool` (from `--deploy-demo-sandbox`) sets `replicas: 2`. Not enough for our "many concurrent sessions" story. `setup.sh` runs `kubectl -n ate-demo-sandbox scale workerpool/sandbox-workerpool --replicas=5` in place; `teardown.sh` scales it back to 2. No manifest of our own required.

## Files this demo adds

```
kagenti-demos/local_claude_code_kind_substrate_sandbox/
  PLAN.md                            # this file
  README.md                          # user-facing walkthrough (written after implementation)
  hook/
    main.go                          # single binary with three subcommands: session-start, session-end, exec
    go.mod
  skill/
    SKILL.md                         # skill markdown Claude reads to route shell through the binary
  settings.json.example              # SessionStart + SessionEnd hook wiring
  setup.sh                           # scales sandbox workerpool, creates atespace, builds binary
  teardown.sh                        # scales workerpool back, prunes sess-* actors
```

**No upstream changes.** The demo consumes the existing `agent-substrate` sandbox image and `/process` endpoint unchanged.

## Implementation order

1. **Verified.** Hook schema — `SessionStart`, `SessionEnd`, `PreToolUse` are correct event names. `CLAUDE_SESSION_ID` is NOT an env var (session ID comes via stdin JSON). Session ID is stable across `--resume` (SessionStart fires with `source: "resume"`). `PreToolUse` cannot substitute tool output — hence the skill pivot. `$HOME` expands in shell-form commands.
2. **Manual smoke test of the `/process` compose trick.** Against a running sandbox actor (or a fresh one), hand-craft the `sh -c 'mkdir -p /workspace && printf %s "$B64" | base64 -d | tar -xzf - -C /workspace && cd /workspace && ls'` call with `EnvVars["B64"]` set, via `curl` or the existing `demos/sandbox/client/`. Confirm the tar unpacks and the ensuing command sees the files.
3. Write `hook/main.go` — three subcommands sharing a small `ateapi` client helper. Start with `exec` against a hardcoded actor name; add `session-start`/`session-end` and pin-file plumbing second.
4. Write `skill/SKILL.md` — the instructions telling Claude to route all shell through the binary.
5. Wire `settings.json.example`, `setup.sh`, `teardown.sh`, and README.
6. End-to-end test: two `claude` sessions in two different scratch dirs concurrently, verify two actors in `kubectl ate get actors -a claude-sandbox`, verify `--resume` picks up the same actor with a warm build cache (e.g., a second `npm install` is fast).

## What could bite us

- **Claude ignoring the skill.** The skill relies on Claude reading its description and choosing to route through the binary. If the description is weak, Claude may just call the built-in Bash. Mitigation: make the skill description unambiguous ("in this session, ALL shell operations must go through..."), and put a short reminder in the scratch dir's `CLAUDE.md` too.
- **Pin file lifetime and concurrent sessions.** The pin file at `<scratch>/.claude/substrate-sandbox-actor` is written by SessionStart. Two concurrent sessions in the *same* scratch dir would collide over it; SessionStart guards against this by refusing to overwrite a pin file that names a different actor. Users get a clear error telling them to use a different scratch dir. If a session crashes and leaves a stale pin file behind, restarting the *same* session (same session_id) is fine — the pin matches the derived name and SessionStart proceeds; starting a *fresh* session in the same scratch dir requires deleting the stale file first. Missing pin file at exec time is a clear error message telling the user SessionStart didn't run.
- **Concurrent exec calls.** Claude can invoke tools in parallel. The `exec` subcommand's per-actor `flock` handles this.
- **Workspace boundary drift.** If the user's project pulls from a sibling module or a shared cache dir outside the scratch, the upload won't include it. README calls this out.
- **Large workspaces.** Full-workspace tar on every command is fine for demo scale; a real product would want content-addressed diffs. Not solving here.
- **Actor cold start on first `exec`.** SessionStart hook does the resume eagerly, so the first exec pays only tar+network cost, not schedule+restore.
- **Session ID stability across `--resume`.** Docs confirm stability; SessionStart fires with `source: "resume"` and the same `session_id`. Our approach relies on this.
- **Claude doesn't know the shell is remote.** The skill tells it, but it may still run commands assuming laptop-local paths (`~/`, `/etc/`, absolute paths outside the workspace). Mostly fine because the workspace is uploaded, but worth calling out in the demo's CLAUDE.md.
