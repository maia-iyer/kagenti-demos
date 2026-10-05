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
session is the orchestrator: it dispatches A, awaits A's sync response,
embeds A's `.text` in B's prompt, dispatches B, reports B's `.text`. One
`curl` per leaf, no polling, no PVC read-back from the laptop.

Sync dispatch (`POST /runs`) is sufficient for a two-step chain. Async
exists in MOCA but requires polling and is only available on
unauthenticated deployments — no benefit here.

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
- How to shape one `/runs` call: envelope, `sessionId` convention,
  `workload` selection, `.text` extraction.
- Which workloads exist in this scratch dir and their mount posture.
- Prompt-authoring guidance for leaves (state the mount posture, pass
  forward context from earlier leaves, describe the deliverable).
- How to sequence leaves if the operator asks for a chain.

The skill does **not** prescribe how many leaves to run, in what
order, or with what prompts. That orchestration lives in the
operator's requests and the parent's judgment. The two-prompt
"diagnose, then fix" flow this demo illustrates is operator-driven;
`moca-dispatch` would work the same way for a one-leaf review, a
three-leaf fan-out, or anything else the operator asks for. The
README's "Run a session" section carries example operator prompts as
illustration, not as part of the skill contract.

### Settings deny `Task`, allow only the `/runs` curl

`settings.json.example`:

- `permissions.deny`: `Task` — forces the skill path.
- `permissions.allow`: a prefix-matched `curl` to `/runs` on
  `localhost:8080`, plus `jq` for parsing. Scoped as tightly as the
  Claude Code allow-rule schema supports.

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

1. MOCA + Context Service up on kind; port-forward live.
2. `./setup.sh` publishes the fixture, creates workloads A and B,
   stages scratch.
3. Operator runs Claude from scratch, pastes the starter prompt.
4. Claude reads the skill, does **not** invoke `Task` (deny fires if
   it tries).
5. Permission prompt shows the full `curl` to `/runs` targeting
   `workload-a` — visual proof the leaf is being dispatched to MOCA.
6. A's `.text` returns inline.
7. Second `curl` for B targeting `workload-b` with A's finding
   embedded.
8. B's `.text` returns with diff and passing tests.
9. Operator sees cold-start-and-drop-to-zero leaf pods in
   `kubectl get pods -n moca-system`.
10. Side check: `kubectl exec` into an A leaf, `touch /workspace/x`
    → read-only filesystem error.

## Out of scope

- Standing up MOCA or Context Service — prerequisites, documented in
  README.
- Per-leaf tool allowlists on `LeafEnvelope` — upstream MOCA change.
- Web-fetch tool for the researcher — upstream MOCA change.
- Async dispatch or `/runs/status` polling — sync is sufficient here.
- Fan-out beyond A → B — single-chain is the whole demo.
