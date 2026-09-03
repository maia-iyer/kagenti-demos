// substrate-sandbox-hook: a single binary invoked by Claude Code to route
// shell operations into a per-session Agent Substrate sandbox actor.
//
// Subcommands:
//
//   session-start      Eager-mode SessionStart. Derives an actor name from
//                      session_id, creates or resumes the actor via
//                      `kubectl ate`, and writes
//                      `export SUBSTRATE_ACTOR_NAME=<name>` to $CLAUDE_ENV_FILE
//                      so `exec` (running under Claude's Bash tool) sees the
//                      actor in its environment. The env-file is per-session,
//                      so two concurrent sessions in the same scratch dir
//                      pick up different actor names.
//
//   session-start-lazy Lazy-mode SessionStart. Same env-file write as above,
//                      plus `export SUBSTRATE_SANDBOX_LAZY=1`. Does NO
//                      cluster work — the actor is created on the first
//                      `exec` call. Sessions that never shell out never
//                      touch the cluster.
//
//   session-end        Suspends the actor.
//
//   session-end-lazy   Same, but skips silently if the actor was never
//                      created (session never shelled out).
//
//   exec -- <cmd>      Reads SUBSTRATE_ACTOR_NAME (and SUBSTRATE_SANDBOX_LAZY)
//                      from the environment, tars the workspace, uploads it
//                      to the actor via POST /process. In lazy mode: creates
//                      the actor if needed, resumes before the POST, suspends
//                      after a successful POST. Prints stdout/stderr; exits
//                      with the sandbox's exit code.
//
//   check-bash      Invoked by the PreToolUse hook on Bash. Reads the tool
//                   input JSON from stdin; if the command is not routed
//                   through `substrate-sandbox-hook exec --`, prints a
//                   deny decision as JSON and exits nonzero so Claude sees
//                   the block and re-issues through the sandbox.
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
	actorEnvVar  = "SUBSTRATE_ACTOR_NAME"
	lazyEnvVar   = "SUBSTRATE_SANDBOX_LAZY"
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
		fatal("usage: substrate-sandbox-hook {session-start|session-start-lazy|session-end|session-end-lazy|exec -- <cmd>|check-bash}")
	}
	switch os.Args[1] {
	case "session-start":
		sessionStart()
	case "session-start-lazy":
		sessionStartLazy()
	case "session-end":
		sessionEnd()
	case "session-end-lazy":
		sessionEndLazy()
	case "exec":
		execCmd(os.Args[2:])
	case "check-bash":
		checkBash()
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

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "substrate-sandbox-hook: "+format+"\n", args...)
	os.Exit(1)
}

// --- session-start ---

func sessionStart() {
	sessionID := readSessionID()
	name := actorName(sessionID)

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

	// Publish the actor name to $CLAUDE_ENV_FILE so `exec` (invoked from
	// Claude's Bash tool as a subprocess) reads it via the environment.
	// This is per-session, so two concurrent Claude sessions in the same
	// scratch dir each carry their own actor name in their own preamble.
	envFile := os.Getenv("CLAUDE_ENV_FILE")
	if envFile == "" {
		fatal("CLAUDE_ENV_FILE not set — SessionStart must run under Claude Code so the actor name reaches `exec`")
	}
	line := fmt.Sprintf("export %s=%s\n", actorEnvVar, name)
	if err := os.WriteFile(envFile, []byte(line), 0o644); err != nil {
		fatal("write CLAUDE_ENV_FILE: %v", err)
	}
}

// sessionStartLazy is the lazy-mode SessionStart. It does NO cluster work —
// it just derives the actor name from the session ID and publishes it (plus
// the lazy-mode flag) to $CLAUDE_ENV_FILE. The actor is created on the
// first `exec` call, not here, so a session that never shells out never
// touches the cluster.
func sessionStartLazy() {
	sessionID := readSessionID()
	name := actorName(sessionID)

	envFile := os.Getenv("CLAUDE_ENV_FILE")
	if envFile == "" {
		fatal("CLAUDE_ENV_FILE not set — session-start-lazy must run under Claude Code so the actor name reaches `exec`")
	}
	content := fmt.Sprintf("export %s=%s\nexport %s=1\n", actorEnvVar, name, lazyEnvVar)
	if err := os.WriteFile(envFile, []byte(content), 0o644); err != nil {
		fatal("write CLAUDE_ENV_FILE: %v", err)
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
}

// sessionEndLazy is the lazy-mode variant of sessionEnd. If the session
// never ran a shell command, the actor was never created; we skip the
// suspend rather than emit a spurious "not found" warning. If the actor
// does exist, we suspend as a safety net in case a call was interrupted
// mid-flight and left it running.
func sessionEndLazy() {
	sessionID := readSessionID()
	name := actorName(sessionID)

	if out, err := runKube("kubectl", "ate", "get", "actor", name, "-a", atespace); err != nil {
		if strings.Contains(out, "NotFound") || strings.Contains(out, "not found") {
			return
		}
		fmt.Fprintf(os.Stderr, "substrate-sandbox-hook: get actor %s (lazy end) failed: %v\n%s\n", name, err, out)
		return
	}
	if _, err := runKube("kubectl", "ate", "suspend", "actor", name, "-a", atespace); err != nil {
		fmt.Fprintf(os.Stderr, "substrate-sandbox-hook: suspend actor %s (lazy end) failed: %v\n", name, err)
	}
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

	// Read the target actor from the environment. SessionStart publishes it
	// to $CLAUDE_ENV_FILE, which Claude Code sources as a preamble before
	// every Bash command.
	actor := strings.TrimSpace(os.Getenv(actorEnvVar))
	if actor == "" {
		fatal("%s not set in environment (SessionStart may not have run, or $CLAUDE_ENV_FILE was not sourced)", actorEnvVar)
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

	// Lazy mode: create-if-missing, then resume for this call, suspend after.
	// This releases the worker slot between commands so a user who steps away
	// for ten minutes isn't holding one. Create is idempotent (AlreadyExists
	// after the first call); resume is a no-op on an already-running actor.
	// SessionStart in lazy mode does no cluster work, so the first `exec` in
	// a session pays the create cost; subsequent calls just resume/suspend.
	lazy := os.Getenv(lazyEnvVar) == "1"
	if lazy {
		if out, err := runKube("kubectl", "ate", "create", "actor", actor, "-a", atespace, "--template", template); err != nil {
			if !strings.Contains(out, "AlreadyExists") && !strings.Contains(out, "already exists") {
				fatal("create actor %s (lazy): %v\n%s", actor, err, out)
			}
		}
		if out, err := runKube("kubectl", "ate", "resume", "actor", actor, "-a", atespace); err != nil {
			fatal("resume actor %s (lazy): %v\n%s", actor, err, out)
		}
	}

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
		// Hook-level failure (POST didn't return). Leave the actor running
		// so the user can retry without paying resume latency again.
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

	// Lazy mode: suspend after a successful POST regardless of the user
	// command's exit code — a nonzero test run is expected, not a hook error.
	if lazy {
		if out, err := runKube("kubectl", "ate", "suspend", "actor", actor, "-a", atespace); err != nil {
			fmt.Fprintf(os.Stderr, "substrate-sandbox-hook: suspend actor %s (lazy) failed: %v\n%s\n", actor, err, out)
		}
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

// --- check-bash ---
//
// PreToolUse hook for the Bash tool. Claude Code invokes this on every Bash
// call with a JSON payload on stdin:
//
//   {"tool_name":"Bash","tool_input":{"command":"..."}, ...}
//
// If the command is not routed through the sandbox, we emit a permissionDecision
// of "deny" with an explanatory reason. Claude sees the reason and re-issues
// the command through `substrate-sandbox-hook exec --`.

type bashHookInput struct {
	ToolName  string `json:"tool_name"`
	ToolInput struct {
		Command string `json:"command"`
	} `json:"tool_input"`
}

type hookOutput struct {
	HookSpecificOutput hookSpecificOutput `json:"hookSpecificOutput"`
}

type hookSpecificOutput struct {
	HookEventName            string `json:"hookEventName"`
	PermissionDecision       string `json:"permissionDecision"`
	PermissionDecisionReason string `json:"permissionDecisionReason"`
}

func checkBash() {
	var in bashHookInput
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		// Fail closed: if we can't parse the input we can't verify the command,
		// so deny with an explanation.
		emitBashDeny("substrate-sandbox-hook check-bash: could not parse hook input: " + err.Error())
		return
	}
	cmd := strings.TrimSpace(in.ToolInput.Command)
	if isSandboxRouted(cmd) {
		// Allow: no output is a passthrough, exit 0.
		return
	}
	emitBashDeny(
		"This session runs shell commands inside a remote Agent Substrate sandbox " +
			"(Alpine Linux), NOT on the local laptop. The Bash command you attempted " +
			"was blocked because it did not go through the sandbox binary.\n\n" +
			"Re-issue the command as:\n\n" +
			"    ~/bin/substrate-sandbox-hook exec -- <your command>\n\n" +
			"Everything after `--` runs inside the sandbox actor with /workspace as CWD. " +
			"See the substrate-sandbox skill for details. If you truly need to run " +
			"something on the laptop, ask the user first — they can approve a specific " +
			"local command by adding it to the allow list in .claude/settings.json.",
	)
}

// isSandboxRouted returns true if the command's first token is the sandbox
// binary. Accepts a few equivalent spellings of the path.
func isSandboxRouted(cmd string) bool {
	// Strip a leading `cd <dir> && ` that Claude Code sometimes prepends via
	// its own tooling — anything before the first `&&` shouldn't matter for
	// the guarantee we care about (that the payload runs in the sandbox).
	trimmed := strings.TrimSpace(cmd)
	if trimmed == "" {
		return false
	}
	// Grab first whitespace-separated token.
	firstTok := trimmed
	for i, r := range trimmed {
		if r == ' ' || r == '\t' {
			firstTok = trimmed[:i]
			break
		}
	}
	// Accept these prefixes as "routed via sandbox".
	home := os.Getenv("HOME")
	acceptable := []string{
		"~/bin/substrate-sandbox-hook",
		"$HOME/bin/substrate-sandbox-hook",
		"substrate-sandbox-hook",
	}
	if home != "" {
		acceptable = append(acceptable, filepath.Join(home, "bin", "substrate-sandbox-hook"))
	}
	for _, p := range acceptable {
		if firstTok == p {
			return true
		}
	}
	return false
}

func emitBashDeny(reason string) {
	// Emit both signals for maximum robustness across Claude Code versions:
	// 1. Structured JSON on stdout so the reason is shown as tool feedback.
	// 2. The same reason on stderr as a fallback.
	// 3. Exit code 2, which unconditionally blocks the tool call even if
	//    JSON parsing fails on the reader side.
	out := hookOutput{
		HookSpecificOutput: hookSpecificOutput{
			HookEventName:            "PreToolUse",
			PermissionDecision:       "deny",
			PermissionDecisionReason: reason,
		},
	}
	_ = json.NewEncoder(os.Stdout).Encode(&out)
	fmt.Fprintln(os.Stderr, reason)
	os.Exit(2)
}
