# Findings

Results as they are established. Phase 0 only, so far.

**Evidence labels** are used throughout, because the plan's whole point is
that reading source is not the same as running it:

- **VERIFIED** — observed by running code in this repo.
- **SOURCE** — read from the installed harness or upstream source, not yet
  executed.
- **BLOCKED** — could not be established here; what is missing is named.

---

## Phase 0 status

| Exit criterion | Status |
| --- | --- |
| `uname -s` returns Darwin through the `local` backend | ✅ VERIFIED |
| `uname -s` returns Linux from a substrate actor | ⛔ BLOCKED — no substrate cluster on this machine |
| Pi `BashOperations.exec` signature confirmed or fixed | ✅ VERIFIED — the plan's guess was wrong in four ways |
| Seven compatibility questions answered against `Backend` | ✅ written below (3 VERIFIED, 4 SOURCE/BLOCKED) |
| `local` + `substrate` impls behind one interface, plus `harness-exec` | ✅ VERIFIED (substrate's transport path untested) |
| `run/` layout established, `setup.sh` builds into `run/bin/` | ✅ VERIFIED |

**What blocks the substrate leg.** It is environment, not code, and it is
**not a missing prerequisite** — it simply has not been run here. The checkout
is present at `~/workdir/agentic-platform/substrate` (on `main`, with the
`hack/` scripts below), so the only thing absent is a running cluster: the one
kind cluster on this machine is `sh-knative`, `kubectl ate get atespaces`
reports `services "api" not found`, and nothing listens on port 8000.

To close this criterion:

```bash
cd ~/workdir/agentic-platform/substrate
./hack/create-kind-cluster.sh
./hack/install-ate-kind.sh --deploy-ate-system --deploy-demo-counter --deploy-demo-sandbox
kubectl port-forward -n ate-system svc/atenet-router 8000:80   # leave running

cd -   # back to multi_harness_sandbox_matrix
./setup.sh --backend=substrate
./smoke.sh --backend=substrate    # uname -s MUST return Linux
```

Until that passes, the substrate code path is **written and unit-tested but
not executed end-to-end**, and nothing downstream should treat "M1 works
through substrate" as established.

---

## The Pi seam: the plan's guess vs. the installed API

Open question #8 asked whether the guessed `BashOperations.exec` signature was
right. It was not, and **three of the four errors would have failed silently**
— which is the failure class this matrix exists to measure, so it is worth
recording precisely.

Verified against Pi **0.85.1**, `dist/core/tools/bash.d.ts:23-38`:

```ts
export interface BashOperations {
    exec: (command: string, cwd: string, options: {
        onData: (data: Buffer) => void;
        signal?: AbortSignal;
        timeout?: number;
        env?: NodeJS.ProcessEnv;
    }) => Promise<{ exitCode: number | null }>;
}
```

| What the plan assumed | What is actually true | Failure mode if unfixed |
| --- | --- | --- |
| `exec` resolves with only an exit code | Correct — `{exitCode}` only, output via `onData` | — (the plan got this right) |
| `timeout` in milliseconds (implied) | **Seconds** — `resolveTimeoutMs` does `timeout * 1000` (`bash.js:14-24`), and the tool schema says "Timeout in seconds" | A 120 s timeout becomes 120 000 s. Hangs instead of timing out. Silent. |
| Errors are ordinary `Error`s | Pi string-matches `"aborted"` and `` `timeout:<secs>` `` (`bash.js:252-258`) | Timeouts and cancels surface to the model as raw stack text. Silent. |
| `onData` takes a string | Takes a **`Buffer`**; Pi feeds it a streaming `TextDecoder` | Multibyte characters split across chunks corrupt. Silent, rare, undebuggable. |
| One seam to replace | **Two.** The `bash` tool and the `user_bash` event are separate paths | User-typed `!` commands run on the **laptop** while agent commands are sandboxed. Silent, and a security hole. |

Also contractual, and easy to get backwards: **a nonzero exit is not an
error.** Return `{exitCode: n}` and Pi raises `Command exited with code N`
itself (`bash.js:263-265`). Rejecting instead double-reports every failing
test run.

And a fifth detail: `exitCode` is `number | **null**`, documented as "null if
killed", and Pi's failure check is `exitCode !== 0 && exitCode !== null` — so
`null` is not a failure, it means *nothing can be said about the command*.

Writing a test for this turned up a distinction worth keeping, because the
obvious version of the test asserted the wrong thing. There are two signal
deaths, and they are not the same event:

| What dies | Result | Why |
| --- | --- | --- |
| The shell *inside* the backend (`kill -TERM $$`) | **255** | The backend watched the command run and die. That is a real result. |
| `harness-exec` itself | **null** | Node's `close` reports no code. Genuinely unknown. |

Both are correct, and conflating them would be a fail-silent bug in either
direction: synthesising a code for the second case reports a command failure
that was never observed, while passing null for the first throws away an exit
code the backend actually had. Node supplies null only in the second case and
the shim forwards it unchanged. A plausible "tidy-up" like `code ?? 1` would
break it. Both rows are now pinned by tests.

The `user_bash` finding is the one with teeth. `BashOperations` reads like the
single seam, and replacing it looks complete; the agent's commands really do
get sandboxed. But `!` commands go through `executeBashWithOperations`
(`dist/core/bash-executor.js:65-68`), which is reached only by handling the
`user_bash` event. Miss it and the sandbox is partial in exactly the way a
demo would never notice — the agent is contained, the human is not.

A second-order consequence: that path calls `exec` with **only**
`{onData, signal}` — no `timeout`, no `env`. An impl that assumes either is
present breaks `!` commands specifically. `pi/m1/ops_test.mjs` covers this
("missing timeout and env are tolerated").

### Interface consequence

`Exec` taking an `io.Writer` was right, and for the reason the plan gave:
Pi returns output exclusively through `onData`. One addition was needed —
`ExecResult.Streamed`, so a backend that can only return output at completion
is *visibly* degenerate rather than silently assumed. Substrate is one of
those (see Q2).

---

## The seven compatibility questions, as requirements on `Backend`

Answered as the plan asks: as questions you would also put to Docker, SSH,
Fly, E2B, or Modal. That framing is what makes them interface questions rather
than substrate trivia.

### Q1 — State: does `cd` persist across calls?

**Requirement: no. The client must carry cwd, and `Backend` must not assume a
session.**

**VERIFIED (Pi side, SOURCE for the mechanism):** Pi passes `cwd` as a
per-call parameter and holds it in `SessionManager`, which has `getCwd()` and
**no setter**; `process.chdir` appears nowhere in `dist/core` or
`dist/modes`. So a `cd /foo` inside one command cannot affect the next call
even in stock local Pi. Pi's own semantics already match a stateless backend.

This is lucky rather than designed, and it is the right requirement anyway:
substrate's `/process` is request/response over an actor that may be suspended
between calls, so there is no session to hold state in. A backend that *does*
have a persistent shell (SSH with a kept-open channel) must still re-assert
cwd per call, or it will diverge from every other backend on the second
command.

`ExecRequest.Cwd` carries it. **No `Chdir` method, and no implied session.**

### Q2 — Streaming: incremental stdout, or only on completion?

**Requirement: `Exec` must accept a writer and stream where it can; a backend
that cannot must say so rather than appear to.**

**SOURCE, and it is a real gap.** `/process` returns `{stdout, stderr,
exitCode}` as one JSON body after the command finishes. There is no chunked
or streaming variant. Against Pi's `onData` contract this is **degenerate**:
one callback at completion, no incremental output. A `npm test` that takes two
minutes shows nothing for two minutes and then everything.

Worse, and worth stating plainly: because `/process` hands back stdout and
stderr as **separate complete strings**, their interleaving is
unrecoverable. The substrate backend writes stdout then stderr, so a command
whose streams interleave meaningfully is reported in an order that never
happened. Pi has one output channel, so this loss is invisible to the harness
— it looks like ordinary output.

Encoded as `ExecResult.Streamed`. `local` sets it true; `substrate` sets it
false, always. This is the first concrete entry on the "requirements substrate
cannot meet" list that phase 1b is supposed to produce.

### Q3 — Exit codes and stderr: faithfully returned, and distinguishable?

**Requirement: three outcomes must stay distinct — command-failed,
backend-failed, and timed-out. Collapsing any two produces `fail-silent`.**

**VERIFIED.** This drove two fixes during phase 0, and both were the
fail-silent kind:

1. `Exec` returns `(ExecResult, error)` where a nonzero exit is a **result**
   and only a backend failure is an **error**. Substrate's `/process` has a
   separate `error` field for "the actor could not run this", which is mapped
   to the error return, not to an exit code.
2. **`harness-exec` exits 125 for backend failure**, chosen so it cannot be
   confused with a shell's 126 (not executable) or 127 (not found). The Pi
   shim translates 125 into a thrown error rather than passing it through as
   an exit code — otherwise the model is told *its command* failed when the
   *sandbox* failed, and it goes off to "fix" working code.

Stderr: both backends merge stderr into the single writer, because that is
what the harness seams expose. Pi has one `onData` channel; pretending to
separate them would misrepresent what any harness can show.

### Q4 — TTY and signals: stdin, Ctrl-C, timeout kills?

**Requirement: stdin is closed, cancellation must at least release the
client, and a backend that cannot signal the remote process must admit it.**

Partly **VERIFIED**, partly a **known gap**:

- **stdin**: closed (`stdio: ["ignore", ...]`). No backend in this matrix
  offers an interactive TTY, so any command expecting input hangs or fails
  rather than appearing to work. Consistent across both impls.
- **Timeout**: VERIFIED. Reported as exit **124** (the `timeout(1)`
  convention), distinct from any signal-death code. This was a real bug
  found by testing: `exec.CommandContext` kills with SIGKILL, so checking
  `errors.As(&exec.ExitError)` *before* `ctx.Err()` reported 255 and made a
  timeout indistinguishable from an ordinary failure. The context check must
  come first. Pinned by `TestTimeoutIsDistinguishable`.
- **Ctrl-C / abort**: the client is released and `harness-exec` is
  SIGTERM'd. **But `/process` offers no way to signal the actor-side
  process**, so the command keeps running in the actor until it finishes or
  the actor is suspended. Cancellation is therefore *client-side only* on
  substrate. Pi's `AbortSignal` is honoured as far as Pi can observe, which
  means the gap is invisible from the harness — the UI says cancelled, the
  actor disagrees.

A backend with a real process handle (Docker, SSH) can do better. The
interface permits it; substrate does not deliver it.

### Q5 — Workspace path: same path actor-side as the harness believes?

**Requirement: no, and `Cwd` must mean the same thing through every backend
regardless.**

**VERIFIED, and this is where the two-backend discipline paid for itself.**
The first green `local` smoke test was followed immediately by a *failing*
workspace round-trip, for a reason that had nothing to do with sandboxing:
an upload-based backend unpacks the workspace and *lands in it*, so the
workspace root becomes the cwd. A local backend has no such moment and stays
wherever the client process was. `cat marker.txt` therefore worked in the
sandbox and failed on the laptop.

Had phase 0 shipped one backend, this would have been baked in as an
unexamined assumption and surfaced in phase 2 as a mysterious per-harness
inconsistency.

The rule, now enforced in both impls and pinned by
`TestEmptyCwdIsWorkspaceRoot` / `TestRelativeCwdJoinsWorkspace`:

- `Cwd` empty → the workspace root.
- `Cwd` relative → joined onto the workspace root.
- `Cwd` absolute → honoured as given, and this is the one place the impls
  *legitimately* differ, because a host absolute path exists locally and
  cannot exist in a sandbox. Left visible rather than normalised away.

Path identity is **not** preserved: the host workspace becomes `/workspace`
actor-side. The Pi extension handles this the way the upstream Gondolin
extension does — `createBashTool(WORKSPACE_DIR, ...)`, so Pi hands the backend
a sandbox-side path directly instead of translating strings inside `exec` —
and rewrites the system prompt so the model is told where it actually is. Skip
that rewrite and the model emits host absolute paths that do not exist in the
sandbox.

### Q6 — Actor lifetime: per-session or per-command?

**Requirement: the interface must not encode either. `Close` must be
idempotent, and lifetime belongs in backend config.**

**SOURCE.** Substrate supports both, and the choice is a cost/latency
tradeoff rather than a correctness one: an actor held for a session keeps a
worker slot while the user reads their email; an actor resumed per command
pays resume latency every call. The existing Claude Code demo ships both as
"eager" and "lazy" modes.

Encoded as `substrate.Config.Manage` — when true the backend creates/resumes
on first use and suspends on `Close`. Nothing about lifetime appears in
`Backend` itself, which is the point: Docker containers, SSH sessions, and
Fly machines all answer this differently and none of them should need the
interface changed.

Two consequences not yet tested, flagged for phase 2 rather than claimed:

- **`/tmp` state and anything outside the workspace** survives between
  commands on a held actor and may not on a recycled one. Scenarios that
  write outside the workspace are measuring the lifetime policy, not the
  harness.
- **Parallel subagents** sharing one actor would interleave. The existing
  demo serialises with an flock; `harness-exec` currently does **not**,
  because phase 0 is single-command. This needs resolving before the
  parallel-subagent scenario means anything.

### Q7 — Upload ceiling: confirm the 128 KiB wall; does M1-Pi sidestep it?

**Requirement: `Sync` must be separate from `Exec` and must fail fast with an
actionable message. M1 does not help.**

**VERIFIED (the preflight and the compression ratio), SOURCE (the kernel
limit itself).**

The wall is real and **M1-Pi does not sidestep it**. It lives in the upload
path and the upstream `/process` handler — which appends env vars to
`cmd.Env` before `execve()`, where Linux caps a *single* env string at
32 × PAGE_SIZE = 131072 B. Switching harnesses changes nothing about it.
Choosing a different *backend* is the only thing that does.

What phase 0 added:

- **A preflight in `Sync`**, before any cluster contact, returning a typed
  `*LimitError` naming the measured base64 size, the gzipped size, the limit,
  why `ulimit` does not help, and the way past it. Observed:

  ```
  harness-exec: substrate: workspace /tmp/limtest is too large for the
  base64-env upload path: 533792 B base64 (400342 B gzipped) exceeds the
  130048 B limit.
  ```

  Compare the pre-existing behaviour, which was `argument list too long`
  surfacing as exit −1 from deep inside a composed shell command.
- **Confirmation that the plan's compression warning was right.** 400 KB of
  incompressible data gzipped to 400342 B — a ratio of 1.0. The plan's
  revised "~2× on real source, not 10×" is the number to budget against, so
  the usable raw workspace is far smaller than 128 KiB suggests.

A mount- or rsync-based backend implements `Sync` as a no-op and has **no
ceiling at all**. That is precisely why `Sync` is separate from `Exec`: it
makes the difference measurable rather than structural. Any scenario that
trips this limit is scoring **the backend**, not the harness and not the
method.

One trap found while building it: the first version of the ceiling test used
a cheap arithmetic pattern as filler, which gzip compressed away, so the test
passed while asserting nothing. It now uses a seeded PRNG. A test for a
size limit must use incompressible data or it is not testing the limit.

---

## Smaller findings worth keeping

- **Pi's package cannot be `require.resolve`'d.** Its `exports` map declares
  only an `"import"` condition, so CJS resolution fails with
  `No "exports" main defined` while ESM `import` of the same specifier
  succeeds. This is why `tsx` cannot load an extension that imports Pi, and
  why jiti (which Pi itself uses) can. Anything testing a Pi extension needs
  Pi's own loader; `pi/m1/run_register_test.mjs` borrows it.
- **Pi's default provider is `google`.** `pi -p` against a machine with only
  `anthropic` credentials fails with a bare `401 invalid x-api-key` that
  reads like a broken key rather than a wrong provider. `pi auth check
  --provider <name>` is the diagnostic.
- **Testing the shim beats testing through the model.** The 21 contract tests
  here need no credentials, no tokens, and no cluster, and they cover the
  exact details that fail silently. A single model-driven smoke run would
  have exercised one happy path and told us nothing about `timeout:` strings
  or Buffer handling.

---

## Open questions moved forward

- **#8 (Pi `exec` signature)** — **CLOSED.** Verified against 0.85.1;
  corrections above.
- **#7 (should substrate stay the default backend?)** — sharpened. Two
  concrete things it cannot do: stream incrementally (Q2) and signal a
  running remote process (Q4). Neither blocks phase 0; both belong on phase
  1b's "cannot satisfy" list.
- **#3 (subagent hook inheritance)** — untouched, and now with a prerequisite:
  `harness-exec` does not serialise concurrent calls against one actor, so
  the parallel-subagent scenario needs that resolved first or it will measure
  our race rather than the harness's behaviour.
- **#5 (Gondolin is not a credential boundary)** — reinforced by a detail
  from the same seam: the Pi extension forwards Pi's resolved environment,
  `PI_*` and all, into the sandbox. That is right for fidelity and wrong for
  isolation. Nothing in this matrix should be described as a credential
  boundary.
