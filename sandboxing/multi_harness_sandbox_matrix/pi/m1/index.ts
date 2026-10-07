/**
 * Pi + M1: relocate the execution backend.
 *
 * The strongest of the four redirection methods. Pi exposes its shell
 * implementation as a `BashOperations` object, so we replace it outright
 * instead of intercepting commands on their way to a local shell. There is no
 * local execution path to miss, which is M1's whole claim — and the reason
 * nothing here parses a command string.
 *
 * The execution logic lives in ./ops.ts (testable without Pi or a cluster);
 * the upload, /process client, and payload-ceiling preflight live in
 * harness-exec (Go), shared with every other harness in the matrix. This
 * file is only the registration layer, so a cross-harness difference is
 * attributable to the harness rather than to four divergent shims.
 *
 * Verified against Pi 0.85.1.
 *
 * Usage:
 *   pi -e ./pi/m1/index.ts --tools bash -p "run uname -a"
 *
 * Environment:
 *   HARNESS_EXEC          path to harness-exec (default: ../../run/bin/harness-exec)
 *   HARNESS_BACKEND       substrate | local  (default: substrate)
 *   HARNESS_WORKSPACE     host workspace root to sync (default: Pi's cwd)
 *   SUBSTRATE_ACTOR_NAME  actor to run in (default: derived from the session)
 */

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type BashOperations, createBashTool } from "@earendil-works/pi-coding-agent";

import { createHarnessExecOps } from "./ops.ts";

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * Where the workspace lives sandbox-side; must match the substrate backend's
 * Config.WorkspaceDir default.
 *
 * This is passed as the `cwd` argument to createBashTool so Pi hands the
 * backend a sandbox-side path directly, rather than us string-replacing a
 * host path inside exec. The upstream Gondolin extension uses the same trick
 * (`createBashTool(GUEST_WORKSPACE, ...)`), and it works because the inner
 * tool is invoked without the 5th `ctx` argument — see execute() below.
 */
const WORKSPACE_DIR = "/workspace";

export default function (pi: ExtensionAPI) {
  const localWorkspace = resolve(process.env.HARNESS_WORKSPACE ?? process.cwd());
  const harnessExec = process.env.HARNESS_EXEC ?? resolve(HERE, "../../run/bin/harness-exec");
  const backend = process.env.HARNESS_BACKEND ?? "substrate";

  // Assigning to Pi's BashOperations type is the check that ops.ts's
  // structural restatement of it has not drifted from the real one.
  const ops = (): BashOperations =>
    createHarnessExecOps({ harnessExec, localWorkspace, workspaceDir: WORKSPACE_DIR, backend });

  // The built-in bash tool, kept for its name, schema, renderers, and
  // truncation behaviour. Spreading it is what inherits all of that instead
  // of reimplementing it — Pi's docs note renderers are inherited per slot
  // when omitted.
  const localBash = createBashTool(localWorkspace);

  // Nothing is connected here on purpose: an extension factory runs even in
  // invocations that never open a session, so touching the cluster at this
  // point would create actors for `pi --help`. The Go backend creates and
  // resumes the actor lazily, on first use.

  // (1) The agent-driven `bash` tool. Registering a tool named `bash`
  // overrides the built-in.
  pi.registerTool({
    ...localBash,
    label: `bash (${backend} sandbox)`,
    async execute(id, params, signal, onUpdate) {
      // The sandbox-side root is the cwd the backend will see, so it goes
      // here. The inner execute is then called with FOUR arguments — ctx is
      // omitted deliberately, because passing it would let Pi's local session
      // cwd override WORKSPACE_DIR and send a macOS path to an Alpine actor.
      const tool = createBashTool(WORKSPACE_DIR, { operations: ops() });
      return tool.execute(id, params, signal, onUpdate);
    },
  });

  // (2) User-typed `!` / `!!` commands, which do NOT go through the bash
  // tool. Omitting this is a hole rather than a cosmetic gap: a user typing
  // `!rm -rf .` would hit the laptop while the agent's own commands were
  // safely sandboxed. A truthy return short-circuits Pi's remaining handlers
  // and its local fallback.
  pi.on("user_bash", () => ({ operations: ops() }));

  // (3) Tell the model where it actually is. Without this the system prompt
  // still advertises the host path, and the model reasons about a filesystem
  // it cannot see — emitting absolute paths that do not exist sandbox-side.
  pi.on("before_agent_start", (event: { systemPrompt: string }) => {
    const localLine = `Current working directory: ${localWorkspace}`;
    const sandboxLine =
      `Current working directory: ${WORKSPACE_DIR} ` +
      `(${backend} sandbox; host workspace ${localWorkspace} is synced here). ` +
      "Shell commands run in the sandbox, not on the host. Use paths relative to " +
      `${WORKSPACE_DIR}; host absolute paths do not exist there.`;
    const systemPrompt = event.systemPrompt.includes(localLine)
      ? event.systemPrompt.replace(localLine, sandboxLine)
      : `${event.systemPrompt}\n\n${sandboxLine}`;
    return { systemPrompt };
  });

  // A visible marker that redirection is active. A silently-inactive sandbox
  // is the worst outcome in the matrix, so make the active case loud.
  pi.on("session_start", (_event: unknown, ctx: ExtensionContext) => {
    ctx?.ui?.notify?.(
      `Shell redirected to the ${backend} backend (workspace ${WORKSPACE_DIR}).`,
      "info",
    );
  });
}
