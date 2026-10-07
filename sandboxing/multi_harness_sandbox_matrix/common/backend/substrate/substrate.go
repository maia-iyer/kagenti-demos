// Package substrate runs commands inside an Agent Substrate actor.
//
// One implementation of backend.Backend, not the structure of the demo. The
// cluster-shaped concepts — atespaces, actor templates, suspend/resume,
// Host-header DNS routing — are all confined to this file.
//
// Two properties of this backend are findings rather than implementation
// details, and the code is arranged to make them visible instead of hiding
// them:
//
//   - It cannot stream. POST /process returns stdout and stderr only once the
//     command has finished, so ExecResult.Streamed is always false. A harness
//     seam that requires incremental output (Pi's onData) is satisfied only
//     degenerately.
//   - It has a hard payload ceiling. The workspace travels as base64 in an
//     env var, and Linux caps a single env string at 32 x PAGE_SIZE = 131072
//     bytes. Sync fails fast with an actionable message rather than letting
//     execve() surface "argument list too long" as an opaque exit -1.
package substrate

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/kagenti/sandboxing/multi-harness-sandbox-matrix/common/backend"
)

const (
	// envStringLimit is the kernel's cap on a single environment string:
	// 32 * PAGE_SIZE on Linux. Measured against the upstream /process
	// handler, which appends envvars to cmd.Env before execve():
	// 131065 B went through, 131070 B returned "argument list too long".
	// The limit is per-string, so raising ulimits does not move it.
	envStringLimit = 32 * 4096 // 131072

	// envStringHeadroom leaves room for the "B64=" prefix and the other
	// strings sharing the same execve() payload.
	envStringHeadroom = 1024

	defaultTimeout = 5 * time.Minute
)

// skipDirs are workspace subdirectories left out of the upload.
//
// Known defect, kept deliberately and recorded rather than fixed: this
// matches on basename, so a project with its own `bin/` or `build/` source
// directory silently loses it. The matrix has a scenario for exactly this
// (a source `bin/` dir), and the point is to score it, not to paper over it
// in the shared backend and lose the measurement.
var skipDirs = map[string]bool{
	".git": true, ".claude": true, ".pi": true, ".opencode": true,
	"node_modules": true, ".venv": true, "venv": true,
	"__pycache__": true, ".pytest_cache": true, ".mypy_cache": true, ".tox": true,
	"target": true, "dist": true, "build": true, "bin": true,
}

// Config parameterises the backend. Defaults match the existing
// local_claude_code_kind_substrate_sandbox demo so the two are comparable.
type Config struct {
	Actor     string // actor name; required
	Atespace  string // defaults to "claude-sandbox"
	Template  string // defaults to "ate-demo-sandbox/sandbox-template"
	DNSSuffix string // defaults to "actors.resources.substrate.ate.dev"
	RouterURL string // atenet-router address; defaults to "localhost:8000"

	// WorkspaceDir is where the synced workspace lands actor-side. The
	// harness believes the workspace is at some local path; this is what it
	// actually becomes. Phase 0 question 5 is whether that divergence is
	// tolerable. Defaults to "/workspace".
	WorkspaceDir string

	// Manage makes the backend own the actor lifecycle: create-if-missing and
	// resume on first use, suspend on Close. When false the actor is assumed
	// to be up already, which is what a per-session harness wants.
	Manage bool
}

func (c *Config) applyDefaults() {
	if c.Atespace == "" {
		c.Atespace = "claude-sandbox"
	}
	if c.Template == "" {
		c.Template = "ate-demo-sandbox/sandbox-template"
	}
	if c.DNSSuffix == "" {
		c.DNSSuffix = "actors.resources.substrate.ate.dev"
	}
	if c.RouterURL == "" {
		c.RouterURL = "localhost:8000"
	}
	if c.WorkspaceDir == "" {
		c.WorkspaceDir = "/workspace"
	}
}

// Backend talks to one actor.
type Backend struct {
	cfg Config

	// payload is the base64 tarball from the most recent Sync. Exec unpacks
	// it actor-side on every call.
	//
	// Re-sending the whole workspace per command is wasteful and is also the
	// honest reading of what /process offers: it is a request/response
	// endpoint over an actor that may have been suspended in between, so
	// there is no session to hold state in. Carrying the payload here rather
	// than re-tarring inside Exec is what keeps the ceiling a Sync-time
	// failure with a legible message.
	payload string

	// synced records whether Sync has run, so Exec can say "workspace not
	// synced" rather than silently running against an empty /workspace.
	synced bool

	resumed bool
}

// New returns a substrate backend for the named actor.
func New(cfg Config) (*Backend, error) {
	if strings.TrimSpace(cfg.Actor) == "" {
		return nil, fmt.Errorf("substrate: Config.Actor is required")
	}
	cfg.applyDefaults()
	return &Backend{cfg: cfg}, nil
}

// --- Sync ---

// Sync tars and gzips the workspace at root and holds it for subsequent Exec
// calls. It does not talk to the cluster: the upload rides along with the
// command, because /process has no separate file-transfer path.
//
// The preflight is the load-bearing part. Above the env-string ceiling this
// returns a *LimitError naming the measured size and the limit, so the caller
// can report a real constraint instead of an exec failure.
func (b *Backend) Sync(ctx context.Context, root string) error {
	// Validated the same way the local backend validates it, so a typo'd
	// workspace path fails identically through both rather than producing a
	// cluster round-trip against an empty tarball.
	info, err := os.Stat(root)
	if err != nil {
		return fmt.Errorf("substrate: workspace %s: %w", root, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("substrate: workspace %s is not a directory", root)
	}

	tarball, err := tarWorkspace(root)
	if err != nil {
		return fmt.Errorf("substrate: tar workspace %s: %w", root, err)
	}
	b64 := base64.StdEncoding.EncodeToString(tarball)

	if limit := envStringLimit - envStringHeadroom; len(b64) > limit {
		return &LimitError{
			Root:       root,
			Encoded:    len(b64),
			Compressed: len(tarball),
			Limit:      limit,
		}
	}

	b.payload = b64
	b.synced = true
	return nil
}

// LimitError reports a workspace too large for the base64-env upload path.
//
// A distinct type because this is the single most important failure mode of
// this backend and the one the plan requires be legible: it is a property of
// the transport, not of the harness, the method, or the user's command. Any
// scenario that trips it is scoring the backend.
type LimitError struct {
	Root       string
	Encoded    int // base64 length, the number the kernel actually caps
	Compressed int // gzipped tar length
	Limit      int
}

func (e *LimitError) Error() string {
	return fmt.Sprintf(
		"substrate: workspace %s is too large for the base64-env upload path: "+
			"%d B base64 (%d B gzipped) exceeds the %d B limit.\n"+
			"This is a kernel cap on a single environment string (32 x PAGE_SIZE = %d B) "+
			"hit by the upstream /process handler when it appends envvars before execve(); "+
			"raising ulimits does not help because the limit is per-string.\n"+
			"Options: exclude large directories from the workspace, or use a backend that "+
			"mounts or rsyncs instead of uploading (such a backend implements Sync as a no-op "+
			"and has no ceiling at all).",
		e.Root, e.Encoded, e.Compressed, e.Limit, envStringLimit)
}

// tarWorkspace tars+gzips root, skipping skipDirs and symlinks.
func tarWorkspace(root string) ([]byte, error) {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)

	err := filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		if info.IsDir() && skipDirs[info.Name()] {
			return filepath.SkipDir
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return nil
		}
		hdr, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		hdr.Name = filepath.ToSlash(rel)
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(tw, f)
		return err
	})
	if err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// --- Exec ---

// Exec unpacks the synced workspace actor-side and runs the command in it.
//
// Note what the composed command does NOT do: it does not quote, split, or
// rewrite req.Command. The command is appended to a `cd` and run by the
// actor's `sh -c`, so pipes, redirections, semicolons, and newlines mean
// exactly what they would mean in a local shell. That is the whole claim of
// M1 — there is no local execution path to miss, so there is also nothing to
// parse defensively.
func (b *Backend) Exec(ctx context.Context, req backend.ExecRequest, out io.Writer) (backend.ExecResult, error) {
	var res backend.ExecResult // Streamed stays false: see package doc.

	if strings.TrimSpace(req.Command) == "" {
		return res, fmt.Errorf("substrate: empty command")
	}
	if !b.synced {
		return res, fmt.Errorf("substrate: workspace not synced — call Sync before Exec")
	}
	if err := b.ensureResumed(); err != nil {
		return res, err
	}

	timeout := req.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}

	// Cwd is interpreted relative to the actor-side workspace root. An
	// absolute local path cannot exist actor-side, so a caller passing one
	// gets the workspace root rather than a confusing `cd` failure; phase 0
	// question 5 records this divergence.
	cwd := b.cfg.WorkspaceDir
	if rel := strings.TrimSpace(req.Cwd); rel != "" && !filepath.IsAbs(rel) {
		cwd = filepath.ToSlash(filepath.Join(b.cfg.WorkspaceDir, rel))
	}

	composed := fmt.Sprintf(
		"mkdir -p %s && printf %%s \"$SANDBOX_WORKSPACE_B64\" | base64 -d | tar -xzf - -C %s && cd %s && %s",
		b.cfg.WorkspaceDir, b.cfg.WorkspaceDir, cwd, req.Command)

	envvars := map[string]string{"SANDBOX_WORKSPACE_B64": b.payload}
	for k, v := range req.Env {
		if k == "SANDBOX_WORKSPACE_B64" {
			return res, fmt.Errorf("substrate: env var SANDBOX_WORKSPACE_B64 is reserved for the workspace upload")
		}
		envvars[k] = v
	}

	resp, err := b.postProcess(ctx, map[string]any{
		"command": []string{"sh", "-c", composed},
		"envvars": envvars,
		"timeout": timeout.String(),
	}, timeout)
	if err != nil {
		return res, err
	}

	// /process hands back both streams complete. Writing stdout then stderr
	// to the single writer loses interleaving; that loss is the backend's,
	// not the harness's, and is why Streamed is false.
	if resp.Stdout != "" {
		if _, err := io.WriteString(out, resp.Stdout); err != nil {
			return res, fmt.Errorf("substrate: write stdout: %w", err)
		}
	}
	if resp.Stderr != "" {
		if _, err := io.WriteString(out, resp.Stderr); err != nil {
			return res, fmt.Errorf("substrate: write stderr: %w", err)
		}
	}
	// A non-empty Error field is the actor failing to run the command, which
	// is a backend error and must not be mistaken for a nonzero exit.
	if resp.Error != "" {
		return res, fmt.Errorf("substrate: actor %s reported: %s", b.cfg.Actor, resp.Error)
	}

	res.ExitCode = resp.ExitCode
	return res, nil
}

type processResponse struct {
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	ExitCode int    `json:"exitCode"`
	Error    string `json:"error,omitempty"`
}

func (b *Backend) postProcess(ctx context.Context, body map[string]any, timeout time.Duration) (*processResponse, error) {
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("substrate: marshal request: %w", err)
	}

	// Outlive the actor-side timeout so a command killed in the actor comes
	// back as a result rather than as a client-side cancellation.
	ctx, cancel := context.WithTimeout(ctx, timeout+30*time.Second)
	defer cancel()

	url := fmt.Sprintf("http://%s/process", b.cfg.RouterURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	// Routing is by Host header through atenet-router, mirroring
	// resources.ActorDNSName upstream.
	req.Host = fmt.Sprintf("%s.%s.%s", b.cfg.Actor, b.cfg.Atespace, b.cfg.DNSSuffix)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("substrate: POST /process to actor %s: %w "+
			"(is `kubectl port-forward -n ate-system svc/atenet-router %s:80` running?)",
			b.cfg.Actor, err, portOf(b.cfg.RouterURL))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("substrate: POST /process returned %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	var pr processResponse
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return nil, fmt.Errorf("substrate: decode /process response: %w", err)
	}
	return &pr, nil
}

func portOf(addr string) string {
	if i := strings.LastIndex(addr, ":"); i >= 0 {
		return addr[i+1:]
	}
	return "8000"
}

// --- lifecycle ---

// ensureResumed creates and resumes the actor once per process when the
// backend was configured to manage it. A fresh create leaves the actor
// suspended, so the resume is unconditional rather than conditional on the
// create having happened.
func (b *Backend) ensureResumed() error {
	if !b.cfg.Manage || b.resumed {
		return nil
	}
	if out, err := runKube("kubectl", "ate", "create", "actor", b.cfg.Actor,
		"-a", b.cfg.Atespace, "--template", b.cfg.Template); err != nil {
		if !strings.Contains(out, "AlreadyExists") && !strings.Contains(out, "already exists") {
			return fmt.Errorf("substrate: create actor %s: %w\n%s", b.cfg.Actor, err, out)
		}
	}
	if out, err := runKube("kubectl", "ate", "resume", "actor", b.cfg.Actor, "-a", b.cfg.Atespace); err != nil {
		return fmt.Errorf("substrate: resume actor %s: %w\n%s", b.cfg.Actor, err, out)
	}
	b.resumed = true
	return nil
}

// Close suspends the actor if this backend created it. Best-effort: a failed
// suspend leaves a worker slot held, which is worth a warning to the caller
// but is not worth failing a completed run over.
func (b *Backend) Close(ctx context.Context) error {
	if !b.cfg.Manage || !b.resumed {
		return nil
	}
	b.resumed = false
	if out, err := runKube("kubectl", "ate", "suspend", "actor", b.cfg.Actor, "-a", b.cfg.Atespace); err != nil {
		return fmt.Errorf("substrate: suspend actor %s: %w\n%s", b.cfg.Actor, err, out)
	}
	return nil
}

func runKube(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}
