# Claude Code Crash Recovery Experiments

Testing session recovery when Claude Code processes are killed or interrupted.

## Scenarios

### 1. Local Machine - Interrupted Session Recovery

**Goal:** Resume interrupted Claude Code sessions when process is killed.

**Setup:**
```bash
# Start a long-running session
claude --session-name long-task

# In another terminal, kill the process
pkill -f "claude.*long-task"

# Resume the session
claude --resume
```

**Expected behavior:**
- Session state is preserved in `~/.claude/sessions/`
- `claude --resume` reloads the last interrupted session
- Conversation history and context are intact

**Implementation:**
- Shell alias: `alias claude='claude --resume'` (always resumes if available)
- Or manual: `claude --resume` when needed

---

### 2. Local Machine - Multiple Interrupted Sessions

**Goal:** Resume all interrupted sessions simultaneously.

**Setup:**
```bash
# Start multiple sessions
claude --session-name task-1 &
claude --session-name task-2 &
claude --session-name task-3 &

# Kill all Claude processes
pkill -f claude

# Resume all at once
bash ~/.claude/resume-all-tmux.sh

# Attach to tmux session
tmux attach-session -t claude-sessions
```

**Expected behavior:**
- All interrupted sessions resume in separate tmux windows
- Each maintains its own conversation context
- Can switch between sessions with tmux (Prefix + n/p)

**Files:**
- `~/.claude/resume-all-tmux.sh` - Script to resume all in tmux

---

### 3. Cloud (Kind) - Pod Session Persistence

**Goal:** Resume Claude sessions when a Kind pod is restarted or rescheduled.

**Challenges:**
- Sessions stored in ephemeral pod storage by default
- Pod restart loses all state unless persistence is configured
- Network interruptions during long-running sessions

**Setup with Kind:**
```bash
# Create Kind cluster
kind create cluster --name claude-sessions

# Deploy persistent volume for session storage
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: claude-sessions-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /tmp/claude-sessions

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: claude-sessions-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

# Deploy Claude Code pod with persistent session storage
# (See claude-deployment.yaml)

# Kill the pod and verify session recovery
kubectl delete pod <pod-name>

# New pod should auto-resume from persistent sessions
```

**Expected behavior:**
- Sessions persist across pod restarts
- Startup script resumes all interrupted sessions automatically
- No manual intervention needed

---

### 4. Local Machine - OpenShell Sandbox Interrupted Session Recovery

**Goal:** Resume an interrupted OpenShell sandbox session after the host process is killed.

**Expected behavior:**
- Sandbox workspace state (files, shell history, env) persists across kills
- Re-launching the sandbox reattaches to the previous workspace without losing in-progress work
- Any agent-visible state (VFS contents, cwd, pending tasks) is restored

**Open questions:**
- Where does OpenShell persist workspace state by default, and is it opt-in?
- Does it expose a session/workspace identifier we can target for resume?
- Is there a "snapshot before kill" primitive, or only best-effort recovery from the last persisted point?

---

### 5. Local Machine - OpenShell Sandbox Multi-Session

**Goal:** Run multiple concurrent OpenShell sandboxes, kill all, resume all.

**Expected behavior:**
- Each sandbox maintains its own isolated workspace through the kill/resume cycle
- No cross-session state bleed (file contents, env, history stay partitioned)
- Resume flow scales to N sessions without manual per-session intervention

**Open questions:**
- Does OpenShell multiplex cleanly, or is one-process-per-sandbox the assumption?
- What's the isolation boundary — process, container, VFS namespace?

---

### 6. Cloud (Kind) - OpenShell Sandbox Pod Persistence

**Goal:** Resume an OpenShell sandbox when its Kind pod is deleted or rescheduled.

**Expected behavior:**
- Workspace survives pod restart via PVC-backed storage
- New pod auto-reattaches to the persisted workspace on startup
- Pod identity / network identity is stable enough for agents with an external reference to the sandbox

**Open questions:**
- Does OpenShell ship a container image / Helm chart, or do we wrap it ourselves?
- How does its persistence model line up with the AgentSandbox CRD (stable hostname, PV, pause/resume)?
- Where are the platform-vs-harness boundaries — what does OpenShell expect the platform to provide, and what does it handle internally?

---

## Implementation Details

### Local: resume-all-tmux.sh

Location: `~/.claude/resume-all-tmux.sh`

Features:
- Lists all interrupted sessions
- Creates tmux session `claude-sessions`
- Spawns each session in a separate window
- Provides attach command

Usage:
```bash
bash ~/.claude/resume-all-tmux.sh
tmux attach-session -t claude-sessions
```

---

### Cloud: Pod Entrypoint

For Kind deployment, the pod should:
1. Mount persistent volume at `~/.claude/sessions`
2. Run startup script on container start
3. Auto-attach to tmux session (or provide access via kubectl exec)

Entrypoint script:
```bash
#!/bin/bash
# Initialize session storage
mkdir -p ~/.claude/sessions

# Resume all interrupted sessions in tmux
bash ~/.claude/resume-all-tmux.sh

# Keep container alive
tmux attach-session -t claude-sessions || sleep infinity
```

---

## Testing Checklist

- [ ] Local: Start session, kill process, resume with `claude --resume`
- [ ] Local: Start 3 sessions, kill all, verify all resume in tmux
- [ ] Local: Verify session history persists after resume
- [ ] Cloud: Create Kind cluster with persistent volume
- [ ] Cloud: Deploy Claude pod, kill it, verify auto-resume
- [ ] Cloud: Verify persistent storage survives pod restarts
- [ ] Cloud: Test kubectl exec into pod and attach to tmux session
- [ ] OpenShell local: Start sandbox, kill process, verify workspace resume
- [ ] OpenShell local: Start N sandboxes, kill all, verify isolated resume
- [ ] OpenShell cloud: Deploy sandbox pod with PVC, delete pod, verify workspace survives

---

## Open Questions

- Does `claude sessions list --format=json` exist? May need to verify CLI API.
- What's the actual session storage format in `~/.claude/sessions/`?
- Can Claude Code handle multiple simultaneous sessions in one process, or do they need separate processes?
- For cloud: Should we use init containers for session recovery, or run in main container?

---

## References

- Claude Code CLI docs (if available)
- Kind documentation: https://kind.sigs.k8s.io/
- tmux pane management: https://github.com/tmux/tmux/wiki
