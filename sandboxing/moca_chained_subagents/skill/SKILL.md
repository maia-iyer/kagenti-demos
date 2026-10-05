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
they describe.

## MOCA basics

MOCA is reached through a Kourier port-forward. Read `MOCA.md` in the
scratch dir for the current values; at time of writing they are:

- Base URL:     `http://localhost:8080`
- Host header:  `serverless-harness.default.example.com`
- workspaceRef: `/workspace/<run-id>/repo` (seeded by setup.sh)

**Every curl to MOCA must include `-H "Host: <host>"`** — the port-forward
hits Kourier, which routes by Host. If `MOCA.md` lists different values,
trust it over this file.

- Dispatch is **asynchronous**: `POST /runs` with `"async": true` starts
  a leaf and returns a handle. The leaf runs to completion on the
  cluster even if this Claude session exits. `GET /runs/status?sessionId=…`
  returns the result when the leaf is done.
- Field `.text` on the completed result holds the leaf's answer. (The
  exact field may vary; dump the full response and surface the relevant
  text if `.text` is absent.)
- Each leaf is a fresh sandbox that scales to zero when done. Leaves
  do not share state; anything one leaf should know, you have to put
  in its prompt.
- Async is only available on **unauthenticated** MOCA deployments. If
  dispatch returns `401`/`403`, surface it to the operator and stop.

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
    "workspaceRef": "<workspace-ref>",
    "dispatchedAt": "<iso8601>",
    "status":       "pending" | "done" | "failed",
    "resultPath":   ".moca-runs/<run-id>-<leaf-label>.result.json"
  }
  ```
- `.moca-runs/<run-id>-<leaf-label>.result.json` — the full response
  body from `/runs/status` once `status` is `done`. Not written until
  collection succeeds.

Reuse `<run-id>` from `MOCA.md` across leaves in the same operator
request so they share a run identity. `<leaf-label>` is a short
identifier within the run (e.g. `diagnose`, `fix`, `review`).

## Procedure 1: start a leaf

```bash
curl -sS -H "Host: serverless-harness.default.example.com" \
     -X POST http://localhost:8080/runs \
  -H 'content-type: application/json' \
  -d '{
    "sessionId":    "<run-id>/<leaf-label>",
    "workspaceRef": "<workspace-ref>",
    "async":        true,
    "prompt":       "<leaf prompt>"
  }'
```

Expected response is a handle (minimally `status: "accepted"` and the
`sessionId`). If the response is instead a full result body, the
deployment is sync-only — surface to the operator and stop.

Then write the record file to `.moca-runs/<run-id>-<leaf-label>.json`
with `status: "pending"`. Report the sessionId to the operator.

**Do not block polling inside this turn.** Return control to the
operator after writing the record.

## Procedure 2: check a leaf

Given a record file with `status: "pending"`:

```bash
curl -sS -H "Host: serverless-harness.default.example.com" \
     "http://localhost:8080/runs/status?sessionId=<run-id>/<leaf-label>"
```

Possible outcomes:

- Status is still `pending` / `running` → leave the record as
  `pending`; tell the operator it's not ready.
- Status is `done` → write the full response body to the record's
  `resultPath`, update `status` to `done`, and surface the result text
  to the operator (or feed it into the next leaf's prompt).
- Status is `failed` / `aborted` or an HTTP error → update `status` to
  `failed`, write whatever body you got to `resultPath`, surface the
  error to the operator.

## Procedure 3: list pending runs

When starting a new turn, before accepting the operator's next request
at face value, glance at `.moca-runs/` for records with `status: "pending"`.
If you find some, they are leaves from an earlier turn (or an earlier
Claude session). Options:

- If the operator's request references them ("check on that subagent"
  / "did it finish?"), run procedure 2 against them.
- If the request is unrelated, note the pending runs briefly ("you have
  N pending leaves from an earlier dispatch; want me to check on them?")
  and then proceed with the current request.

Don't silently discard pending records — they represent cluster-side
work the operator paid for.

## Writing the leaf prompt

The leaf has no memory of the parent session and does not see other
leaves' output. Everything it needs must be in its prompt. In
particular:

- **State the workspace path explicitly.** Tell the leaf where its
  files live (the workspaceRef, e.g. `/workspace/<run-id>/repo`).
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
   2). If done, extract its result text.
3. Compose leaf 2's prompt, embedding leaf 1's result verbatim.
4. Start leaf 2 (procedure 1). Record is written.
5. Check leaf 2 (procedure 2) when the operator wants the final
   result.

Do **not** parallelize leaves whose prompts depend on each other.
Do **not** fan out beyond what the operator asked for.

## Error handling

- `curl: (7)` or connection refused → operator's Kourier port-forward
  is not up. Surface the error; do not retry.
- HTTP `404` from a path that should exist → check the Host header is
  being sent; Kourier returns 404 if routing fails.
- HTTP `401` / `403` on `POST /runs` → MOCA has auth enabled; async
  isn't available. Surface and stop.
- HTTP `503` with `Retry-After` → MOCA's sandbox pool is saturated.
  Wait the suggested interval, retry once; otherwise surface.
- HTTP `4xx` with a body mentioning an unknown field → the envelope
  shape has drifted. Surface the response body to the operator.
- `GET /runs/status` returns 404 for a `sessionId` you have a pending
  record for → the leaf was lost. Mark the record `failed`, surface,
  do not auto-redispatch.
- `GET /runs/status` for a pending sessionId appears to hang forever →
  the `leaf-worker` KEDA ScaledJob may not be installed. Surface this
  possibility to the operator (see demo prerequisites).

## What this skill does not do

- Does not provision workspaces. Setup owns that (seeds files into
  `sandbox-0:/workspace/<run-id>/repo` via `kubectl cp`).
- Does not block the turn on a leaf finishing. Dispatch returns
  immediately; collection happens on a later turn.
- Does not prescribe an orchestration shape. The operator's request
  drives how many leaves run and in what order.
