# Design notes: chained MOCA subagents

Trimmed design doc for the demo. Operator-facing documentation is in
[README.md](README.md); this file captures the design decisions behind
the shape.

## Goal

Show a local Claude Code session delegating to a two-step chain of
isolated MOCA leaves — the arrangement MOCA (`rossoctl/serverless-
harness`) is actually designed for (leaf-session dispatch). Fills a gap
left by the sibling demos: `local_claude_code_kind_substrate_sandbox`
redirects individual shell commands into a per-session substrate actor,
and `burst_multiplex_kind_substrate` exercises a shared pool — neither
exercises subagents on serverless.

## Design decisions

### Parent orchestrates the chain, not MOCA

MOCA has no "on complete, trigger X" primitive. The parent Claude
session is the orchestrator: it starts leaves, collects their results
on a later turn, embeds completed outputs into subsequent leaves'
prompts, and surfaces final results to the operator.

### Detached sync dispatch, not the async queue

Dispatch uses the **synchronous** `POST /runs` path — no `async`
field — so MOCA runs the leaf and returns the answer in the same
response. MOCA's async queue (`async:true` + polling
`GET /runs/status`) is **not** used as the dispatch mechanism.

A blocking call would normally pin the operator's turn open and die
with the session, which is exactly what we don't want. So
`moca start` **detach-executes**: it forks a background worker
(`nohup`, fully redirected, disowned) that owns the blocking call and
writes the response to disk when it returns. `moca start` returns as
soon as the worker is forked.

Why this beats the async queue here:

- **It works on authenticated deployments.** MOCA rejects
  `async:true` with 501 whenever a token is presented, so the async
  path is structurally limited to unauthenticated installs. The sync
  path has no such restriction.
- **It keeps the pause/resume property anyway.** The worker sits
  outside Claude Code's process group, so quitting Claude doesn't
  kill it and the leaf still completes.
- **It needs no KEDA ScaledJob.** The async queue requires the
  `leaf-worker` ScaledJob to drain Redis; the sync path runs the agent
  in the Knative harness revision itself. One less moving part that
  can silently not be installed.

Two independent mechanisms protect the result:

1. The detached worker outlives the Claude session and writes
   `.result.json`.
2. MOCA persists each leaf's result cluster-side **before** writing
   the sync response, so even if the worker is killed — or Knative's
   300s request timeout cuts the connection — the result is
   recoverable via `GET /runs/status` for 24h.

So `/runs/status` is still used, but only as a **recovery fallback**,
never as the primary collection path. `moca check` prefers (1) and
falls back to (2).

Run state is held in `.moca-runs/<run-id>-<leaf-label>.json` inside
the scratch dir. One record per dispatched leaf; completed results
land in a sibling `.result.json` file. The scratch dir **is** the
resumable state — no `$HOME` lookups, no Claude Code session-id
tricks.

### Session ids use `.`, not `/`

MOCA validates `sessionId` as alphanumerics plus `-`, `_`, `.` with
alphanumeric first/last characters. The natural-looking
`<run-id>/<leaf-label>` is therefore rejected at the API boundary
before any work starts, so the scheme is `<run-id>.<leaf-label>`
(e.g. `review-123.diagnose`). The CLI validates the same rule locally
so an illegal id fails at `start` without consuming the leaf label.

### Fixture seeded directly into the sandbox pool

MOCA accepts `repoUrl`+`ref` to git-fetch inside the sandbox, but that
makes the fixture external to this directory. Instead, `setup.sh`
copies `example_repo/` into **every** pool-labeled sandbox pod at
`/workspace/<run-id>/repo` via `kubectl cp`.

Every pod in the pool needs the fixture because a leaf leases an
arbitrary pool pod — the demo can't predict which one it lands on.

An earlier iteration provisioned a PVC through `lib/ctx.sh` (a
`kubectl`-only shim mirroring `contextctl` verbs) so the workspace
could be mounted `readOnly: true`. That approach is retired: this
MOCA install exposes no per-run mount-posture controls, so the PVC
bought nothing the pool seeding doesn't. `lib/ctx.sh` remains in the
tree as a leftover and is **not** sourced by the current `setup.sh`.

### One dispatch path, no workload catalog

An earlier design used two pre-registered workloads — one mounting
the workspace `readOnly: true` for the researcher, one `readOnly:
false` for the fixer — to make the capability split
substrate-enforced.

That is not available on this install. `moca start` sends
`kind:"prompt"` with no `workload`, no `workspaceRef`, and no
per-run `readOnly` flag, and there is no `/workloads` endpoint to
register posture-specific workloads against. So the
researcher-vs-fixer split is **prompt-only** here: it lives in the
leaf prompt text ("do not modify files" vs "apply this fix"), and a
non-compliant leaf could ignore it.

This is a real reduction in what the demo proves, and the README says
so plainly rather than implying enforcement. Restoring
substrate-enforced read-only mounts needs an upstream MOCA surface for
per-run mount posture.

### Vendored stand-in library, not a real npm package

`example_repo/node_modules/lib/` is a hand-rolled module that only
exports `newName`. `src/index.js` calls `lib.oldName`, so tests fail with
`TypeError: lib.oldName is not a function`. Keeps the demo reproducible
indefinitely — no dependency on upstream API history.

The fix B applies is a one-line rename in `src/index.js`. Tests pass.

### Skill is mechanism, not flow

A single `SKILL.md` tells Claude:

- `Task` is denied; the only subagent path is this skill.
- There is no workload catalog on this install; dispatch takes no
  workload argument and posture rules go in the prompt text.
- Three procedures: **start a leaf** (`moca start` — writes a record
  and forks the detached worker), **check a leaf** (`moca check` —
  reads the worker's `.result.json`, falling back to `/runs/status`
  only if the worker was lost), **list pending runs** (`moca list`).
- Prompt-authoring guidance for leaves (state the workspace path, pass
  forward context from earlier leaves verbatim, describe the
  deliverable).
- That `moca start` must not be wrapped in anything that waits on it,
  and `moca check` must not be run in a polling loop.
- How to sequence leaves if the operator asks for a chain.

The skill does **not** prescribe how many leaves to run, in what
order, or with what prompts. That orchestration lives in the
operator's requests and the parent's judgment. The multi-prompt
"diagnose, then fix" flow this demo illustrates is operator-driven;
`moca-dispatch` would work the same way for a one-leaf review, a
three-leaf fan-out, or anything else the operator asks for. The
README's "Run a session" section carries example operator prompts as
illustration, not as part of the skill contract.

### Settings deny `Task`, allow only the `moca` CLI

`settings.json.example`:

- `permissions.deny`: `Task` — forces the skill path.
- `permissions.allow`: `Bash(moca start*)`, `Bash(moca check*)`,
  `Bash(moca list*)`, plus `jq` for parsing.

Routing through a small CLI rather than raw `curl` is deliberate: the
permission prompt reads `moca start review-123.diagnose <file>`
instead of a many-flag `curl` line, which makes it legible as "this
is going to MOCA, not running locally" — the operator's visual
confirmation at the moment of dispatch. It also guarantees the
on-disk record shape a resumed session depends on, and gives the
detached-worker fork somewhere to live.

Local file ops on `.moca-runs/` go through Claude's Read/Write/Edit
tools and don't need extra permissions.

No hooks. The operator-side substrate is: skill + settings + the
`moca` CLI + a running port-forward.

## Scope limits (what's honest)

- **Isolation is prompt-only, not substrate-enforced.** There is no
  per-run read-only mount on this install, so the researcher and the
  fixer get identical substrate posture. "Do not modify files" is a
  sentence in a prompt, not a mount flag. This is the biggest honesty
  gap in the demo and the README states it directly.
- **A's "no exec / no network" is prompt-only too.** MOCA gives every
  leaf the same seven tools (`read, write, edit, ls, find, bash,
  grep`), there's no per-leaf `tools` allowlist on `LeafEnvelope`, and
  there is no web-fetch tool anywhere in MOCA. A non-compliant
  researcher could run `bash`. Honest capability splits need upstream
  MOCA changes.
- **Leaves share sandbox pods.** The pool is shared and the fixture is
  seeded per-run-id, so two concurrent runs are separated by path, not
  by a boundary. Fine for a single-operator demo; not a security
  claim.
- **What the demo does prove:** the parent never runs the subagent's
  work locally (`Task` is denied and dispatch is visible in the
  permission prompt), the work executes on cluster-side infrastructure
  that scales to zero, and the chain survives the operator quitting
  Claude mid-run.

## Verification arc (what the README walks through)

1. MOCA up on kind; port-forward live.
2. `./setup.sh` seeds `example_repo/` into every pool sandbox pod and
   stages scratch (settings, skill, `bin/moca`, `.moca-runs/`,
   `MOCA.md`).
3. Operator runs Claude from scratch, pastes the "dispatch a
   diagnosis subagent" prompt.
4. Claude reads the skill, does **not** invoke `Task` (deny fires if
   it tries).
5. Permission prompt shows `moca start review-<ts>.diagnose <file>` —
   short, legible, and clearly not a local shell execution.
6. Claude writes a record to `.moca-runs/`, forks the detached worker,
   reports the session id, and returns control. The leaf is now
   running on the cluster.
7. **Operator Ctrl-C's Claude** (optional but worth demonstrating).
   The detached worker keeps holding the call; the leaf keeps running.
8. Operator restarts Claude from the scratch dir, says "check on that
   subagent". `moca list` shows the pending record, `moca check` reads
   the worker's `.result.json`, Claude surfaces the diagnosis.
9. Operator pastes the "dispatch a fixer with that diagnosis" prompt.
   Claude embeds the diagnosis verbatim in leaf 2's prompt and starts
   it.
10. Operator asks for the result; Claude surfaces the diff and test
    outcome.
11. `kubectl -n default get pods -w` shows the
    `serverless-harness-*` revision cold-starting on dispatch and
    scaling back to zero when idle. (No `leaf-worker-*` pods — those
    belong to the async queue this demo doesn't use.)
12. Side check: the fix landed on a sandbox pod, not locally —
    `kubectl -n default exec sandbox-0 -- cat
    /workspace/<run-id>/repo/src/index.js` shows the rename, while the
    operator's `example_repo/` is untouched.

## Out of scope

- Standing up MOCA — prerequisite, documented in README.
- Substrate-enforced read-only workspaces — needs a per-run mount
  posture surface upstream. Prompt-only for now.
- Per-leaf tool allowlists on `LeafEnvelope` — upstream MOCA change.
- Web-fetch tool for the researcher — upstream MOCA change.
- Fan-out beyond A → B — single-chain is the whole demo.
- Using MOCA's async queue — the detached sync path gives the same
  pause/resume property, works on authenticated installs, and needs no
  KEDA ScaledJob. Supporting both modes would roughly double the skill
  and bury the main thread.
- Returning files from the leaf. Only the response text comes back;
  anything the operator needs to see must be asked for as text in the
  prompt.
