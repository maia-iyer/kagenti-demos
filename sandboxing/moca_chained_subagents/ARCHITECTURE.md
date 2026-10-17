# Architecture

How the pieces of this demo fit together: a local Claude Code session
(the **parent**) dispatches isolated **leaves** to MOCA on a kind
cluster via `mocactl`, against a workload Context Service holds the
files for, and collects their results later.

## Components

```mermaid
flowchart LR
  subgraph laptop["Operator's laptop"]
    direction TB
    OP["Operator<br/>(issues prompts in sequence)"]
    subgraph cc["Claude Code — parent session<br/>cwd = ~/tmp/moca-chained-scratch"]
      direction TB
      TASK["Task tool<br/>DENIED"]:::denied
      SKILL["skill: moca-delegate-task<br/>(upstream, verbatim)"]
      BASH["Bash"]
    end
    SCRATCH[("Scratch dir<br/>src/ · tests/ · vendor/ · docs/ · README.md<br/>leaves/*.prompt.txt · *.context · *.json · *.text<br/>.claude/settings.json")]
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
  MOCACTL -->|"spawn: forks"| WORKER
  MOCACTL -->|"create session"| PF
  WORKER -->|"POST /v1/runs (--workload)"| PF
  MOCACTL -->|"get / subagents"| PF
  PF --> CP
  PF --> SUP
  PF --> CS
  CP --- REDIS
  SUP --- RESULTS
  CS --- REV
  SUP -->|"fetch frozen revision<br/>(read-only or writable copy)"| CS
  SUP -->|"mount workload view at<br/>/workspace/.moca-context/runs/&lt;sid&gt;"| POD0
  SUP --> POD1

  classDef denied stroke-dasharray: 4 3,color:#b00,stroke:#b00
```

Key: dashed red = deliberately blocked by `.claude/settings.json`
(`Task` tool, and reading mocactl's token dir).

## Dispatch / collect sequence (one leaf)

```mermaid
sequenceDiagram
  autonumber
  actor OP as Operator
  participant CC as Claude Code (parent)
  participant MC as mocactl
  participant W as detached worker
  participant SV as MOCA supervisor
  participant CS as Context Service
  participant SB as sandbox pod
  participant FS as scratch leaves dir

  OP->>CC: "Dispatch a subagent to diagnose…"
  CC->>FS: write leaves/LABEL.prompt.txt
  CC->>FS: contextctl ctx pack . -> leaves/LABEL.context
  CC->>MC: mocactl workloads create --context leaves/LABEL.context --json
  MC->>CS: upload bundle
  MC-->>CC: workloadId WLID
  CC->>MC: mocactl spawn --kind prompt --workload WLID [--writable] --tag TAG --json
  Note over CC,MC: permission prompt = operator's visual confirmation
  MC->>SV: create session
  SV-->>MC: sessionId
  MC->>W: fork (detached)
  MC-->>CC: stdout — type=session, sessionId, pid
  CC->>FS: write leaves/LABEL.json (label, sessionId, workloadId)
  W->>SV: POST /v1/runs (synchronous, no disconnect-abort)
  CC-->>OP: dispatched, sessionId=… then STOPS (no polling)

  Note over SV,SB: leaf runs server-side — session pins to one pod on first turn
  SV->>CS: fetch frozen revision (lazy, cached per user+revision)
  CS-->>SV: bundle bytes (streamed, sha256-verified)
  SV->>SB: mount view at /workspace/.moca-context/runs/sid<br/>(read-only, or writable per-run copy)
  SV->>SB: leaf tool calls, cwd = that mount
  SB-->>SV: final message
  SV->>SV: persist result BEFORE responding (24h TTL)
  SV-->>W: 200 (worker may already be dead — irrelevant)

  Note over OP,CC: minutes or hours later — may be a brand-new Claude session
  OP->>CC: "Check on that subagent."
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
   deleted after collection. The writable copy is per-run and discarded
   on completion — nothing persists across runs (that is phase-2
   workloads, https://github.com/rossoctl/moca/issues/476). No file
   paths cross the leaf boundary.
```

Isolation is substrate-enforced at the session level (each session
gets its own view, and each writable run gets its own per-run copy),
so leaves *could* fan out concurrently; this demo deliberately stays
a sequential chain.

## Trust and durability boundaries

| Boundary | What it guarantees | What it does not |
| --- | --- | --- |
| `Task` denied + `moca-delegate-task` skill | Subagent work cannot run in-process on the laptop | — |
| `mocactl` owns auth (`~/.config/mocactl`, Read-denied) | Demo stores no secret; no token plumbing | — |
| Workload mount read-only (diagnose leaf) | The diagnose leaf cannot alter the shared revision | — |
| Writable per-run copy (fix leaf) | Edits are isolated to that run and discarded on completion | **Not durable** — nothing survives to the next run; that is [rossoctl/moca#476](https://github.com/rossoctl/moca/issues/476) |
| Server persists result before responding to `/v1/runs` | Quit Claude, close the laptop, reboot — result survives | Nothing: there is **no cancel** |
| Server-side result store | Collectable for **24h** | Past 24h, or after `teardown.sh`, it's gone |
| Context Service frozen revision | Sha256-pinned, immutable upload; later uploads to the same workload are rejected | — |
| Shared sandbox pool | Workloads and sandbox caches are per user | **Not a security boundary** between users — tasks share the sandbox as the same Linux user. Per-workload sandboxes are [rossoctl/moca#476](https://github.com/rossoctl/moca/issues/476) |
| NetworkPolicy between `moca-sandbox` and everything else | Sandbox network isolation | Requires a NetworkPolicy-enforcing CNI (kind ≥ 0.24.0) |
