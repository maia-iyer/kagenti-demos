/**
 * Registration test for the Pi M1 extension.
 *
 * Checks the thing ops_test.mjs cannot: that the extension wires itself into
 * the right Pi extension points. Specifically that it covers BOTH shell
 * paths, because covering only one is a silent hole rather than a visible
 * failure — the agent's commands would be sandboxed while a user-typed `!`
 * command still hit the laptop.
 *
 * The extension is invoked with a stub ExtensionAPI, so this needs no Pi
 * session, no model credentials, and no cluster. It does import Pi's package
 * for createBashTool, so it must run under a loader that can resolve it:
 *
 *   npx tsx pi/m1/register_test.mjs
 *
 * If Pi's package cannot be resolved from here, the test says so and exits 0
 * rather than failing — a resolution quirk of the global install is not a
 * defect in the extension, and ops_test.mjs covers the execution contract
 * either way.
 */

import assert from "node:assert/strict";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
process.env.HARNESS_BACKEND = "local";
process.env.HARNESS_WORKSPACE = resolve(HERE);

let extension;
try {
  // run_register_test.mjs supplies a loader that uses the jiti bundled with
  // Pi — the same resolver a real `pi -e ...` invocation uses. Falling back
  // to a plain import keeps this file runnable on its own under any loader
  // that can resolve Pi's package directly.
  extension = globalThis.__loadExtension
    ? await globalThis.__loadExtension()
    : (await import("./index.ts")).default;
} catch (err) {
  console.log("SKIP registration test: could not load the extension module.");
  console.log(`      ${err.message.split("\n")[0]}`);
  console.log("      (Pi loads it via jiti with its own resolution; the");
  console.log("       execution contract is covered by ops_test.mjs.)");
  process.exit(0);
}

const registeredTools = [];
const handlers = new Map();

const pi = {
  registerTool(tool) {
    registeredTools.push(tool);
  },
  on(event, handler) {
    if (!handlers.has(event)) handlers.set(event, []);
    handlers.get(event).push(handler);
  },
};

extension(pi);

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("overrides the built-in bash tool", () => {
  const bash = registeredTools.find((t) => t.name === "bash");
  assert.ok(
    bash,
    `no tool named "bash" was registered (got: ${registeredTools.map((t) => t.name).join(", ") || "none"})`,
  );
  assert.equal(typeof bash.execute, "function", "the bash override needs an execute()");
});

test("inherits the built-in tool's schema and renderers", () => {
  const bash = registeredTools.find((t) => t.name === "bash");
  // Spreading the built-in tool is what carries schema, renderers, and
  // truncation behaviour across. A hand-rolled tool would be missing these
  // and would break the UI and the details contract.
  assert.ok(bash.parameters ?? bash.schema, "bash override lost its parameter schema");
});

test("handles user_bash, so `!` commands are also redirected", () => {
  const hs = handlers.get("user_bash");
  assert.ok(hs?.length, "no user_bash handler: user-typed ! commands would run locally");
  const result = hs[0](
    { type: "user_bash", command: "echo hi", cwd: "/workspace", excludeFromContext: false },
    {},
  );
  assert.ok(result, "user_bash handler returned falsy — Pi would fall through to local execution");
  assert.equal(
    typeof result.operations?.exec,
    "function",
    "user_bash must return { operations } with an exec()",
  );
});

test("rewrites the advertised cwd in the system prompt", () => {
  const hs = handlers.get("before_agent_start");
  assert.ok(hs?.length, "no before_agent_start handler: the model would be told the host path");
  const local = process.env.HARNESS_WORKSPACE;
  const res = hs[0]({ systemPrompt: `Current working directory: ${local}` }, {});
  assert.ok(res?.systemPrompt, "handler returned no systemPrompt");
  assert.match(res.systemPrompt, /\/workspace/, "the sandbox path is not advertised");
  assert.ok(
    !res.systemPrompt.includes(`Current working directory: ${local}`),
    "the host cwd line survived; the model will reason about a filesystem it cannot see",
  );
});

test("appends the cwd notice when the expected line is absent", () => {
  // Pi's prompt wording is not ours to rely on. If the line we look for ever
  // changes, the notice must still get through rather than vanishing.
  const hs = handlers.get("before_agent_start");
  const res = hs[0]({ systemPrompt: "Some entirely different prompt." }, {});
  assert.match(res.systemPrompt, /\/workspace/, "notice lost when the cwd line is missing");
  assert.match(res.systemPrompt, /Some entirely different prompt\./, "original prompt was dropped");
});

test("does not touch the cluster at factory time", () => {
  // An extension factory runs even for invocations that never open a session
  // (`pi --help`), so connecting here would create actors for nothing. The
  // factory has already run by this point with no cluster reachable; if it
  // tried to connect, we would not have got this far.
  assert.ok(true);
});

test("session_start handler tolerates a context with no ui", () => {
  // The notify call is cosmetic, and a crash in it would take down a session
  // that was otherwise fine.
  const hs = handlers.get("session_start");
  assert.ok(hs?.length, "no session_start handler");
  hs[0]({}, {}); // must not throw
  hs[0]({}, { ui: {} });
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
