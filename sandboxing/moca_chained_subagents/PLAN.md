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
session is the orchestrator: it starts leaves, polls their status
later, embeds completed outputs into subsequent leaves' prompts, and
surfaces final results to the operator.

### Async dispatch, not sync

Dispatch uses `POST /runs` + `GET /runs/status?sessionId=…` rather
than a blocking sync `/runs` call. Reasons:

- The operator can quit Claude between dispatch and collection. The
  leaf runs to completion on the cluster regardless, and a resumed
  Claude session reconstructs state from disk.
- Long-running leaves don't tie up the Claude session.
- The handle-and-poll shape is honest about what's happening: work
  lives cluster-side, not inside the HTTP connection.

Trade-off: async is only available on unauthenticated MOCA
deployments. If the install has auth on, the skill surfaces 401/403
and stops rather than papering over it with a sync fallback.

Run state is held in `.moca-runs/<run-id>-<leaf-label>.json` inside
the scratch dir. One record per dispatched leaf; completed results
land in a sibling `.result.json` file. The scratch dir **is** the
resumable state — no `$HOME` lookups, no Claude Code session-id
tricks.

### Fixture lives in-repo, mounted via a PVC

MOCA accepts `repoUrl`+`ref` to git-fetch inside the sandbox, but that
makes the fixture external to this directory and — more importantly —
precludes mounting it `readOnly: true`, which is the one piece of
substrate-enforced isolation the demo exists to show. Instead,
`setup.sh` provisions a PVC in the MOCA namespace, copies
`example_repo/` into it via a short-lived loader pod, and mounts that
PVC into every leaf.

The provisioning is factored through `lib/ctx.sh` — a thin
`kubectl`-only shim whose functions mirror the `contextctl` verbs that
would otherwise do this (`ctx create`, `ctx artifact publish`,
`ctx sync push`, `ctx get`, `ctx delete`). Rationale: the demo should
work on any MOCA-equipped cluster without a Context Service install,
but the design still points at Context Service as the eventual host.
Swapping back is a function-body change, not a restructure.

### Two workloads, not one

- `workload-a` mounts the PVC `readOnly: true` for the researcher.
- `workload-b` mounts the same PVC `readOnly: false` for the fixer.

Alternative considered: a single read-only workload with an in-sandbox
copy-to-scratch step for B. Rejected as fallback-only — two workloads is
cleaner and matches MOCA's native `workspace.readOnly` field.

### Vendored stand-in library, not a real npm package

`example_repo/node_modules/lib/` is a hand-rolled module that only
exports `newName`. `src/index.js` calls `lib.oldName`, so tests fail with
`TypeError: lib.oldName is not a function`. Keeps the demo reproducible
indefinitely — no dependency on upstream API history.

The fix B applies is a one-line rename in `src/index.js`. Tests pass.

### Skill is mechanism, not flow

A single `SKILL.md` tells Claude:

- `Task` is denied; the only subagent path is this skill.
- Workloads are already provisioned by setup; do not call `/workloads`.
- Three procedures: **start a leaf** (`POST /runs` + write record),
  **check a leaf** (`GET /runs/status` + write result + update
  record), **list pending runs** (read `.moca-runs/`).
- Which workloads exist in this scratch dir and their mount posture.
- Prompt-authoring guidance for leaves (state the mount posture, pass
  forward context from earlier leaves verbatim, describe the
  deliverable).
- How to sequence leaves if the operator asks for a chain.

The skill does **not** prescribe how many leaves to run, in what
order, or with what prompts. That orchestration lives in the
operator's requests and the parent's judgment. The multi-prompt
"diagnose, then fix" flow this demo illustrates is operator-driven;
`moca-dispatch` would work the same way for a one-leaf review, a
three-leaf fan-out, or anything else the operator asks for. The
README's "Run a session" section carries example operator prompts as
illustration, not as part of the skill contract.

### Settings deny `Task`, allow only `/runs` curls

`settings.json.example`:

- `permissions.deny`: `Task` — forces the skill path.
- `permissions.allow`: prefix-matched `curl` to `POST /runs` and
  `GET /runs/status` on `localhost:8080`, plus `jq` for parsing.
  Scoped as tightly as the Claude Code allow-rule schema supports.

Local file ops on `.moca-runs/` go through Claude's Read/Write/Edit
tools and don't need extra permissions.

No hooks. No custom binary. The whole substrate on the operator side
is: skill + settings + a running port-forward.

## Scope limits (what's honest)

- **A's read-only workspace is substrate-enforced** — the PVC is
  mounted `readOnly: true`. Writes physically fail. Verifiable with
  `kubectl exec`.
- **A's "no exec / no network" is prompt-only.** MOCA gives every leaf
  the same seven tools (`read, write, edit, ls, find, bash, grep`),
  there's no per-leaf `tools` allowlist on `LeafEnvelope`, and there is
  no web-fetch tool anywhere in MOCA. A non-compliant A could run
  `bash`. Honest capability splits need upstream MOCA changes.
- **B needs a writable workspace** — hence `workload-b`. There is no
  way to give B exec and deny A exec within one workload today.

## Verification arc (what the README walks through)

1. MOCA up on kind; port-forward live.
2. `./setup.sh` provisions the PVC, pushes `example_repo/`, creates
   workloads A and B, stages scratch (including `.moca-runs/`).
3. Operator runs Claude from scratch, pastes the "dispatch a
   diagnosis subagent" prompt.
4. Claude reads the skill, does **not** invoke `Task` (deny fires if
   it tries).
5. Permission prompt shows the full `POST /runs` curl targeting
   `workload-a` — visual proof the leaf is being dispatched to MOCA.
6. Claude writes a record to `.moca-runs/` and returns control. The
   leaf is now running on the cluster.
7. **Operator Ctrl-C's Claude** (optional but worth demonstrating).
   `kubectl get pods -n moca-system` shows the leaf still running.
8. Operator restarts Claude from the scratch dir, says "check on
   that subagent". Claude polls `/runs/status`, writes the result,
   surfaces the diagnosis.
9. Operator pastes "dispatch a fixer against the read-write workload"
   prompt. Second leaf starts.
10. Operator asks for the result; Claude polls and surfaces the diff
    and test outcome.
11. Operator sees cold-start-and-drop-to-zero leaf pods in
    `kubectl get pods -n moca-system`.
12. Side check: `kubectl exec` into a workload-a leaf while it's
    live, `touch /workspace/x` → read-only filesystem error.

## Out of scope

- Standing up MOCA or Context Service — prerequisites, documented in
  README.
- Per-leaf tool allowlists on `LeafEnvelope` — upstream MOCA change.
- Web-fetch tool for the researcher — upstream MOCA change.
- Fan-out beyond A → B — single-chain is the whole demo.
- Graceful fallback from async to sync when MOCA has auth enabled —
  the skill surfaces 401/403 and stops. Supporting both modes would
  roughly double the skill and bury the main thread.
