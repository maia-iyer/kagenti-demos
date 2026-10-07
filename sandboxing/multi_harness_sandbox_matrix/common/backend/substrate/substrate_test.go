// Tests for the parts of the substrate backend that need no cluster.
//
// That is mostly the upload ceiling: it is the backend's defining constraint,
// it is the failure the plan requires be legible rather than surfacing as
// "argument list too long" at exit -1, and it is checkable entirely offline
// because the check happens in Sync before anything is sent.
package substrate

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kagenti/sandboxing/multi-harness-sandbox-matrix/common/backend"
)

func newTestBackend(t *testing.T) *Backend {
	t.Helper()
	be, err := New(Config{Actor: "test-actor"})
	if err != nil {
		t.Fatal(err)
	}
	return be
}

func TestNewRequiresActor(t *testing.T) {
	if _, err := New(Config{}); err == nil {
		t.Error("New accepted an empty Actor; the backend cannot route without one")
	}
}

// TestSyncAcceptsSmallWorkspace: the ordinary case, and proof the ceiling
// check is not simply rejecting everything.
func TestSyncAcceptsSmallWorkspace(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("small\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := newTestBackend(t).Sync(context.Background(), root); err != nil {
		t.Fatalf("Sync of a tiny workspace failed: %v", err)
	}
}

// TestSyncRejectsOversizedWorkspace is the headline constraint. Incompressible
// data is used deliberately: gzip on random bytes is a no-op, so the test
// pins the ceiling itself rather than the compression ratio. (Real source
// compresses about 2x, not the 10x it is tempting to assume — which is why
// the raw-size budget is far smaller than the limit suggests.)
func TestSyncRejectsOversizedWorkspace(t *testing.T) {
	root := t.TempDir()
	// 256 KiB of genuinely incompressible data, so the test pins the ceiling
	// itself rather than gzip's ratio on whatever filler we picked. A
	// seeded math/rand stream is used rather than a hand-rolled arithmetic
	// pattern: the obvious cheap ones (i*prime>>shift and friends) are
	// periodic and gzip removes them almost entirely, which silently turned
	// this test into a no-op the first time around.
	big := make([]byte, 256*1024)
	rng := rand.New(rand.NewSource(1)) // fixed seed: a failure reproduces
	if _, err := rng.Read(big); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "big.bin"), big, 0o644); err != nil {
		t.Fatal(err)
	}

	err := newTestBackend(t).Sync(context.Background(), root)
	if err == nil {
		t.Fatal("Sync accepted a workspace past the env-string ceiling")
	}

	// A distinct type, not a string match: callers need to tell this apart
	// from a transport failure, because it scores the backend rather than the
	// harness or the method.
	var limitErr *LimitError
	if !errors.As(err, &limitErr) {
		t.Fatalf("error is %T, want *LimitError: %v", err, err)
	}
	if limitErr.Encoded <= limitErr.Limit {
		t.Errorf("LimitError reports Encoded=%d <= Limit=%d, which would not be a violation",
			limitErr.Encoded, limitErr.Limit)
	}

	// The message has to be actionable: name the measured size, the limit,
	// why raising ulimits will not help, and the way past it.
	msg := limitErr.Error()
	for _, want := range []string{
		"too large",
		"base64",
		"environment string",
		"per-string",
		"mounts or rsyncs",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("LimitError message is missing %q; a user hitting the ceiling needs it to be self-explanatory.\ngot: %s", want, msg)
		}
	}
}

// TestExecBeforeSyncIsAnError: running against an unsynced workspace would
// execute in an empty /workspace and look like a mysteriously missing file.
// It has to be a backend error instead.
func TestExecBeforeSyncIsAnError(t *testing.T) {
	_, err := newTestBackend(t).Exec(context.Background(),
		backend.ExecRequest{Command: "true"}, os.Stdout)
	if err == nil {
		t.Fatal("Exec succeeded without a prior Sync")
	}
	if !strings.Contains(err.Error(), "not synced") {
		t.Errorf("error should say the workspace was not synced; got: %v", err)
	}
}

func TestExecRejectsEmptyCommand(t *testing.T) {
	if _, err := newTestBackend(t).Exec(context.Background(),
		backend.ExecRequest{Command: "   "}, os.Stdout); err == nil {
		t.Error("Exec accepted an empty command")
	}
}

// TestExecRejectsReservedEnvVar: the workspace payload travels in
// SANDBOX_WORKSPACE_B64, so a caller setting it would silently replace the
// workspace with its own value. Better to refuse than to corrupt.
func TestExecRejectsReservedEnvVar(t *testing.T) {
	be := newTestBackend(t)
	if err := be.Sync(context.Background(), t.TempDir()); err != nil {
		t.Fatal(err)
	}
	_, err := be.Exec(context.Background(), backend.ExecRequest{
		Command: "true",
		Env:     map[string]string{"SANDBOX_WORKSPACE_B64": "hijacked"},
	}, os.Stdout)
	if err == nil {
		t.Fatal("Exec accepted an override of the reserved workspace env var")
	}
	if !strings.Contains(err.Error(), "reserved") {
		t.Errorf("error should say the var is reserved; got: %v", err)
	}
}

func TestSyncRejectsBadWorkspace(t *testing.T) {
	be := newTestBackend(t)
	if err := be.Sync(context.Background(), filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Error("Sync accepted a nonexistent workspace")
	}
	f := filepath.Join(t.TempDir(), "file.txt")
	if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := be.Sync(context.Background(), f); err == nil {
		t.Error("Sync accepted a file as a workspace")
	}
}

// TestSkipDirsAreExcluded documents the known basename-matching defect rather
// than asserting it is correct: a project with a source `bin/` directory
// loses it. The matrix scores that case; this test makes sure the behaviour
// does not change unnoticed underneath the score.
func TestSkipDirsAreExcluded(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{"node_modules", "bin", "src"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
		// 64 KiB per directory: enough that including an excluded one would
		// push the total past the ceiling and fail Sync.
		payload := strings.Repeat(fmt.Sprintf("content-of-%s\n", d), 4096)
		if err := os.WriteFile(filepath.Join(root, d, "f.txt"), []byte(payload), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Highly compressible, so this only passes if the excluded dirs really
	// are absent from the tarball rather than merely gzipping well.
	if err := newTestBackend(t).Sync(context.Background(), root); err != nil {
		t.Fatalf("Sync failed; excluded dirs may be getting uploaded: %v", err)
	}
	if !skipDirs["bin"] {
		t.Error("skipDirs no longer excludes bin/ — the known data-loss defect the matrix scores has changed")
	}
}

func TestConfigDefaults(t *testing.T) {
	be := newTestBackend(t)
	if be.cfg.Atespace != "claude-sandbox" {
		t.Errorf("Atespace = %q, want claude-sandbox", be.cfg.Atespace)
	}
	if be.cfg.WorkspaceDir != "/workspace" {
		t.Errorf("WorkspaceDir = %q, want /workspace", be.cfg.WorkspaceDir)
	}
	if be.cfg.RouterURL != "localhost:8000" {
		t.Errorf("RouterURL = %q, want localhost:8000", be.cfg.RouterURL)
	}
}

// TestCloseIsNoopWhenUnmanaged: an unmanaged backend must not suspend an
// actor the harness owns, and Close runs on every path.
func TestCloseIsNoopWhenUnmanaged(t *testing.T) {
	be := newTestBackend(t) // Manage is false
	if err := be.Close(context.Background()); err != nil {
		t.Fatalf("Close on an unmanaged backend should be a no-op: %v", err)
	}
	if err := be.Close(context.Background()); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}
