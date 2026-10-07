// harness-exec runs one shell command through a backend.Backend.
//
// This is the single Go/TypeScript boundary for the whole matrix. Every
// harness shim — Pi extension, OpenCode tool, Codex exec-server, Claude Code
// hook — spawns this binary and forwards its output. Keeping one CLI means a
// difference between harnesses is attributable to the harness or the method,
// and not to four shims that each reimplemented tar and upload slightly
// differently.
//
// Usage:
//
//	harness-exec [flags] -- <command>...
//
// Everything after `--` is joined with single spaces and handed to the
// backend as one shell string. Callers that care about exact spacing should
// pass the command as a single argv element.
//
// Exit codes: the command's own exit code on success. 124 on timeout. 125 for
// a harness-exec or backend failure, chosen because it cannot be confused
// with a shell's 126 (not executable) or 127 (not found) — a caller seeing
// 125 knows the command never ran.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/kagenti/sandboxing/multi-harness-sandbox-matrix/common/backend"
	"github.com/kagenti/sandboxing/multi-harness-sandbox-matrix/common/backend/local"
	"github.com/kagenti/sandboxing/multi-harness-sandbox-matrix/common/backend/substrate"
)

// exitHarnessFailure signals that the command never ran. Distinct from any
// code a shell produces for a command that did run.
const exitHarnessFailure = 125

func main() {
	fs := flag.NewFlagSet("harness-exec", flag.ContinueOnError)
	backendName := fs.String("backend", envOr("HARNESS_BACKEND", "substrate"),
		"backend to run through: substrate | local")
	workspace := fs.String("workspace", envOr("HARNESS_WORKSPACE", ""),
		"local workspace root to sync (default: current directory)")
	cwd := fs.String("cwd", envOr("HARNESS_CWD", ""),
		"directory to run in, relative to the workspace root")
	actor := fs.String("actor", envOr("SUBSTRATE_ACTOR_NAME", ""),
		"substrate actor name (default: derived from --session)")
	session := fs.String("session", envOr("HARNESS_SESSION_ID", ""),
		"session id, used to derive a stable actor name when --actor is unset")
	manage := fs.Bool("manage", envOr("HARNESS_MANAGE_ACTOR", "") == "1",
		"create/resume the actor before running and suspend it after")
	timeout := fs.Duration("timeout", envDuration("HARNESS_TIMEOUT", 5*time.Minute),
		"command timeout")
	printBackend := fs.Bool("print-backend", false,
		"write a one-line banner naming the backend to stderr before running")

	if err := fs.Parse(os.Args[1:]); err != nil {
		os.Exit(exitHarnessFailure)
	}

	command := strings.TrimSpace(strings.Join(fs.Args(), " "))
	if command == "" {
		fatal("no command given.\nusage: harness-exec [flags] -- <command>")
	}

	root := *workspace
	if root == "" {
		var err error
		if root, err = os.Getwd(); err != nil {
			fatal("getwd: %v", err)
		}
	}

	be, err := newBackend(*backendName, *actor, *session, *manage)
	if err != nil {
		fatal("%v", err)
	}

	// Ctrl-C and SIGTERM cancel the in-flight command. The actor-side process
	// is not signalled — /process offers no way to — which is the honest
	// answer to phase 0 question 4 and is recorded as such rather than
	// smoothed over with a local kill that leaves the actor running.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *printBackend {
		fmt.Fprintf(os.Stderr, "[harness-exec] backend=%s workspace=%s\n", *backendName, root)
	}

	if err := be.Sync(ctx, root); err != nil {
		// Close before reporting: a managed actor was possibly resumed by a
		// previous call in this process and should not be left holding a slot.
		closeQuietly(be)
		var limitErr *substrate.LimitError
		if errors.As(err, &limitErr) {
			// Already a full explanation; don't bury it in a wrapper.
			fatalRaw(limitErr.Error())
		}
		fatal("%v", err)
	}

	res, execErr := be.Exec(ctx, backend.ExecRequest{
		Command: command,
		Cwd:     *cwd,
		Timeout: *timeout,
	}, os.Stdout)

	// Close before exiting so a managed actor is suspended even on failure.
	if err := be.Close(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "harness-exec: %v\n", err)
	}

	if execErr != nil {
		fatal("%v", execErr)
	}
	os.Exit(res.ExitCode)
}

func newBackend(name, actor, session string, manage bool) (backend.Backend, error) {
	switch name {
	case "local":
		return local.New(), nil
	case "substrate":
		if actor == "" {
			if session == "" {
				return nil, fmt.Errorf("backend substrate needs --actor or --session " +
					"(or $SUBSTRATE_ACTOR_NAME / $HARNESS_SESSION_ID)")
			}
			actor = actorName(session)
		}
		return substrate.New(substrate.Config{
			Actor:    actor,
			Atespace: envOr("SUBSTRATE_ATESPACE", ""),
			Template: envOr("SUBSTRATE_TEMPLATE", ""),
			Manage:   manage,
		})
	default:
		return nil, fmt.Errorf("unknown backend %q (want substrate or local)", name)
	}
}

// actorName derives a stable actor name from a session id, matching the
// scheme in local_claude_code_kind_substrate_sandbox so the two demos can
// share a cluster without colliding on names.
func actorName(sessionID string) string {
	h := sha256.Sum256([]byte(sessionID))
	return "sess-" + hex.EncodeToString(h[:])[:8]
}

func closeQuietly(be backend.Backend) {
	if err := be.Close(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "harness-exec: %v\n", err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
}

func fatal(format string, args ...any) {
	fatalRaw(fmt.Sprintf(format, args...))
}

func fatalRaw(msg string) {
	fmt.Fprintf(os.Stderr, "harness-exec: %s\n", msg)
	os.Exit(exitHarnessFailure)
}
