/**
 * The harness-exec-backed shell operations for Pi M1.
 *
 * Split out from index.ts for one reason: this module imports nothing from
 * Pi at runtime (only a type, which erases), so it can be driven directly by
 * a test with no Pi session, no model credentials, and no cluster. The
 * contract it has to honour is subtle and silent when broken — see ops_test
 * — so being able to test it cheaply matters more than keeping the extension
 * in one file.
 *
 * Verified against Pi 0.85.1, `dist/core/tools/bash.d.ts`. Four details are
 * contractual; each is marked CONTRACT where relied on.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

/**
 * Pi's BashOperations, restated structurally rather than imported.
 *
 * Deliberate: importing the real type would pull Pi's package into this
 * module's resolution graph, which is exactly what makes a standalone test
 * impossible (the published package exposes no runtime "." export). The
 * extension in index.ts does import Pi's type and assigns this factory's
 * result to it, so a drift between the two is a compile error there rather
 * than a silent mismatch here.
 */
export interface ShellOperations {
  exec: (
    command: string,
    cwd: string,
    options: {
      onData: (data: Buffer) => void;
      signal?: AbortSignal;
      timeout?: number;
      env?: NodeJS.ProcessEnv;
    },
  ) => Promise<{ exitCode: number | null }>;
}

/** Exit code harness-exec uses for "the command never ran". */
const EXIT_BACKEND_FAILURE = 125;

export interface OpsConfig {
  /** Path to the harness-exec binary. */
  harnessExec: string;
  /** Host directory to sync into the sandbox. */
  localWorkspace: string;
  /** Where the workspace lands sandbox-side; Pi's cwd is relative to this. */
  workspaceDir: string;
  /** Backend name passed to harness-exec: "substrate" or "local". */
  backend: string;
}

/**
 * Build shell operations that run every command through harness-exec.
 *
 * No command parsing happens here, by design. M1's claim is that there is no
 * local execution path to miss, so there is nothing to defend against: the
 * command string is forwarded verbatim as a single argv element and pipes,
 * semicolons, newlines, and heredocs mean what a shell says they mean.
 */
export function createHarnessExecOps(cfg: OpsConfig): ShellOperations {
  return {
    exec: (command, cwd, { onData, signal, timeout, env }) =>
      new Promise((resolvePromise, reject) => {
        // CONTRACT: Pi matches thrown messages against the exact strings
        // "aborted" and "timeout:<seconds>" (bash.js:252-259); anything else
        // reaches the model raw. Reject early so a cancelled call never
        // starts a cluster round-trip.
        if (signal?.aborted) {
          reject(new Error("aborted"));
          return;
        }

        const args = [
          `--backend=${cfg.backend}`,
          `--workspace=${cfg.localWorkspace}`,
        ];

        // Pi hands us an absolute sandbox-side path (workspaceDir, or a
        // subdirectory of it). harness-exec wants it relative to the
        // workspace root, because only the backend knows where that root
        // lands on the far side.
        if (cwd && cwd !== cfg.workspaceDir) {
          const prefix = `${cfg.workspaceDir}/`;
          const rel = cwd.startsWith(prefix) ? cwd.slice(prefix.length) : cwd;
          if (rel) args.push(`--cwd=${rel}`);
        }

        // CONTRACT: Pi's timeout is in SECONDS (the model-facing parameter is
        // documented as "Timeout in seconds"), and harness-exec takes a Go
        // duration string — hence the "s" suffix. Optional because the
        // user_bash path (bash-executor.js:65) passes no timeout at all.
        if (timeout && timeout > 0) args.push(`--timeout=${timeout}s`);

        args.push("--", command);

        // Forward Pi's resolved environment (PI_* included) so the sandbox
        // sees what a local shell would have. Undefined values are dropped:
        // NodeJS.ProcessEnv allows them, spawn does not.
        const childEnv: Record<string, string> = {};
        for (const [k, v] of Object.entries(env ?? process.env)) {
          if (v !== undefined) childEnv[k] = v;
        }

        const child = spawn(cfg.harnessExec, args, {
          stdio: ["ignore", "pipe", "pipe"],
          env: childEnv,
        });

        let timedOut = false;
        const timer =
          timeout && timeout > 0
            ? setTimeout(() => {
                timedOut = true;
                child.kill("SIGTERM");
              }, timeout * 1000)
            : undefined;

        // CONTRACT: onData takes Buffers. Pi feeds them to a streaming
        // TextDecoder, which is what lets a multibyte character split across
        // two chunks decode correctly; stringifying here would break that.
        //
        // Both streams go to the one callback because Pi exposes no separate
        // stderr channel. harness-exec merges them for the same reason, and
        // its own diagnostics arrive on stderr.
        child.stdout.on("data", onData);
        child.stderr.on("data", onData);

        const onAbort = () => child.kill("SIGTERM");
        signal?.addEventListener("abort", onAbort, { once: true });

        const cleanup = () => {
          if (timer) clearTimeout(timer);
          signal?.removeEventListener("abort", onAbort);
        };

        child.on("error", (err) => {
          cleanup();
          if (!existsSync(cfg.harnessExec)) {
            reject(
              new Error(
                `harness-exec not found at ${cfg.harnessExec}. ` +
                  "Run ./setup.sh in multi_harness_sandbox_matrix/, or set $HARNESS_EXEC.",
              ),
            );
            return;
          }
          reject(err);
        });

        child.on("close", (code) => {
          cleanup();
          // Abort is checked before timeout: a call that was aborted and also
          // timed out is an abort from Pi's point of view, and the two
          // produce different model-facing messages.
          if (signal?.aborted) {
            reject(new Error("aborted"));
            return;
          }
          if (timedOut) {
            reject(new Error(`timeout:${timeout}`));
            return;
          }
          // The command never ran. Reporting this as an ordinary nonzero exit
          // would tell the model its command failed and invite it to "fix"
          // working code — the fail-silent class this matrix exists to
          // measure. It is the same distinction the Go Backend interface
          // draws between an error and an ExitCode.
          if (code === EXIT_BACKEND_FAILURE) {
            reject(
              new Error(
                "sandbox backend failure: the command did not run. " +
                  "See the output above for the backend's diagnostic.",
              ),
            );
            return;
          }
          // CONTRACT: a nonzero exit is NOT an exec-level error. Return it
          // and Pi raises "Command exited with code N" itself; rejecting here
          // would double-report every failing test run.
          resolvePromise({ exitCode: code });
        });
      }),
  };
}
