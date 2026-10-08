# Pi + M1: relocated execution backend

Replaces Pi's shell operations (`BashOperations`) so every command — the
agent's `bash` tool calls *and* user-typed `!` commands — runs through
`harness-exec` instead of a local shell. See the matrix
[README](../../README.md) for background and [FINDINGS](../../FINDINGS.md)
for what has and hasn't been verified.

## Test it

### 1. Contract tests (no cluster, no Pi session, no credentials)

From the matrix root:

```bash
./setup.sh                        # builds run/bin/harness-exec
npx tsx pi/m1/ops_test.mjs        # exec contract (14 tests)
node pi/m1/run_register_test.mjs  # registration wiring (7 tests)
```

(or just `./test.sh`, which runs these plus the Go backend tests)

Expected: `14/14 passed` and `7/7 passed`. The registration test prints
`SKIP` and exits 0 if it can't find the globally installed Pi — that's a
resolution quirk, not a failure, but it does mean the wiring went untested.

### 2. Real Pi session, local backend (no cluster)

```bash
HARNESS_BACKEND=local HARNESS_WORKSPACE="$PWD" \
  pi -e pi/m1/index.ts
```

Then in the session:

```
> run uname -a
```

What to look for:

- **Banner on session start** — `Shell redirected to the local backend
  (workspace /workspace)`. No banner = the extension didn't load.
- **Output goes through harness-exec** — with `HARNESS_BACKEND=local`,
  `uname` still says Darwin, but the tool label should read
  `bash (local sandbox)`.
- **`!` commands are redirected too** — type `!echo hi` yourself; it must
  use the same path. (A user-typed `!rm` hitting the laptop while the agent
  is sandboxed is the silent hole this extension exists to close.)
- **Nonzero exits report once** — `> run exit 3` should say "Command exited
  with code 3", not an error dump.

### 3. Real Pi session, substrate backend (needs a cluster)

Prerequisites and port-forward are in the matrix
[README](../../README.md#running-against-substrate) — do those first, then:

```bash
HARNESS_BACKEND=substrate HARNESS_WORKSPACE="$PWD" \
  pi -e pi/m1/index.ts
```

In the session:

```
> run uname -a
> run cat README.md     # workspace round-trip
```

What to look for:

- **`uname -a` says Linux** (host is macOS). This is the entire point —
  unforgeable evidence the command left the laptop. Darwin here means
  redirection is not happening.
- **Workspace files are visible** — `cat` on a file from your repo should
  return its contents (uploaded via the base64 tarball).
- **The model uses `/workspace` paths** — it should not emit host paths
  like `/Users/...`; the system-prompt rewrite handles this.

### Known limits you'll hit (expected, not bugs)

- **No incremental output** — `/process` returns once at completion, so a
  long command shows nothing, then everything. Recorded in FINDINGS Q2.
- **Ctrl-C releases the client only** — the actor-side process keeps
  running. FINDINGS Q4.
- **Workspace over ~128 KiB (gzipped+base64) fails** — expect a long,
  self-explanatory `LimitError`, not a hang. FINDINGS Q7. Note `bin/`,
  `dist/`, `node_modules/` etc. are excluded from upload, so size your
  test workspace accordingly.
- **Files created in the sandbox don't come back** — writes land in the
  actor only; re-uploading overwrites them next command.

## Quick diagnosis

| Symptom | Likely cause |
| --- | --- |
| `harness-exec not found` | Run `./setup.sh` from the matrix root |
| Extension won't load under `pi -e` | Check `pi --version` is 0.85.x; the seam was verified against 0.85.1 |
| `uname` says Darwin with substrate | Port-forward down, or actor never resumed — run `./smoke.sh --backend=substrate` to isolate the extension from the backend |
| `401 invalid x-api-key` on startup | Pi's default provider is `google`; if your credentials are for `anthropic`, run `pi auth check --provider anthropic` |
| Command output lost / garbled multibyte | Regression in the Buffer contract — rerun `ops_test.mjs` |

## What has never been run

The substrate path of this extension (`HARNESS_BACKEND=substrate` in a real
Pi session) is unverified end-to-end — no cluster was available during
phase 0. Everything above under "local backend" was exercised via the
contract tests only; a real model-driven session through either backend is
still worth a first careful run.
