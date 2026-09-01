---
name: substrate-sandbox
description: This session executes ALL shell commands in a remote Agent Substrate sandbox actor, not on the local laptop. Use this skill for every shell operation — builds, tests, ls, cat, git, package installs, anything that would go through the Bash tool.
---

# Substrate Sandbox

This session is configured so that every shell command runs inside a remote Agent
Substrate sandbox actor running in a Kubernetes cluster, not on the user's laptop.
The workspace (the directory `claude` was launched from) is uploaded to the actor
on each command. Build caches and installed dependencies persist in the actor
across commands and across `--resume`.

## How to run a command

Do **not** use the built-in Bash tool directly. Instead, invoke this binary via
the built-in Bash tool:

    ~/bin/substrate-sandbox-hook exec -- <command>

Everything after `--` is the shell command. It runs inside the sandbox actor
with `/workspace` as the working directory. The binary prints the command's
stdout and stderr to the local terminal and exits with the command's exit code,
so from your point of view it behaves like a normal Bash call.

## Examples

Listing files in the workspace:

    ~/bin/substrate-sandbox-hook exec -- ls -la

Running a build:

    ~/bin/substrate-sandbox-hook exec -- 'go build ./...'

Running tests, using shell operators:

    ~/bin/substrate-sandbox-hook exec -- 'npm test 2>&1 | tail -40'

Multi-step commands — quote the whole thing so the shell inside the sandbox
sees `&&`:

    ~/bin/substrate-sandbox-hook exec -- 'cd cmd/tool && go run . --help'

## When to use the local Bash tool instead

Never, by default. A PreToolUse hook (`substrate-sandbox-hook check-bash`)
denies any Bash call whose command doesn't start with `substrate-sandbox-hook
exec --`. If you try to run `uname` or `ls` directly through the built-in Bash
tool, you'll get a deny with a reason telling you to re-issue through the
sandbox binary. This is deliberate — it's how the demo guarantees that shell
commands actually reach the sandbox actor.

The only way to run something locally is for the user to explicitly permit
that specific command in `.claude/settings.json` — do not try to work around
the deny yourself. If a deny happens, re-issue the command through
`~/bin/substrate-sandbox-hook exec --`.

## How to prove you're in the sandbox

To sanity-check that a command actually reached the actor,
`~/bin/substrate-sandbox-hook exec -- uname -a` should print Linux
(Alpine), not Darwin. `~/bin/substrate-sandbox-hook exec -- cat
/etc/os-release` should say `NAME="Alpine Linux"`.

## Things to know

- **Local files are still local.** `Read`, `Edit`, `Grep`, `Glob` continue to
  operate on the laptop's filesystem. The sandbox only receives the workspace
  contents when you run a shell command through this skill.
- **State persists between commands.** Files created by a command (build
  outputs, downloaded modules, generated code) stay in the actor's `/workspace`
  across subsequent commands. But they do **not** come back to the laptop —
  if the user needs to see a generated file, print it with `cat` through this
  skill.
- **`/workspace` is the CWD.** The command runs there by default.
- **The workspace tar skips heavy dirs.** `.git`, `node_modules`, `.venv`,
  `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.tox`, `target`, `dist`,
  `build`, `bin` are not uploaded. Their state, if any, lives only in the
  actor and is not overwritten from the laptop each call.
- **Paths outside the workspace behave differently.** Absolute paths like
  `/etc/`, `/tmp/`, `~/` refer to the sandbox actor's filesystem, not the
  laptop's. The sandbox is Alpine Linux; expect a minimal base image.
- **Errors from the binary itself** (e.g. `read pin file: no such file`) mean
  the session's setup is broken — surface these to the user rather than
  retrying blindly.
