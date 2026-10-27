# Architecture

How the pieces of this demo fit together: a local **parent coding
agent** session (Claude Code or OpenCode — picked at setup time with
`PARENT=`) dispatches isolated **leaves** to MOCA on a kind cluster
via `mocactl`, against a workload Context Service holds the files for
and promoted config bundles the control plane holds the skills for,
and collects their results later.

## Components

```mermaid
flowchart LR
  subgraph laptop["Operator's laptop"]
    direction TB
    OP["Operator<br/>(issues prompts in sequence)"]
    subgraph cc["Parent coding agent — Claude Code or OpenCode<br/>cwd = ~/tmp/moca-chained-scratch"]
      direction TB
      TASK["In-process subagent tool<br/>Task / task — DENIED"]:::denied
      SKILL["skill: moca-delegate-task<br/>(upstream, verbatim)"]
      BASH["Bash"]
    end
    SCRATCH[("Scratch dir (IS the project)<br/>src/ · tests/ · vendor/ · docs/ · README.md · MOCA.md<br/>leaves/*.prompt.txt · *.context · *.text<br/>.claude/settings.json OR .opencode/opencode.jsonc · .gitignore")]
    MOCACTL["mocactl<br/>(official client, owns all auth)"]
    CTXCTL["contextctl<br/>(ctx pack @ dispatch time, per leaf)"]
    LEDGER[("~/.local/state/mocactl/<br/>subagents.jsonl")]
    WORKER["detached worker per leaf<br/>holds sync POST /v1/runs"]
    AUTH[("~/.config/mocactl<br/>tokens — Read DENIED")]:::denied
    PF{{"port-forwards<br/>8080 harness · 8090 control plane · 9090 context-service"}}
  end

  subgraph cluster["kind cluster"]
    direction TB
    subgraph nsmoca["namespace: moca"]
      CP["control plane"]
      SUP["supervisor / harness"]
      REDIS[("Redis")]
      RESULTS[("session + result store<br/>24h TTL")]
      BUNDLES[("promoted config bundles<br/>DIGEST_PUBLIC · DIGEST_FULL<br/>sha256-pinned skills + commands")]
    end
    subgraph nsctx["namespace: context-service"]
      CS["Context Service"]
      REV[("frozen revision<br/>sha256-pinned")]
    end
    subgraph nssb["namespace: moca-sandbox"]
      POD0["moca-sandbox-0<br/>container: sandbox"]
      POD1["moca-sandbox-1<br/>container: sandbox"]
    end
  end

  OP -->|"prompt 1..4"| cc
  cc -.->|"re-routes to"| SKILL
  SKILL --> BASH
  BASH --> MOCACTL
  BASH --> CTXCTL
  CTXCTL -->|"writes leaves/LABEL.context"| SCRATCH
  cc <--> SCRATCH
  MOCACTL --- AUTH
  MOCACTL --> LEDGER
  MOCACTL -->|"workloads create: upload bundle"| PF
  MOCACTL -->|"promote: upload skills+commands<br/>(setup only, per bundle)"| PF
  MOCACTL -->|"spawn: forks"| WORKER
  MOCACTL -->|"create session"| PF
  WORKER -->|"POST /v1/runs<br/>(--config DIGEST --workload)"| PF
  MOCACTL -->|"get / subagents"| PF
  PF --> CP
  PF --> SUP
  PF --> CS
  CP --- REDIS
  CP --- BUNDLES
  SUP --- RESULTS
  CS --- REV
  SUP -->|"seed workload PVC from frozen revision<br/>(mount: read-only or writable)"| CS
  SUP -->|"apply config overlay<br/>(skills from DIGEST)"| POD0
  SUP -->|"mount workload view at<br/>/workspace/.moca-context/runs/&lt;sid&gt;"| POD0
  SUP --> POD1

  classDef denied stroke-dasharray: 4 3,color:#b00,stroke:#b00
```

Key: dashed red = deliberately blocked by the parent agent's config
(`.claude/settings.json` for Claude Code, `.opencode/opencode.jsonc`
for OpenCode) — the in-process subagent tool (`Task` / `task`) and
reading mocactl's token dir.

## Dispatch / collect sequence (one leaf)

```mermaid
sequenceDiagram
  autonumber
  actor OP as Operator
  participant CC as Parent agent (Claude/OpenCode)
  participant MC as mocactl
  participant W as detached worker
  participant SV as MOCA supervisor
  participant CS as Context Service
  participant SB as sandbox pod
  participant FS as scratch leaves dir
  participant LEDGER as mocactl ledger<br/>(~/.local/state/mocactl/<br/>subagents.jsonl)

  OP->>CC: "Dispatch a subagent to diagnose…"
  CC->>FS: write leaves/LABEL.prompt.txt
  CC->>FS: contextctl ctx pack . -> leaves/LABEL.context
  CC->>MC: mocactl workloads create --context leaves/LABEL.context --json
  MC->>CS: upload bundle
  MC-->>CC: workloadId WLID
  CC->>MC: mocactl spawn --kind prompt --config DIGEST --workload WLID [--writable] --tag TAG --label LABEL --json
  Note over CC,MC: permission prompt = operator's visual confirmation<br/>digest, workload id and label visible on the command line
  MC->>SV: create session with configRef and workloadId
  SV-->>MC: sessionId
  MC->>LEDGER: append row — label · sessionId · workloadId · bundle · tag · submittedAt
  MC->>W: fork (detached)
  MC-->>CC: stdout — type=session, sessionId, pid
  W->>SV: POST /v1/runs (synchronous, no disconnect-abort)
  CC-->>OP: dispatched, sessionId=… then STOPS (no polling)

  Note over SV,SB: leaf runs server-side — session pins to one pod on first turn
  SV->>SB: apply config overlay — skills and commands from DIGEST
  SV->>CS: fetch frozen revision (lazy, cached per user+revision)
  CS-->>SV: bundle bytes (streamed, sha256-verified)
  SV->>SB: mount view at /workspace/.moca-context/runs/sid<br/>(read-only, or writable per-run copy)
  SV->>SB: leaf tool calls, cwd = that mount
  SB-->>SV: final message
  SV->>SV: persist result BEFORE responding (24h TTL)
  SV-->>W: 200 (worker may already be dead — irrelevant)

  Note over OP,CC: minutes or hours later — may be a brand-new parent-agent session
  OP->>CC: "Check on that subagent."
  CC->>MC: mocactl subagents --tag TAG --json (look up label=LABEL)
  MC->>LEDGER: read rows
  LEDGER-->>MC: {sessionId, workloadId, state, …}
  MC-->>CC: sessionId SID, workloadId WLID
  CC->>MC: mocactl get SID --out leaves --json
  MC->>SV: fetch result
  SV-->>MC: status — queued, responded, failed or paused
  MC->>FS: write leaves/SID.text (when responded)
  CC->>FS: read result
  CC->>MC: mocactl workloads delete WLID (after collection)
  CC-->>OP: surface diagnosis (or still running, and stop)
```

## Chaining: context flows as prompt text only

The parent does the sequencing — MOCA has no "on complete, trigger X"
primitive, and neither leaf knows a chain exists.

```
                leaf 1 "diagnose"                      leaf 2 "fix"
         ┌──────────────────────────┐          ┌──────────────────────────┐
         │ session A                │          │ session B                │
         │ config  DIGEST_PUBLIC    │          │ config  DIGEST_FULL      │
         │ workload WLID_A          │          │ workload WLID_B          │
         │   mounted READ-ONLY      │          │   WRITABLE per-run copy  │
         │ runs tests, reports      │          │ edits src/, runs tests   │
         └────────────┬─────────────┘          └────────────┬─────────────┘
                      │ final message                       │ final message
                      ▼                                     ▼
            leaves/<sidA>.text                     leaves/<sidB>.text
                      │                                     │
                      │  parent inlines VERBATIM             │
                      └────────► leaves/fix.prompt.txt       └──► report to operator

   Each leaf has its own workload, packed and created at dispatch and
   deleted after collection, and boots with its own content-addressed
   config bundle — same `mocactl spawn`, different posture. Each
   child's identity is the triple (config digest, workload revision,
   sessionId), all sha256-pinned and server-held. A workload created
   with `--mount writable` keeps edits on its own PVC until the
   workload is deleted, so a follow-up spawn on the same workload sees
   them; a `--mount read-only` workload exposes an immutable view and
   leaves return findings in the final message. No file paths cross
   the leaf boundary.
```

Isolation is substrate-enforced at the workload level (each workload
gets its own StatefulSet and PVC under `moca-sandbox`, provisioned on
activate), so leaves *could* fan out concurrently; this demo
deliberately stays a sequential chain.

## Trust and durability boundaries

| Boundary | What it guarantees | What it does not |
| --- | --- | --- |
| In-process subagent tool (`Task` / `task`) denied + `moca-delegate-task` skill | Subagent work cannot run in-process on the laptop | — |
| `mocactl` owns auth (`~/.config/mocactl`, Read-denied) | Demo stores no secret; no token plumbing | — |
| Promoted config bundle, sha256-pinned | The skills (and commands) a leaf boots with are content-addressed and server-held; two leaves can share one workload but differ in posture | Ships skills + commands only — a `CLAUDE.md` under the promoted dir is NOT included and does not travel to the sandbox |
| Workload mount read-only (diagnose leaf) | The leaf cannot alter the frozen revision | — |
| Workload mount writable (fix leaf) | Each workload gets its own PVC; edits persist across runs on that workload until the workload is deleted | A workload's edits are visible to any spawn on the same workload — a leaf cannot assume the PVC starts at the frozen revision mid-chain |
| Per-workload StatefulSet and PVC under `moca-sandbox` | Two users' workloads do not share a sandbox or disk; `workloads delete` reaps both | — |
| Server persists result before responding to `/v1/runs` | Quit the parent agent, close the laptop, reboot — result survives | Nothing: there is **no cancel** |
| Server-side result store | Collectable for **24h** | Past 24h, or after `teardown.sh`, it's gone |
| Context Service frozen revision | Sha256-pinned, immutable upload; later uploads to the same workload are rejected | — |
| NetworkPolicy between `moca-sandbox` and everything else | Sandbox network isolation | Requires a NetworkPolicy-enforcing CNI (kind ≥ 0.24.0) |
