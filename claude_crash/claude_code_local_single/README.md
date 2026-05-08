# Claude Code — Local, Single Session

Kill a running Claude Code process on the local machine and resume the session with `claude --resume`. The simplest crash-recovery case: one harness, one session, no orchestration.

## Goal

Verify that a Claude Code session survives a hard process kill and can be resumed with full conversation history and context intact, relying only on the harness's default on-disk session state (`~/.claude/sessions/`).

## Prerequisites

- Claude Code CLI installed and on `$PATH`
- A scratch working directory — the demo writes real files on disk
- Two terminals side-by-side (terminal A runs Claude, terminal B issues the kill)

## Setup (both scenarios)

> **Safety note:** this demo kills a Claude Code process. The `kill-by-cwd.sh` script in this directory only targets the Claude whose working directory is `/tmp/claude-crash-demo`, so other Claude sessions (including the one you may be reading this README in) are not affected. Do **not** substitute `pkill -f claude` — that matches every Claude process on your machine.

```bash
mkdir -p /tmp/claude-crash-demo && cd /tmp/claude-crash-demo
```

Open a second terminal (terminal B). It can be in any directory — it only needs a path to the kill script in this demo dir.

---

## Scenario A — Kill between turns (file-edit task)

State spans both the conversation (what Claude remembers) and the filesystem (what was already written). We want to see both survive.

### Step 1. Start Claude Code

Terminal A, from `/tmp/claude-crash-demo`:

```bash
claude
```

### Step 2. Build up some state

Paste each prompt into Claude, one at a time. Wait for it to finish before the next.

**Prompt 1:**
```
Create a file called notes.md with three sections: "Goals", "Open Questions", and "Next Steps". Each section should have two placeholder bullet points.
```

**Prompt 2:**
```
Add a fourth section called "Risks" after "Open Questions", with two placeholder bullets.
```

**Prompt 3:**
```
In the "Goals" section, replace the placeholder bullets with: "ship v1 by end of quarter" and "onboard two new contributors".
```

At this point, `notes.md` exists on disk and Claude's conversation context contains the full history.

### Step 3. Kill the process

Terminal B (replace `<path-to-demo>` with wherever you cloned this repo):

```bash
<path-to-demo>/claude_code_local_single/kill-by-cwd.sh /tmp/claude-crash-demo
```

Terminal A should drop back to the shell prompt.

### Step 4. Resume

Terminal A, still in `/tmp/claude-crash-demo`:

```bash
claude --resume
```

Select the most recent session.

### Step 5. Verify — ask Claude to recall

**Prompt:**
```
What were we just working on, and what sections does notes.md currently have?
```

Expected: Claude names the file, lists all four sections (Goals, Open Questions, Risks, Next Steps), and recalls that the Goals bullets were rewritten.

### Step 6. Verify — inspect the session store

In a separate shell:

```bash
ls -la ~/.claude/sessions/ 2>/dev/null || ls -la ~/.claude/projects/
find ~/.claude -type d -name "*claude-crash-demo*" 2>/dev/null
```

Open the most recent session file (likely `.jsonl` under `~/.claude/projects/<path-slug>/`) and confirm the user prompts and assistant responses from Step 2 are present. Note what is and is not serialized: tool calls, tool results, file snapshots, cwd.

---

## Scenario B — Kill mid tool-call (long-running task)

The messier edge case: kill while Claude is actively executing a tool. We want to know whether the resumed session replays, skips, or errors on the interrupted call.

### Step 1. Start a fresh session

Terminal A:

```bash
cd /tmp/claude-crash-demo
claude
```

### Step 2. Trigger a long tool call

**Prompt:**
```
Run `sleep 60 && echo done > /tmp/claude-crash-demo/sleep-result.txt` as a background Bash command, then wait for it to finish and read the result file back to me.
```

Watch for Claude to start the Bash tool call. Do not wait for it to finish.

### Step 3. Kill mid-call

Terminal B, while the tool call is still running (within ~30 seconds):

```bash
<path-to-demo>/claude_code_local_single/kill-by-cwd.sh /tmp/claude-crash-demo
```

### Step 4. Resume

Terminal A:

```bash
claude --resume
```

### Step 5. Verify — ask Claude what happened

**Prompt:**
```
What was the last thing you were doing before you were interrupted? Did the sleep command finish, and if so, what's in sleep-result.txt?
```

Observations to record:
- Does Claude know it was interrupted?
- Does the resumed session show the completed or incomplete tool call?
- Does `/tmp/claude-crash-demo/sleep-result.txt` exist? (The `sleep` process may have outlived the harness — that is itself an interesting finding.)

### Step 6. Verify — inspect the session store

```bash
ls -lat ~/.claude/projects/*claude-crash-demo*/ 2>/dev/null | head
```

Open the latest session file and find the interrupted tool call. Look for: was the tool result recorded? Is there a marker for the interruption? What state does the harness assume on resume?

---

## What to record after running

Keep rough notes for comparison with later demos (local_multi, kind, openshell):

- **Where state lives on disk:** path and format
- **What survived the kill:** conversation turns, tool calls, tool results, cwd
- **What was lost:** anything only in memory
- **Graceful vs. hard kill:** the script uses `kill -9` (hard); editing it to drop `-9` (SIGTERM) is worth trying as a comparison
- **Mid-tool-call behavior:** replay? skip? error? orphan process?

## Cleanup

After you're done recording observations, tear down the demo artifacts. Session records under `~/.claude/projects/` are left in place — they're the evidence trail for what survived the kill.

### 1. Check for orphaned processes (Scenario B only)

The `sleep 60` from Scenario B can outlive the killed Claude. Check for survivors and kill only those spawned from the demo directory:

```bash
ps -eo pid,ppid,command | awk '/sleep 60/ && !/awk/ {print}'
```

If you see a `sleep 60` still running from the demo, kill it by PID:

```bash
kill <pid>
```

Do **not** run `pkill sleep` — it matches every `sleep` on your machine.

### 2. Remove the scratch directory

```bash
rm -rf /tmp/claude-crash-demo
```

This removes `notes.md`, `sleep-result.txt`, and anything else Claude wrote during the run.

### 3. (Optional) Close the resumed session

If the resumed `claude` in terminal A is still attached, exit it normally (`/exit` or Ctrl-D) so it flushes cleanly rather than being killed again.

---

## Open questions (revisit after running)

- Exact on-disk format of session state (per-session file? append-only log? snapshot?)
- Does `--resume` offer a selector when multiple sessions exist, or always pick the latest?
- Is there state the harness keeps only in memory that cannot be reconstructed from disk?
- Are orphaned child processes (like the `sleep` in Scenario B) cleaned up or left running?
