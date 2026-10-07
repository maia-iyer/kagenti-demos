/**
 * Contract test for the Pi M1 extension's BashOperations.
 *
 * Drives `exec` directly rather than through a Pi session, for two reasons:
 * it needs no model credentials and no tokens, and it tests the part that is
 * actually ours. What a model does with the output is Pi's business; whether
 * we honour Pi's exec contract is ours, and that contract has four details
 * that are easy to get wrong and silent when wrong:
 *
 *   1. onData receives Buffers, not strings.
 *   2. timeout is in seconds, and must reject with `timeout:<secs>`.
 *   3. abort must reject with exactly "aborted".
 *   4. a nonzero exit is a RESULT ({exitCode: n}), not a rejection.
 *
 * Run: node pi/m1/ops_test.mjs
 * Uses the local backend, so no cluster is required.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const HARNESS_EXEC = resolve(HERE, "../../run/bin/harness-exec");


import { createHarnessExecOps } from "./ops.ts";

// ops.ts imports nothing from Pi at runtime, so it is driven directly here:
// no Pi session, no model credentials, no cluster.
//
// Each test builds a fresh workspace and its own ops object pointed at it,
// rather than sharing one and mutating the root between tests. Slightly more
// verbose per test, but the tests stay independent and order-insensitive.
function opsFor(workspaceRoot) {
  return createHarnessExecOps({
    harnessExec: HARNESS_EXEC,
    localWorkspace: workspaceRoot,
    workspaceDir: "/workspace",
    backend: "local",
  });
}
let ops;

function workspace() {
  const root = mkdtempSync(join(tmpdir(), "pi-m1-"));
  writeFileSync(join(root, "marker.txt"), "at-root\n");
  mkdirSync(join(root, "sub"));
  writeFileSync(join(root, "sub", "nested.txt"), "in-sub\n");
  return root;
}

// exec with output collected the way Pi collects it: Buffers through a
// streaming decoder.
async function run(cwd, command, extra = {}) {
  const chunks = [];
  const decoder = new TextDecoder();
  let sawNonBuffer = false;
  const res = await ops.exec(command, cwd, {
    onData: (d) => {
      if (!Buffer.isBuffer(d)) sawNonBuffer = true;
      chunks.push(decoder.decode(d, { stream: true }));
    },
    ...extra,
  });
  chunks.push(decoder.decode());
  return { out: chunks.join(""), exitCode: res.exitCode, sawNonBuffer };
}

// Find the harness-exec processes this test started. Matched on the absolute
// binary path so a stray harness-exec from another run (or from the user's
// own shell) is not a candidate for killing.
function listHarnessExecPids() {
  const ps = spawnSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" });
  if (ps.status !== 0) return [];
  return ps.stdout
    .split("\n")
    .filter((line) => line.includes(HARNESS_EXEC) && !line.includes("ps -axo"))
    .map((line) => Number.parseInt(line.trim().split(/\s+/)[0], 10))
    .filter((pid) => Number.isInteger(pid) && pid !== process.pid);
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("onData receives Buffers", async () => {
  ops = opsFor(workspace());
  const { out, sawNonBuffer } = await run("/workspace", "echo hello");
  assert.equal(sawNonBuffer, false, "onData was called with a non-Buffer");
  assert.match(out, /hello/);
});

test("nonzero exit is a result, not a rejection", async () => {
  ops = opsFor(workspace());
  const { exitCode } = await run("/workspace", "exit 42");
  assert.equal(exitCode, 42, "exit code must be returned, not thrown");
});

test("empty cwd maps to the workspace root", async () => {
  ops = opsFor(workspace());
  const { out, exitCode } = await run("/workspace", "cat marker.txt");
  assert.equal(exitCode, 0, `expected success, got ${exitCode}: ${out}`);
  assert.match(out, /at-root/);
});

test("sandbox-side subdirectory cwd is translated", async () => {
  ops = opsFor(workspace());
  const { out, exitCode } = await run("/workspace/sub", "cat nested.txt");
  assert.equal(exitCode, 0, `expected success, got ${exitCode}: ${out}`);
  assert.match(out, /in-sub/);
});

test("stderr reaches onData", async () => {
  ops = opsFor(workspace());
  const { out } = await run("/workspace", "echo oops >&2");
  assert.match(out, /oops/, "stderr must reach the single output channel");
});

test("shell metacharacters survive verbatim", async () => {
  ops = opsFor(workspace());
  for (const [cmd, want] of [
    [`printf 'a\\nb\\nc\\n' | head -2`, /a\nb\n/],
    [`echo one; echo two`, /one\ntwo/],
    [`echo "$(echo nested)"`, /nested/],
    ["cat <<'EOF'\nheredoc-line\nEOF", /heredoc-line/],
  ]) {
    const { out, exitCode } = await run("/workspace", cmd);
    assert.equal(exitCode, 0, `${cmd} exited ${exitCode}: ${out}`);
    assert.match(out, want, `command did not pass through verbatim: ${cmd}`);
  }
});

test("timeout rejects with Pi's magic timeout: string", async () => {
  ops = opsFor(workspace());
  await assert.rejects(
    () => run("/workspace", "sleep 10", { timeout: 1 }),
    (err) => {
      assert.ok(
        err.message.startsWith("timeout:"),
        `message must start with "timeout:" for Pi to format it; got ${JSON.stringify(err.message)}`,
      );
      assert.equal(err.message, "timeout:1", "the seconds value must be interpolated");
      return true;
    },
  );
});

test("abort rejects with exactly 'aborted'", async () => {
  ops = opsFor(workspace());
  const ac = new AbortController();
  const p = run("/workspace", "sleep 10", { signal: ac.signal });
  setTimeout(() => ac.abort(), 300);
  await assert.rejects(p, (err) => {
    assert.equal(err.message, "aborted", "Pi matches this string exactly");
    return true;
  });
});

test("pre-aborted signal rejects without spawning", async () => {
  ops = opsFor(workspace());
  const ac = new AbortController();
  ac.abort();
  await assert.rejects(
    () => run("/workspace", "echo should-not-run", { signal: ac.signal }),
    (err) => {
      assert.equal(err.message, "aborted");
      return true;
    },
  );
});

test("backend failure is distinguished from a failing command", async () => {
  // A nonexistent workspace makes harness-exec exit 125: the command never
  // ran. Reporting that as a plain nonzero exit would tell the model its
  // command failed and invite it to "fix" working code.
  ops = opsFor(join(tmpdir(), "definitely-does-not-exist-" + Date.now()));
  await assert.rejects(
    () => run("/workspace", "echo hi"),
    (err) => {
      assert.match(err.message, /backend failure/, `got: ${err.message}`);
      return true;
    },
  );
});

test("env is forwarded to the command", async () => {
  ops = opsFor(workspace());
  const { out } = await run("/workspace", 'echo "$PI_M1_TEST_VAR"', {
    env: { ...process.env, PI_M1_TEST_VAR: "forwarded" },
  });
  assert.match(out, /forwarded/);
});

test("a command that kills its own shell reports a code, not null", async () => {
  // The backend watched this command run and die, so there IS something to
  // report: 255. null is reserved for "we cannot say what happened"
  // (harness-exec itself killed), which is the next test. Conflating the two
  // would make a self-killing command look un-reportable.
  ops = opsFor(workspace());
  const { exitCode } = await run("/workspace", "kill -TERM $$");
  assert.equal(exitCode, 255, "an inner signal death is a result the backend can report");
});

test("harness-exec dying by signal surfaces exitCode null", async () => {
  // Pi's failure check is `exitCode !== 0 && exitCode !== null`, so null is
  // how "killed" is communicated and is deliberately NOT a failure. Node's
  // close event supplies null only when the child itself died by signal, and
  // we forward it unchanged. A tidy-up like `code ?? 1` would turn this into
  // a reported command failure, so this pins the null.
  ops = opsFor(workspace());
  let exitCode = "unset";
  await new Promise((done, fail) => {
    ops
      .exec("sleep 10", "/workspace", { onData: () => {} })
      .then((r) => {
        exitCode = r.exitCode;
        done();
      }, fail);
    // Kill harness-exec out from under the shim. SIGKILL rather than SIGTERM
    // so it cannot exit cleanly with a code.
    setTimeout(() => {
      for (const pid of listHarnessExecPids()) {
        try {
          process.kill(pid, "SIGKILL");
        } catch {
          // Already gone; the assertion below is what matters.
        }
      }
    }, 400);
  });
  assert.equal(exitCode, null, "a signal-killed harness-exec must surface as null");
});

test("missing timeout and env are tolerated (the user_bash path)", async () => {
  // bash-executor.js calls exec with only { onData, signal } — no timeout,
  // no env. Both must be optional or `!` commands break.
  ops = opsFor(workspace());
  const chunks = [];
  const res = await ops.exec("echo bare", "/workspace", {
    onData: (d) => chunks.push(d.toString()),
  });
  assert.equal(res.exitCode, 0);
  assert.match(chunks.join(""), /bare/);
});

let failed = 0;
for (const [name, fn] of tests) {
  try {
    await fn();
    console.log(`ok   ${name}`);
  } catch (err) {
    failed++;
    console.log(`FAIL ${name}`);
    console.log(`     ${err.message.split("\n").join("\n     ")}`);
  }
}
console.log(`\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed === 0 ? 0 : 1);
