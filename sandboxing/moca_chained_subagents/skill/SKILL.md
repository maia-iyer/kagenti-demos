---
name: moca-dispatch
description: Dispatch a subagent to the MOCA serverless harness as an isolated leaf. Use this skill whenever the operator asks you to "use a subagent", "delegate", "run this remotely", "fan out", or anything else that would ordinarily go through the Task tool — Task is denied in this session, so this is the only subagent path. Dispatch is a single curl to MOCA's /runs endpoint and returns the leaf's answer inline.
---

# MOCA dispatch

This session has **no access to the built-in `Task` tool** — it is denied
in `.claude/settings.json`. To run a subagent, dispatch a MOCA leaf via
the HTTP call described below. If you try `Task` the permission layer
will refuse; re-route through this skill instead of asking the operator
to lift the deny.

This skill is **mechanism only**. It tells you how to run one leaf on
MOCA. It does **not** tell you how many leaves to run, in what order,
or with what prompts — those decisions come from the operator's
request. If the operator asks for one leaf, run one. If they ask for a
chain, run them in sequence and feed outputs forward as they describe.
The orchestration shape is the operator's; the mechanism is yours.

## MOCA basics

- Reachable at `http://localhost:8080` via an operator port-forward.
- `/runs` is **synchronous**: the HTTP response body **is** the leaf's
  result. There is no polling.
- Field `.text` on the response holds the leaf's answer. Extract it
  with `jq -r .text`.
- Each leaf is a fresh sandbox that scales to zero when it's done.
  Leaves do not share state with each other; anything one leaf should
  know, you have to put in its prompt.

## Available workloads in this session

Workloads are pre-provisioned by `setup.sh`. Their names and mount
posture are in `WORKLOADS.md` in the scratch dir — read it if you
haven't already. At time of writing:

- `workload-a` — mounts `/workspace` **read-only**. Writes physically
  fail at the filesystem.
- `workload-b` — mounts `/workspace` **read-write** at the same tree.

Both workloads see the same fixture tree. When picking a workload for
a given leaf, match the mount posture to what the leaf needs to do:
read-only tasks (diagnosis, review, analysis) go to `workload-a`;
tasks that must write files or run tests go to `workload-b`.

If `WORKLOADS.md` lists different names or more workloads, trust it
over this file.

## How to dispatch one leaf

One `curl` per leaf:

```bash
curl -sS -X POST http://localhost:8080/runs \
  -H 'content-type: application/json' \
  -d '{
    "sessionId": "<run-id>/<leaf-label>",
    "workload":  "<workload-name>",
    "kind":      "prompt",
    "prompt":    "<leaf prompt>"
  }'
```

- `<run-id>`: pick once per operator request (e.g. a short random
  string). Reuse it across leaves in the same request so they share a
  run identity in logs.
- `<leaf-label>`: a short identifier for this leaf within the run
  (e.g. `a`, `b`, `review`, `fix`). Operator-meaningful.
- `<workload-name>`: one of the names in `WORKLOADS.md`.
- `<leaf prompt>`: the full prompt for this leaf. See "Writing the
  leaf prompt" below.

Response body is the leaf's result. Extract `.text` with
`jq -r .text`. That is what you return to the operator (or feed into
the next leaf's prompt).

> The exact envelope field name for workload selection is `workload`
> as of this writing. If MOCA rejects the body with an unknown-field
> error, inspect the response and adjust. Do **not** fall back to
> `repoUrl`/`ref` — that path git-fetches inside the sandbox and
> bypasses the mounted workspace, defeating the point of this setup.

## Writing the leaf prompt

The leaf has no memory of the parent session and does not see other
leaves' output. Everything it needs must be in its prompt. In
particular:

- **State the mount posture explicitly.** If you dispatched to a
  read-only workload, tell the leaf its workspace is read-only and
  that attempting writes will fail at the filesystem — this prevents
  the leaf from wasting steps trying to write. If you dispatched to a
  read-write workload, tell the leaf it may write and run commands.
- **Pass forward anything the leaf needs from earlier leaves.** If
  this leaf is building on another leaf's finding, embed that finding
  verbatim in the prompt. There is no shared memory to pull it from.
- **Describe the deliverable.** Tell the leaf what the response text
  should contain (a diagnosis, a diff, a test outcome, etc.) and in
  what shape.

## Chaining leaves

MOCA has no "on complete, trigger X" primitive. If the operator asks
for a chain (A then B), you do the sequencing:

1. Dispatch leaf 1. Await the response. Extract `.text`.
2. Compose leaf 2's prompt, embedding `.text` from leaf 1 verbatim
   where leaf 2 needs it.
3. Dispatch leaf 2.

Do **not** parallelize leaves whose prompts depend on each other.
Do **not** fan out beyond what the operator asked for.

## Error handling

- `curl: (7)` or connection refused → operator's `kubectl
  port-forward` is not up. Surface the error; do not retry.
- HTTP `503` with `Retry-After` → MOCA's sandbox pool is saturated.
  Wait the suggested interval, retry once; otherwise surface.
- HTTP `4xx` with a body mentioning an unknown field → the envelope
  shape has drifted. Surface the response body to the operator.
- Leaf response reports a read-only filesystem error after a write
  attempt → you dispatched a writing leaf to a read-only workload.
  Re-dispatch against the correct workload; do not ask the operator
  to change workload config.

## What this skill does not do

- Does not call `/workloads` or any provisioning endpoint. Setup owns
  that.
- Does not poll `/runs/status`. Sync dispatch is sufficient.
- Does not prescribe an orchestration shape. The operator's request
  drives how many leaves run and in what order.
