// Package backend defines the seam between a harness's shell tool and
// wherever that shell actually runs.
//
// The point of the interface is that Agent Substrate is one implementation of
// it, not the shape of the demo. Nothing here mentions actors, atespaces,
// templates, or suspend/resume: if it did, swapping substrate for Docker, a
// plain SSH host, Fly machines, E2B, or Modal would mean reworking every
// caller instead of writing one new impl.
package backend

import (
	"context"
	"io"
	"time"
)

// Backend runs commands somewhere that is not the user's shell.
type Backend interface {
	// Exec runs req.Command and streams its combined output to out as it
	// arrives. Implementations that can only return output at completion
	// write to out once, just before returning — see the Streaming note on
	// ExecResult.
	//
	// A nonzero exit status of the user's command is NOT an error: it comes
	// back in ExecResult.ExitCode with a nil error. A non-nil error means the
	// backend itself failed to run the command at all (transport down,
	// workspace not synced, payload over a backend limit), which callers must
	// distinguish from "the command ran and failed".
	Exec(ctx context.Context, req ExecRequest, out io.Writer) (ExecResult, error)

	// Sync makes the local workspace at root visible to the backend. A
	// backend that mounts or shares a filesystem implements this as a no-op.
	//
	// Separate from Exec on purpose: an upload-based backend has a payload
	// ceiling and a staleness window, and a mount-based one has neither.
	// Keeping the two apart is what makes that difference measurable rather
	// than baked into the demo.
	Sync(ctx context.Context, root string) error

	// Close releases whatever the backend is holding. Idempotent.
	Close(ctx context.Context) error
}

// ExecRequest is a single command to run.
type ExecRequest struct {
	// Command is the shell string exactly as the harness gave it. Backends
	// must not attempt to parse, split, or re-quote it — the escaping bugs
	// this whole matrix is measuring come from doing precisely that.
	Command string

	// Cwd is the directory to run in, as the harness believes it to be.
	// Backends that cannot honour a path verbatim must map it and say so.
	Cwd string

	// Env is extra environment for the command. A backend may refuse values
	// that exceed a transport limit (see substrate's 128 KiB env ceiling).
	Env map[string]string

	// Timeout bounds the command. Zero means the backend's default.
	Timeout time.Duration
}

// ExecResult is what a finished command yields beyond its streamed output.
type ExecResult struct {
	// ExitCode is the command's exit status. Only meaningful when Exec
	// returned a nil error.
	ExitCode int

	// Streamed reports whether output reached the writer incrementally.
	// False means the backend buffered everything and wrote once at
	// completion, which satisfies a streaming caller (such as Pi's onData
	// contract) only degenerately. Surfacing it here keeps that a visible
	// property of the backend rather than a silent assumption.
	Streamed bool
}
