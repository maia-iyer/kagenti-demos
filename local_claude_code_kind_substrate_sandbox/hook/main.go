// substrate-sandbox-hook: a single binary invoked by Claude Code to route
// shell operations into a per-session Agent Substrate sandbox actor.
//
// Subcommands:
//
//   session-start   Invoked by the SessionStart hook. Reads session_id from
//                   stdin JSON, derives an actor name, creates or resumes the
//                   actor via `kubectl ate`, and writes the actor name to a
//                   pin file for `exec` to read.
//
//   session-end     Invoked by the SessionEnd hook. Reads session_id from
//                   stdin JSON, suspends the actor, removes the pin file.
//
//   exec -- <cmd>   Invoked by Claude via a skill. Tars the workspace,
//                   uploads it to the actor via POST /process with the
//                   command composed in, prints stdout/stderr, exits with
//                   the sandbox's exit code.
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	atespace     = "claude-sandbox"
	template     = "ate-demo-sandbox/sandbox-template"
	dnsSuffix    = "actors.resources.substrate.ate.dev"
	pinFileName  = "substrate-sandbox-actor"
	atenetAddr   = "localhost:8000"
	execTimeout  = 5 * time.Minute
)

// skipDirs are workspace subdirectories not uploaded to the actor.
// Their state is kept on the actor across suspends and rebuilt only when
// needed by the commands the user runs.
var skipDirs = map[string]bool{
	".git": true, ".claude": true,
	"node_modules": true, ".venv": true, "venv": true,
	"__pycache__": true, ".pytest_cache": true, ".mypy_cache": true, ".tox": true,
	"target": true, "dist": true, "build": true, "bin": true,
}

func main() {
	if len(os.Args) < 2 {
		fatal("usage: substrate-sandbox-hook {session-start|session-end|exec -- <cmd>}")
	}
	switch os.Args[1] {
	case "session-start":
		sessionStart()
	case "session-end":
		sessionEnd()
	case "exec":
		execCmd(os.Args[2:])
	default:
		fatal("unknown subcommand: %s", os.Args[1])
	}
}

// --- Shared helpers ---

type hookInput struct {
	SessionID string `json:"session_id"`
}

// readSessionID parses the hook stdin JSON and returns session_id.
func readSessionID() string {
	var in hookInput
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fatal("read hook input: %v", err)
	}
	if in.SessionID == "" {
		fatal("hook input missing session_id")
	}
	return in.SessionID
}

// actorName derives a stable actor name from the session ID.
func actorName(sessionID string) string {
	h := sha256.Sum256([]byte(sessionID))
	return "sess-" + hex.EncodeToString(h[:])[:8]
}

// actorDNSName returns the atenet-router Host header for the actor.
// This mirrors resources.ActorDNSName in the substrate module.
func actorDNSName(name string) string {
	return fmt.Sprintf("%s.%s.%s", name, atespace, dnsSuffix)
}

// projectDir returns the scratch project directory: CLAUDE_PROJECT_DIR if set
// (hooks + skill invocation both set it), else the current working directory.
func projectDir() string {
	if d := os.Getenv("CLAUDE_PROJECT_DIR"); d != "" {
		return d
	}
	d, err := os.Getwd()
	if err != nil {
		fatal("getwd: %v", err)
	}
	return d
}

func pinFilePath() string {
	return filepath.Join(projectDir(), ".claude", pinFileName)
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "substrate-sandbox-hook: "+format+"\n", args...)
	os.Exit(1)
}

// --- session-start ---

func sessionStart() {
	sessionID := readSessionID()
	name := actorName(sessionID)

	// Refuse to start if a pin file already exists in this scratch dir.
	// Multiple concurrent Claude sessions must run in distinct scratch dirs
	// so their pin files (and thus their target actors) don't collide.
	// A pin file left behind by a crashed session for the SAME actor is
	// treated as a resume and allowed through.
	pinPath := pinFilePath()
	if existing, err := os.ReadFile(pinPath); err == nil {
		if strings.TrimSpace(string(existing)) != name {
			fatal("another substrate-sandbox session is active in this scratch dir "+
				"(pin file references actor %q, this session wants %q).\n"+
				"Run a concurrent Claude session from a different scratch directory, "+
				"or remove %s if the previous session ended abnormally.",
				strings.TrimSpace(string(existing)), name, pinPath)
		}
	}

	// Create the actor if it doesn't exist; ignore AlreadyExists.
	if out, err := runKube("kubectl", "ate", "create", "actor", name, "-a", atespace, "--template", template); err != nil {
		if !strings.Contains(out, "AlreadyExists") && !strings.Contains(out, "already exists") {
			fatal("create actor %s: %v\n%s", name, err, out)
		}
	}

	// Always resume — a fresh create leaves the actor suspended.
	if out, err := runKube("kubectl", "ate", "resume", "actor", name, "-a", atespace); err != nil {
		fatal("resume actor %s: %v\n%s", name, err, out)
	}

	// Write the pin file so `exec` knows the actor name.
	path := pinFilePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		fatal("mkdir pin dir: %v", err)
	}
	if err := os.WriteFile(path, []byte(name+"\n"), 0o644); err != nil {
		fatal("write pin file: %v", err)
	}
}

// --- session-end ---

func sessionEnd() {
	sessionID := readSessionID()
	name := actorName(sessionID)

	// Suspend is best-effort; session is ending anyway.
	if _, err := runKube("kubectl", "ate", "suspend", "actor", name, "-a", atespace); err != nil {
		fmt.Fprintf(os.Stderr, "substrate-sandbox-hook: suspend actor %s failed: %v\n", name, err)
	}

	_ = os.Remove(pinFilePath())
}

// runKube runs a kubectl-ate command and returns the combined output.
func runKube(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// --- exec ---

func execCmd(args []string) {
	if len(args) < 1 || args[0] != "--" {
		fatal("usage: substrate-sandbox-hook exec -- <command>")
	}
	userCmd := strings.Join(args[1:], " ")
	if strings.TrimSpace(userCmd) == "" {
		fatal("exec: empty command")
	}

	// Read pin file to learn the target actor.
	pinBytes, err := os.ReadFile(pinFilePath())
	if err != nil {
		fatal("read pin file (SessionStart may not have run): %v", err)
	}
	actor := strings.TrimSpace(string(pinBytes))
	if actor == "" {
		fatal("pin file empty")
	}

	// Serialize concurrent execs against the same actor.
	lockPath := fmt.Sprintf("/tmp/substrate-sandbox-hook-%s.lock", actor)
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		fatal("open lock: %v", err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		fatal("flock: %v", err)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	// Tar+gzip the workspace.
	root := projectDir()
	tarball, err := tarWorkspace(root)
	if err != nil {
		fatal("tar workspace: %v", err)
	}
	b64 := base64.StdEncoding.EncodeToString(tarball)

	// Compose command and POST /process.
	composed := `mkdir -p /workspace && printf %s "$B64" | base64 -d | tar -xzf - -C /workspace && cd /workspace && ` + userCmd
	body := map[string]any{
		"command": []string{"sh", "-c", composed},
		"envvars": map[string]string{"B64": b64},
		"timeout": execTimeout.String(),
	}
	respPayload, err := postProcess(actor, body)
	if err != nil {
		fatal("POST /process: %v", err)
	}

	if respPayload.Stdout != "" {
		fmt.Print(respPayload.Stdout)
	}
	if respPayload.Stderr != "" {
		fmt.Fprint(os.Stderr, respPayload.Stderr)
	}
	if respPayload.Error != "" {
		fmt.Fprintf(os.Stderr, "\n(sandbox reported error: %s)\n", respPayload.Error)
	}
	os.Exit(respPayload.ExitCode)
}

type processResponse struct {
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	ExitCode int    `json:"exitCode"`
	Error    string `json:"error,omitempty"`
}

func postProcess(actor string, body map[string]any) (*processResponse, error) {
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), execTimeout+30*time.Second)
	defer cancel()

	url := fmt.Sprintf("http://%s/process", atenetAddr)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Host = actorDNSName(actor)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("status %d: %s", resp.StatusCode, string(msg))
	}
	var pr processResponse
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	return &pr, nil
}

// tarWorkspace tars+gzips root, skipping paths in skipDirs.
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
		// Follow symlinks by their targets? For a demo, skip symlinks entirely.
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
		if info.Mode().IsRegular() {
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			_, err = io.Copy(tw, f)
			f.Close()
			if err != nil {
				return err
			}
		}
		return nil
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
