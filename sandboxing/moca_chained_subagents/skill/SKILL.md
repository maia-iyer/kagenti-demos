---
name: moca-dispatch
description: Dispatch subagents to the MOCA serverless harness as isolated leaves. Use this skill whenever the operator asks you to "use subagents", "delegate", "fan out", or otherwise run work in a separate agent — the built-in Task tool is denied in this session, so this is the only subagent path. Dispatch is a single curl to the MOCA /runs endpoint and returns the leaf's answer inline.
---

# MOCA dispatch

This session has **no access to the built-in `Task` tool** — it is denied
in `.claude/settings.json`. To run a subagent, dispatch a MOCA leaf via
the HTTP calls below. If you try `Task` the permission layer will refuse;
re-route through this skill instead of asking the operator to lift the
deny.

The MOCA service is reachable at `http://localhost:8080` via an operator
port-forward (see the demo README). Two workloads have already been
provisioned by `setup.sh`:

- `workload-A` — researcher. Mounts `/workspace` **read-only**. Writes
  physically fail at the filesystem.
- `workload-B` — fixer. Mounts `/workspace` **read-write** at the same
  fixture tree.

Both workloads see the same `example_repo/` tree, published by
`setup.sh` to Context Service and mounted as a PVC. You do not call
`contextctl` or `/workloads` — those are setup's job.

## How to dispatch a leaf

One `curl` per leaf. The response body **is** the leaf's result; field
`.text` holds the leaf's answer. There is no polling.

```bash
curl -sS -X POST http://localhost:8080/runs \
  -H 'content-type: application/json' \
  -d '{
    "sessionId": "<demo-run-id>/<leaf-name>",
    "workload":  "<workload-name>",
    "kind":      "prompt",
    "prompt":    "<leaf prompt>"
  }'
```

Pick `<demo-run-id>` once per operator request (e.g. a short random
string) and reuse it across A and B so the two leaves share a run
identity in logs. `<leaf-name>` is `A` for the researcher, `B` for the
fixer.

Extract `.text` with `jq -r .text` (jq is available locally).

> The exact envelope field name for workload selection on `/runs` is
> `workload` as of this writing; if MOCA rejects the body, inspect the
> response for the expected field name and adjust. Do not fall back to
> `repoUrl`/`ref` — that path git-fetches instead of using the PVC and
> defeats the demo.

## The chain

For a debug-and-fix request, run **exactly two leaves in order**:

1. **Researcher (A)** against `workload-A`. Use the prompt template
   below verbatim, substituting the operator's problem description.
   Take `.text` from the response — that is A's diagnosis.
2. **Fixer (B)** against `workload-B`. Use the prompt template below,
   embedding A's `.text` into the "Finding from researcher" section.
   Take `.text` — that is B's diff and test outcome.

Report B's `.text` to the operator, prefixed with a one-line summary of
A's finding so the operator can see the chain.

Do not interleave or parallelize A and B — B's prompt depends on A's
output. Do not dispatch more than one researcher and one fixer per
operator request unless the operator explicitly asks for a retry.

## Prompt template for leaf A (researcher)

```
You are a code researcher. The workspace at /workspace is mounted
READ-ONLY: any attempt to write files or run shell commands that
mutate state will fail at the filesystem. Do not attempt writes. Do
not run package installs, builds, or tests — read-only means
read-only.

Your task: diagnose a bug in a small Node.js project at /workspace.
Read src/, test/, node_modules/lib/index.js, and
docs/upstream-refs/. Identify the single root cause and the exact
one-line fix needed in src/index.js. Reference the specific file(s)
and documentation that justify the fix.

Problem description from the operator:
<OPERATOR PROBLEM DESCRIPTION>

Respond with:
1. ROOT CAUSE: one or two sentences.
2. EVIDENCE: the files and line ranges you read that establish it.
3. FIX: the exact change to apply, as a before/after snippet.
```

## Prompt template for leaf B (fixer)

```
You are a code fixer. The workspace at /workspace is mounted
read-write. Apply the fix described below, then run the test suite
and report the outcome.

Finding from researcher (leaf A):
<A.text>

Steps:
1. Apply the fix in /workspace exactly as described.
2. From /workspace, run: node --test test/index.test.js
3. Report: the git-style diff of your change, the test command's
   stdout/stderr, and whether the suite passed.

Do not make changes beyond those required by the finding. If the
tests still fail after applying the fix as given, report the failure
verbatim rather than attempting further edits.
```

## Error handling

- `curl: (7)` or connection refused → the operator's `kubectl
  port-forward` is not up. Surface the error to the operator; do not
  retry.
- HTTP `503` with `Retry-After` → MOCA's sandbox pool is saturated.
  Wait the suggested interval and retry once; otherwise surface.
- HTTP `4xx` with a body mentioning an unknown field → the envelope
  shape has drifted. Surface the response body to the operator.
- B reports a read-only filesystem error → `workload-B` was
  misconfigured. Surface and stop; do not retry against `workload-A`.

## What this skill does not do

- Does not call `/workloads` or `contextctl`. Setup owns those.
- Does not poll `/runs/status`. Sync dispatch is sufficient.
- Does not fan out — the chain is strictly A then B.
