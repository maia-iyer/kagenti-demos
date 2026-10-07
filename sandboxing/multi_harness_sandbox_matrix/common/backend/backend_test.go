// Contract tests for backend.Backend.
//
// These run against every implementation that can work without external
// infrastructure, so a second impl cannot quietly disagree with the first
// about what ExecRequest.Cwd means or whether a nonzero exit is an error.
// Both of those divergences were real and were found by hand in phase 0; the
// tests exist so they are not found by hand twice.
//
// The substrate impl is not covered here: it needs a cluster, and a test that
// silently skips is worse than one that is honestly absent. Its unit-testable
// part (the upload ceiling preflight) is tested in its own package.
package backend_test

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/kagenti/sandboxing/multi-harness-sandbox-matrix/common/backend"
	"github.com/kagenti/sandboxing/multi-harness-sandbox-matrix/common/backend/local"
)

// impls are the backends the contract tests run against. Adding a backend
// here is how you find out it disagrees with the others.
func impls(t *testing.T) map[string]func() backend.Backend {
	return map[string]func() backend.Backend{
		"local": func() backend.Backend { return local.New() },
	}
}

// run is the common path: sync a workspace, exec one command, collect output.
func run(t *testing.T, be backend.Backend, root, cwd, cmd string) (string, backend.ExecResult, error) {
	t.Helper()
	ctx := context.Background()
	if err := be.Sync(ctx, root); err != nil {
		t.Fatalf("Sync(%s): %v", root, err)
	}
	var buf bytes.Buffer
	res, err := be.Exec(ctx, backend.ExecRequest{
		Command: cmd,
		Cwd:     cwd,
		Timeout: 30 * time.Second,
	}, &buf)
	return buf.String(), res, err
}

// workspace builds a throwaway tree: marker.txt at the root, sub/nested.txt
// one level down.
func workspace(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "marker.txt"), []byte("at-root\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "sub", "nested.txt"), []byte("in-sub\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

// TestEmptyCwdIsWorkspaceRoot pins the divergence found in phase 0: an
// upload-based backend unpacks the workspace and lands in it, so an empty Cwd
// must mean the workspace root everywhere, not "wherever the client process
// happened to be".
func TestEmptyCwdIsWorkspaceRoot(t *testing.T) {
	for name, mk := range impls(t) {
		t.Run(name, func(t *testing.T) {
			root := workspace(t)
			out, res, err := run(t, mk(), root, "", "cat marker.txt")
			if err != nil {
				t.Fatalf("Exec: %v", err)
			}
			if res.ExitCode != 0 {
				t.Fatalf("exit %d, want 0 (output: %q)", res.ExitCode, out)
			}
			if !strings.Contains(out, "at-root") {
				t.Errorf("output %q does not contain %q — empty Cwd did not resolve to the workspace root", out, "at-root")
			}
		})
	}
}

// TestRelativeCwdJoinsWorkspace covers the `cd subdir && ...` class without
// the cd: a relative Cwd is joined onto the workspace root.
func TestRelativeCwdJoinsWorkspace(t *testing.T) {
	for name, mk := range impls(t) {
		t.Run(name, func(t *testing.T) {
			root := workspace(t)
			out, res, err := run(t, mk(), root, "sub", "cat nested.txt")
			if err != nil {
				t.Fatalf("Exec: %v", err)
			}
			if res.ExitCode != 0 {
				t.Fatalf("exit %d, want 0 (output: %q)", res.ExitCode, out)
			}
			if !strings.Contains(out, "in-sub") {
				t.Errorf("output %q does not contain %q", out, "in-sub")
			}
		})
	}
}

// TestNonzeroExitIsNotAnError is the distinction the whole scoring scheme
// rests on: a failing test run is a result, and only a backend that could not
// run the command at all is an error. Collapsing the two would make
// fail-silent indistinguishable from fail-loud.
func TestNonzeroExitIsNotAnError(t *testing.T) {
	for name, mk := range impls(t) {
		t.Run(name, func(t *testing.T) {
			_, res, err := run(t, mk(), workspace(t), "", "exit 42")
			if err != nil {
				t.Fatalf("Exec returned an error for a command that ran and exited 42: %v", err)
			}
			if res.ExitCode != 42 {
				t.Errorf("ExitCode = %d, want 42", res.ExitCode)
			}
		})
	}
}

// TestShellMetacharactersSurviveIntact is M1's central claim: because there
// is no local execution path to intercept, there is nothing to parse
// defensively, so pipes, semicolons, quotes, and newlines mean exactly what a
// shell says they mean. Any backend that rewrites the command string will
// fail here.
func TestShellMetacharactersSurviveIntact(t *testing.T) {
	cases := []struct {
		name string
		cmd  string
		want string
	}{
		{"pipe", `printf 'a\nb\nc\n' | head -2`, "a\nb\n"},
		{"semicolon", `echo one; echo two`, "one\ntwo\n"},
		{"and_and", `true && echo yes`, "yes\n"},
		{"newline", "echo first\necho second", "first\nsecond\n"},
		{"single_quotes", `echo 'a  b'`, "a  b\n"},
		{"double_quotes_with_dollar", `X=hi; echo "$X there"`, "hi there\n"},
		{"redirect_and_read", `echo payload > f.tmp && cat f.tmp`, "payload\n"},
		{"subshell", `echo "$(echo nested)"`, "nested\n"},
		{"heredoc", "cat <<'EOF'\nline1\nline2\nEOF", "line1\nline2\n"},
	}
	for name, mk := range impls(t) {
		for _, tc := range cases {
			t.Run(name+"/"+tc.name, func(t *testing.T) {
				out, res, err := run(t, mk(), workspace(t), "", tc.cmd)
				if err != nil {
					t.Fatalf("Exec: %v", err)
				}
				if res.ExitCode != 0 {
					t.Fatalf("exit %d, want 0 (output: %q)", res.ExitCode, out)
				}
				if out != tc.want {
					t.Errorf("output = %q, want %q", out, tc.want)
				}
			})
		}
	}
}

// TestStderrReachesWriter: the harness seams expose one output channel, so
// both streams must arrive. A backend that dropped stderr would turn a loud
// failure into a silent one.
func TestStderrReachesWriter(t *testing.T) {
	for name, mk := range impls(t) {
		t.Run(name, func(t *testing.T) {
			out, _, err := run(t, mk(), workspace(t), "", `echo to-stderr >&2`)
			if err != nil {
				t.Fatalf("Exec: %v", err)
			}
			if !strings.Contains(out, "to-stderr") {
				t.Errorf("stderr did not reach the writer; got %q", out)
			}
		})
	}
}

// TestEnvIsPassedThrough covers ExecRequest.Env.
func TestEnvIsPassedThrough(t *testing.T) {
	for name, mk := range impls(t) {
		t.Run(name, func(t *testing.T) {
			be := mk()
			ctx := context.Background()
			if err := be.Sync(ctx, workspace(t)); err != nil {
				t.Fatal(err)
			}
			var buf bytes.Buffer
			_, err := be.Exec(ctx, backend.ExecRequest{
				Command: `echo "$MATRIX_TEST_VAR"`,
				Env:     map[string]string{"MATRIX_TEST_VAR": "present"},
				Timeout: 30 * time.Second,
			}, &buf)
			if err != nil {
				t.Fatalf("Exec: %v", err)
			}
			if !strings.Contains(buf.String(), "present") {
				t.Errorf("env var did not reach the command; got %q", buf.String())
			}
		})
	}
}

// TestTimeoutIsDistinguishable: 124 rather than a signal-death code, so
// "took too long" is tellable from "failed". The local impl got this wrong
// initially by checking errors.As before ctx.Err().
func TestTimeoutIsDistinguishable(t *testing.T) {
	for name, mk := range impls(t) {
		t.Run(name, func(t *testing.T) {
			be := mk()
			ctx := context.Background()
			if err := be.Sync(ctx, workspace(t)); err != nil {
				t.Fatal(err)
			}
			var buf bytes.Buffer
			res, err := be.Exec(ctx, backend.ExecRequest{
				Command: "sleep 10",
				Timeout: 500 * time.Millisecond,
			}, &buf)
			if err != nil {
				t.Fatalf("a timed-out command should be a result, not an error: %v", err)
			}
			if res.ExitCode != 124 {
				t.Errorf("ExitCode = %d, want 124 for a timeout", res.ExitCode)
			}
		})
	}
}

// TestSyncRejectsBadWorkspace: a typo'd path must fail at Sync with a clear
// message rather than producing an exec against an empty workspace.
func TestSyncRejectsBadWorkspace(t *testing.T) {
	for name, mk := range impls(t) {
		t.Run(name+"/missing", func(t *testing.T) {
			if err := mk().Sync(context.Background(), filepath.Join(t.TempDir(), "nope")); err == nil {
				t.Error("Sync accepted a nonexistent workspace")
			}
		})
		t.Run(name+"/not_a_dir", func(t *testing.T) {
			f := filepath.Join(t.TempDir(), "file.txt")
			if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := mk().Sync(context.Background(), f); err == nil {
				t.Error("Sync accepted a file as a workspace")
			}
		})
	}
}

// TestCloseIsIdempotent — teardown runs on both the success and failure path,
// so a second Close must not report a problem.
func TestCloseIsIdempotent(t *testing.T) {
	for name, mk := range impls(t) {
		t.Run(name, func(t *testing.T) {
			be := mk()
			ctx := context.Background()
			if err := be.Close(ctx); err != nil {
				t.Fatalf("first Close: %v", err)
			}
			if err := be.Close(ctx); err != nil {
				t.Fatalf("second Close: %v", err)
			}
		})
	}
}
