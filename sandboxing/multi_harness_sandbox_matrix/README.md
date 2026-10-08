# Multi-harness sandbox matrix

Does redirecting an agent's shell into a sandbox actually work, and does the
answer depend on which agent you use?

Three things vary independently, which is why this is a matrix and not a demo:

- **Harness** — Claude Code, Pi, (later: others)
- **Method** — how the shell gets redirected (M1–M4 below)
- **Backend** — where the command actually runs (`local`, `substrate`)

The thing being measured is not "did it run in a sandbox". It is **how a
mismatch presents itself**. Three outcomes:

| Outcome | Meaning |
| --- | --- |
| `pass` | The command ran where intended and the result was faithful. |
| `fail-loud` | It broke, visibly, with a message someone could act on. |
| `fail-silent` | It appeared to work and did not. **This is the one that matters.** |

A sandbox that fails loudly is an inconvenience. One that fails silently is a
false sense of containment, and that is the failure mode this repo is built to
find.

See `PLAN.md` for the full design and `FINDINGS.md` for results — including
which ones are verified by running code versus only read from source.

## Status

**Phase 0.** The `Backend` seam exists with two implementations, the Pi M1
extension is written and contract-tested, and **both legs of the smoke test
pass**: `uname -s` returns Darwin through `local` and Linux through
`substrate` (verified 2026-10-07, after fixing two upstream API breaks
recorded in `FINDINGS.md` — proto skew in `kubectl-ate`, and the router's
move from Host-header to explicit `ate-target-actor` header routing).

## The four redirection methods

Ordered by how much of the harness they have to fight. M1 is strongest
because it replaces the thing that runs commands, rather than trying to
intercept or rewrite what the agent asked for.

| | Method | How | Weakness |
| --- | --- | --- | --- |
| **M1** | Relocate the execution backend | Replace the harness's command-execution seam | Needs such a seam to exist |
| **M2** | Shadow/replace the shell tool | Register a tool that shadows the built-in | The original may still be reachable |
| **M3** | Hook with input rewriting | Rewrite the command before it runs | Must parse shell syntax correctly |
| **M4** | Hook deny + natural-language reason | Refuse, and ask the model to retry differently | Relies on the model complying |

M4 is what the existing `local_claude_code_kind_substrate_sandbox/` demo
does, and its weakness is concrete: it decides what to redirect by matching
the first whitespace-separated token, so `VAR=1 npm test` or `(cd x && make)`
walk straight past it. M1 has nothing to match, which is the point.

## Quick start

No cluster needed for any of this:

```bash
./setup.sh              # build harness-exec into run/bin/, verify local backend
./test.sh               # every test that does not need a cluster
./smoke.sh              # uname -s via the local backend -> expects this host's kernel
```

The local backend is not a placeholder. It is the control case: if a scenario
fails identically on `local` and `substrate`, the sandbox is not what broke
it.

```bash
./teardown.sh           # clean run/ (local only by default)
./teardown.sh --actors  # also suspend/delete smoke-*/matrix-* actors
```

`teardown.sh --actors` deliberately leaves `sess-*` actors alone — those
belong to the Claude Code demo, not to this matrix.

## Running against substrate

### Prerequisites (one-time, from a `substrate/` checkout)

Not part of this repo — you need your own checkout of the `substrate`
repository. From its root:

```bash
./hack/create-kind-cluster.sh
./hack/install-ate-kind.sh --deploy-ate-system \
  --credential-provider='{"name":"k8s.io"}' \
  --deploy-demo-counter --deploy-demo-sandbox
go install ./cmd/kubectl-ate   # provides `kubectl ate`, used below
```

`--deploy-ate-system` refuses to run without a `--credential-provider`;
the bundled `k8s.io` provider and its empty, default-deny policy are fine
here — nothing in this matrix injects egress credentials.

This creates a new kind cluster. If you already have unrelated kind clusters,
check what it selects as the current context before running the matrix
against it.

These commands summarize the substrate repo's own setup, and drift when it
changes. The upstream
[Quickstart (Development)](https://github.com/agent-substrate/substrate#quickstart-development)
is the reference to check against when they do.

Then, in a terminal you leave open:

```bash
kubectl port-forward -n ate-system svc/atenet-router 8000:80
```

Verify before going further — `setup.sh` checks this and will tell you what is
missing, but checking by hand is faster to interpret:

```bash
kubectl ate get atespaces
```

### Then

```bash
./setup.sh --backend=substrate
./smoke.sh --backend=substrate    # uname -s MUST return Linux
```

That last assertion is the whole phase-0 exit criterion. `Linux` from a
Darwin host is unforgeable evidence that the command left the laptop.

## Using the Pi extension

```bash
HARNESS_BACKEND=substrate HARNESS_WORKSPACE="$PWD" \
  pi -e pi/m1/index.ts
```

Run from the matrix root — like every other command in this README. (The
extension path is relative to where you invoke `pi`, not to the workspace.)

Set `HARNESS_BACKEND=local` to run the same extension with no cluster, which
is the fastest way to tell an extension bug from a sandbox bug.

The extension covers **both** shell paths — the `bash` tool the agent calls
and the `user_bash` event behind user-typed `!` commands. Handling only the
first is the mistake this matrix exists to catch: the agent gets sandboxed,
the human does not, and nothing says so.

## Layout

```
common/
  backend/            the seam: Backend, ExecRequest, ExecResult
    local/            runs on the host (control case + escape baseline)
    substrate/        runs in an ate actor (all cluster concepts live here)
  cmd/harness-exec/   the single Go <-> harness boundary
pi/m1/
  ops.ts              BashOperations impl; imports nothing from Pi at runtime
  index.ts            registration only (bash tool, user_bash, system prompt)
run/                  gitignored: bin/, workspaces/, results/, logs/
```

Two structural rules worth not breaking:

- **No cluster concepts in `backend.Backend`.** Substrate is one
  implementation behind an interface, not the shape of the project. If
  Docker, SSH, or E2B would need the interface changed to fit, the interface
  is wrong.
- **`ops.ts` must not import Pi at runtime.** That is what lets the execution
  contract be tested with no Pi session, no credentials, and no cluster — 14
  tests covering the details that fail silently.

## Testing

```bash
./test.sh                              # everything below, plus a build if needed
cd common && go test ./...              # backend contract + upload-ceiling preflight
npx tsx pi/m1/ops_test.mjs              # Pi exec contract (14)
node pi/m1/run_register_test.mjs        # Pi extension registration (7)
```

The Go contract tests run against a map of implementations rather than one
concrete type, so a second backend cannot quietly disagree about cwd
handling, exit codes, or metacharacter passthrough.

Deliberately **not** covered: the substrate transport path. It needs a
cluster, so it is verified by `./smoke.sh --backend=substrate` and nowhere
else. A test that silently skips is worse than one that is honestly absent.

## Known gaps

Carried forward in `FINDINGS.md`, listed here because they shape what results
mean:

- **Substrate cannot stream.** `/process` returns once, at completion, so
  `ExecResult.Streamed` is always false and stdout/stderr interleaving is
  unrecoverable.
- **Substrate cannot signal a running remote process.** Ctrl-C releases the
  client; the actor-side command keeps going.
- **~128 KiB workspace ceiling** on the base64-env upload path, and real
  source compresses about 2×, not 10×. `Sync` preflights this and fails with
  an actionable error instead of `argument list too long`.
- **No serialisation across concurrent calls** to one actor, so the
  parallel-subagent scenario is not meaningful yet.
- **This is not a credential boundary.** The environment, tokens and all, is
  forwarded into the sandbox on purpose, for fidelity. Do not describe any of
  this as isolation.
