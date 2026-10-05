---
name: moca-dispatch
description: Dispatch a subagent to the MOCA serverless harness as an isolated leaf. Use this skill whenever the operator asks you to "use a subagent", "delegate", "run this remotely", "fan out", or anything else that would ordinarily go through the Task tool — Task is denied in this session, so this is the only subagent path. Dispatch is asynchronous: a start call returns a run handle, and a separate check call returns the result when the leaf finishes. The operator can quit Claude between those two steps and resume later.
---

# MOCA dispatch

This session has **no access to the built-in `Task` tool** — it is denied
in `.claude/settings.json`. To run a subagent, dispatch a MOCA leaf via
the HTTP calls described below. If you try `Task` the permission layer
will refuse; re-route through this skill instead of asking the operator
to lift the deny.

This skill is **mechanism only**. It tells you how to run and collect
one leaf on MOCA. It does **not** tell you how many leaves to run, in
what order, or with what prompts — those decisions come from the
operator's request. If the operator asks for one leaf, run one. If they
ask for a chain, start them in sequence and feed outputs forward as
they describe. The orchestration shape is the operator's; the
mechanism is yours.

## MOCA basics

- Reachable at `http://localhost:8080` via an operator port-forward.
- Dispatch is **asynchronous**: `POST /runs` starts a leaf and returns
  a run handle; the leaf runs to completion on the cluster even if
  this Claude session exits. `GET /runs/status?sessionId=…` returns
  the result when the leaf is done.
- Field `.text` on the completed result holds the leaf's answer.
- Each leaf is a fresh sandbox that scales to zero when done. Leaves
  do not share state; anything one leaf should know, you have to put
  in its prompt.
- Async is only available on **unauthenticated** MOCA deployments. If
  dispatch returns `401`/`403` or if `POST /runs` returns a full
  result body instead of a run handle, the deployment is sync-only —
  surface that to the operator and stop; do not invent a polling
  scheme on top of a sync response.

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

## The run record directory

A directory `.moca-runs/` lives in the scratch dir. Every dispatch
writes one record file into it; every collection updates that record
and writes a result file alongside. This is how a resumed Claude
session discovers in-flight work.

Files per leaf:

- `.moca-runs/<run-id>-<leaf-label>.json` — the record. Shape:
  ```json
  {
    "sessionId":    "<run-id>/<leaf-label>",
    "workload":     "<workload-name>",
    "dispatchedAt": "<iso8601>",
    "status":       "pending" | "done" | "failed",
    "resultPath":   ".moca-runs/<run-id>-<leaf-label>.result.json"
  }
  ```
- `.moca-runs/<run-id>-<leaf-label>.result.json` — the full response
  body from `/runs/status` once `status` is `done`. Not written until
  collection succeeds.

Pick `<run-id>` once per operator request (short random string).
Reuse it across leaves in the same request so they share a run
identity. `<leaf-label>` is a short identifier within the run
(e.g. `a`, `b`, `review`, `fix`) — operator-meaningful.

## Procedure 1: start a leaf

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

The response should contain the run handle (minimally the
`sessionId`). If instead it contains a full `.text` field, see the
"sync-only deployment" note above — stop and surface to the operator.

Then write the record file to `.moca-runs/<run-id>-<leaf-label>.json`
with `status: "pending"`. Report the sessionId to the operator so they
know what to come back to.

**Do not block polling inside this turn.** Return control to the
operator after writing the record. The point of async dispatch is
that the operator can quit Claude here and resume later.

## Procedure 2: check a leaf

Given a record file with `status: "pending"`:

```bash
curl -sS "http://localhost:8080/runs/status?sessionId=<run-id>/<leaf-label>"
```

Possible outcomes:

- Response says the run is still in progress → leave the record as
  `pending`; tell the operator it's not ready and suggest they check
  again in a moment (or ask Claude to).
- Response contains the completed result → write the full response
  body to the record's `resultPath`, update `status` to `done`, and
  surface `.text` to the operator (or feed it into the next leaf's
  prompt, if the operator asked for a chain).
- Response says the run failed or errored → update `status` to
  `failed`, write whatever body you got to `resultPath`, surface the
  error to the operator.

## Procedure 3: list pending runs

When starting a new turn, before accepting the operator's next
request at face value, glance at `.moca-runs/` for any records with
`status: "pending"`. If you find some, they are leaves that were
dispatched in an earlier turn (or an earlier Claude session). Options:

- If the operator's request references them ("check on that subagent"
  / "did it finish?"), run procedure 2 against them.
- If the operator's request is unrelated, note the pending runs to
  them briefly ("you have N pending leaves from an earlier dispatch;
  want me to check on them?") and then proceed with the current
  request.

Don't silently discard pending records — they represent cluster-side
work the operator paid for.

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
  verbatim in the prompt (read it out of the earlier leaf's
  `.result.json`). There is no shared memory to pull it from.
- **Describe the deliverable.** Tell the leaf what the response text
  should contain (a diagnosis, a diff, a test outcome, etc.) and in
  what shape.

## Chaining leaves

MOCA has no "on complete, trigger X" primitive. If the operator asks
for a chain (A then B), you do the sequencing:

1. Start leaf 1 (procedure 1). Record is written. Return to operator.
2. On a later turn (same session or resumed), check leaf 1 (procedure
   2). If done, extract `.text`.
3. Compose leaf 2's prompt, embedding leaf 1's `.text` verbatim.
4. Start leaf 2 (procedure 1). Record is written.
5. Check leaf 2 (procedure 2) when the operator wants the final
   result.

Do **not** parallelize leaves whose prompts depend on each other.
Do **not** fan out beyond what the operator asked for.

## Error handling

- `curl: (7)` or connection refused → operator's `kubectl
  port-forward` is not up. Surface the error; do not retry.
- HTTP `401` / `403` on `POST /runs` → MOCA has auth enabled; async
  isn't available. Surface and stop.
- HTTP `503` with `Retry-After` → MOCA's sandbox pool is saturated.
  Wait the suggested interval, retry once; otherwise surface.
- HTTP `4xx` with a body mentioning an unknown field → the envelope
  shape has drifted. Surface the response body to the operator.
- `GET /runs/status` returns 404 for a `sessionId` you have a pending
  record for → the leaf was lost (pod evicted, MOCA restarted,
  session TTL exceeded). Mark the record `failed`, surface to the
  operator, do not auto-redispatch — the operator decides whether to
  retry.
- Leaf result reports a read-only filesystem error after a write
  attempt → you dispatched a writing leaf to a read-only workload.
  Dispatch a replacement against the correct workload; do not ask the
  operator to change workload config.

## What this skill does not do

- Does not call `/workloads` or any provisioning endpoint. Setup owns
  that.
- Does not block the turn on a leaf finishing. Dispatch returns
  immediately; collection happens on a later turn.
- Does not prescribe an orchestration shape. The operator's request
  drives how many leaves run and in what order.
