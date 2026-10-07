// Package local runs commands on the user's own machine.
//
// It exists for two reasons, neither of them convenience:
//
//   - It proves the Backend seam is real. If `uname -a` returns Linux through
//     substrate and Darwin through local, the redirection is doing something.
//     Without a second impl, a passing smoke test is indistinguishable from a
//     decorative abstraction over one hardcoded path.
//   - It is the control case for escape testing. The adversarial scenarios ask
//     "did anything run on the laptop?", and local is what running on the
//     laptop looks like when it is working as intended.
//
// It is deliberately the degenerate-free case: real streaming, real exit
// codes, no upload, Sync a no-op. Every way a sandbox backend falls short
// shows up as a difference against this file.
package local

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/kagenti/sandboxing/multi-harness-sandbox-matrix/common/backend"
)

const defaultTimeout = 5 * time.Minute

// Backend runs commands via `sh -c` in the caller's own process tree.
type Backend struct {
	// root is the workspace Sync was called with. Held for one reason, and
	// it is an interface finding rather than bookkeeping: an upload-based
	// backend makes the workspace root BECOME the cwd, because that is where
	// it unpacked the tarball. A local backend has no such moment, so
	// without recording the root here the two backends silently disagree
	// about where a relative command runs — `cat marker.txt` succeeds in the
	// sandbox and fails on the laptop, for reasons that have nothing to do
	// with sandboxing.
	//
	// Resolving Cwd against the synced root in both impls is what makes
	// ExecRequest.Cwd mean the same thing everywhere. See phase 0 question 5
	// (workspace path identity) in FINDINGS.md.
	root string
}

// New returns a local backend. It takes no configuration because there is
// nothing to configure: this is the absence of a sandbox.
func New() *Backend { return &Backend{} }

// Exec runs the command locally, streaming stdout and stderr to out as they
// arrive. Both streams go to the one writer because that is what the harness
// seams we are targeting expose — Pi's onData is a single channel — and
// pretending to separate them here would misrepresent what a harness can
// actually show.
func (b *Backend) Exec(ctx context.Context, req backend.ExecRequest, out io.Writer) (backend.ExecResult, error) {
	timeout := req.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "sh", "-c", req.Command)
	cmd.Dir = b.resolveCwd(req.Cwd)
	cmd.Stdout = out
	cmd.Stderr = out

	// Inherit the user's environment, then overlay. The harness is replacing
	// where a shell runs, not sanitising it; a local shell that saw an empty
	// environment would be a worse control than one that behaves like the
	// user's terminal.
	cmd.Env = os.Environ()
	for k, v := range req.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	err := cmd.Run()
	// Streamed is true unconditionally: os/exec writes through to out as the
	// child produces output, with no buffering on our side.
	res := backend.ExecResult{Streamed: true}

	if err == nil {
		return res, nil
	}
	// Timeout kill is checked BEFORE the ExitError branch, not after: a
	// context-killed child dies by SIGKILL, so cmd.Run() returns an
	// *exec.ExitError whose ExitCode() is the signal-death code (-1, surfaced
	// as 255), not 124. Testing errors.As first would report that code and
	// make a timeout indistinguishable from an ordinary failure.
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		res.ExitCode = 124
		return res, nil
	}
	// A command that ran and exited nonzero is a result, not a backend error.
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		res.ExitCode = exitErr.ExitCode()
		return res, nil
	}
	return res, fmt.Errorf("local exec: %w", err)
}

// resolveCwd mirrors the substrate backend's rule so ExecRequest.Cwd means
// the same thing through both: empty means the workspace root, a relative
// path is joined onto it, and an absolute path is honoured as given.
//
// Absolute paths are the one place the two impls legitimately differ — here
// an absolute local path exists, and in a sandbox it does not. That
// divergence is a property of relocating execution, not a bug to be hidden,
// so it is left visible rather than normalised away.
func (b *Backend) resolveCwd(cwd string) string {
	cwd = strings.TrimSpace(cwd)
	if filepath.IsAbs(cwd) {
		return cwd
	}
	if b.root == "" {
		// Sync was never called: fall back to the process's own cwd, which is
		// what exec.Cmd does with an empty Dir.
		return cwd
	}
	if cwd == "" {
		return b.root
	}
	return filepath.Join(b.root, cwd)
}

// Sync does no copying: the workspace is already the local filesystem. It
// records the root so Exec resolves a relative Cwd the same way an
// upload-based backend does.
//
// This is the shape every mount- or share-based backend takes — no transfer,
// no payload ceiling — and it is the reason Sync is separate from Exec in the
// interface.
func (b *Backend) Sync(ctx context.Context, root string) error {
	abs, err := filepath.Abs(root)
	if err != nil {
		return fmt.Errorf("local: resolve workspace %s: %w", root, err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return fmt.Errorf("local: workspace %s: %w", abs, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("local: workspace %s is not a directory", abs)
	}
	b.root = abs
	return nil
}

// Close is a no-op; nothing is held.
func (b *Backend) Close(ctx context.Context) error { return nil }
