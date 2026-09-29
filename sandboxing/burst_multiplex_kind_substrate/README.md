# Burst multiplex: 300 actors, 3 workers, one burst

Spawn 300
[Agent Substrate](https://github.com/agent-substrate/substrate) actors on a
worker pool pinned to 3 pods, then fire a burst of concurrent HTTP requests
through the atenet router. Two substrate mechanisms fire at once and are both
visible in the output:

- **Actor multiplexing.** 300 actors share 3 worker pods. After each request
  `load.sh` calls `kubectl ate suspend` on the actor it just hit, freeing
  that worker for the next actor waiting in line. (Substrate does not yet
  auto-suspend idle actors — the upstream parking demo uses this same
  request→suspend pattern to stand in for that.) `kubectl ate get workers`
  shows the 3 workers churning between `FREE` and `ASSIGNED`, not 300 workers
  standing up.
- **Request parking.** When more actors need to run than there are workers
  free, the atenet router *holds* inbound requests for up to
  `--parked-request-budget` (default 5s) while substrate resumes actors,
  instead of returning `503`. Under the burst, `parking.active` spikes to
  double digits and drains after.

## Prerequisites

A kind cluster with Substrate installed *and* the upstream
`autoscaled-workerpool` demo deployed. These are one-time setup for local
Substrate work and are not part of this demo.

From your `substrate/` checkout:

```bash
# 1. Kind cluster + local registry.
./hack/create-kind-cluster.sh

# 2. Substrate itself.
./hack/install-ate-kind.sh --deploy-ate-system

# 3. Autoscaled-workerpool demo — deploys the `counter` WorkerPool,
#    ActorTemplate, HPA, and prometheus-adapter that this demo pins and
#    drives load against.
./hack/install-ate-kind.sh --deploy-demo-autoscaled-workerpool
```

You also need:

- Go 1.22+
- `kubectl` and the `kubectl-ate` plugin (`go install ./cmd/kubectl-ate`
  from `substrate/`)
- `curl`, `xargs`, `jq` — standard on most systems

No Anthropic API key, no Docker registry, no cloud storage bucket. The
underlying kind install uses an in-cluster `rustfs` (S3-compatible) for
actor snapshots.

## Architecture

```
                                          burst atespace
  ./load.sh                             ┌─ b001 ─┐
     │  300 concurrent                  │  ...   │ 300 actors
     │  curl requests +                 │        │  (counter-fast or counter)
     │  kubectl ate suspend             └─ b300 ─┘
     ▼                                      │
  localhost:8000                            │ assigns / suspends / resumes
     │ (port-forward)                       ▼
     ▼                          counter WorkerPool (pinned to 3 replicas)
  atenet-router  ─────────►          │
     │  parks bursts up to                  ▼
     │  --parked-request-budget          rustfs (in-cluster S3, snapshots)
     ▼   (5s default, 5m via ./crank.sh)
  /statusz?format=json → live parking gauge on :4040
```

## Setup

From this directory:

```bash
./setup.sh
```

This pins the `counter` HPA to `min=max=POOL_REPLICAS` (default 3), scales the
`counter` workerpool to match, applies a stripped `counter-fast` ActorTemplate
(cheap suspend/resume — see [template mode](#template-mode--load-mode) below),
creates the `burst` atespace, and spawns `NUM_ACTORS` (default 300) actors in
parallel. Takes ~30–60s.

Then, in two separate terminals, start the port-forwards:

```bash
# Terminal A — data plane (curl target for ./load.sh)
kubectl port-forward -n ate-system svc/atenet-router 8000:80

# Terminal B — status port (parking gauge for ./watch.sh)
kubectl port-forward -n ate-system svc/atenet-router 4041:4040
```

The rest of the demo has two shapes: **[Mode A](#mode-a-drive-one-burst-manually)**
runs one burst so you can watch it live, and
**[Mode B](#mode-b-compare-all-four-runs)** sweeps the full 2×2 and prints a
table.

## Mode A: drive one burst manually

```bash
./watch.sh   # prints two paste-ready `watch` commands (worker states + parking)
./load.sh    # fires the burst
```

`load.sh` defaults to `REQUESTS=NUM_ACTORS` (one per actor, on average) at
concurrency 300. In `fast` mode it finishes in a few seconds; in `durable`
mode it takes minutes.

The router defaults to a 5s parking budget, which a slow laptop can outrun
under the durable/create combo. `./crank.sh` bumps it to 5m for a clean run;
`./teardown.sh` strips the patch back out.

```bash
./crank.sh              # BUDGET=5m (default)
BUDGET=30s ./crank.sh   # tighter — expect some 503s
```

### Template mode × load mode

Pick one of each. Template mode is set at `setup.sh`; load mode at `load.sh`.

- `TEMPLATE_MODE=fast` (default) — minimal `snapshotsConfig` (no durable
  volume, no readyz). Cheap suspend/resume, clean multiplex demo.
- `TEMPLATE_MODE=durable` — reuses the upstream `counter` template: full
  memory snapshot on suspend, durable-volume commit per request. Suspend/resume
  takes ~1s+; the burst looks *ugly* (p50 seconds, p99 tens of seconds).
  That's the price of durable state.
- `LOAD_MODE=reuse` (default) — sample a pre-spawned actor, hit it, then
  `kubectl ate suspend` to free its worker. Exercises **resume + parking**.
- `LOAD_MODE=create` — create → hit → delete on every request. Exercises
  **actor-create + golden-snapshot materialization + cold start**. Much
  heavier; pair with a low `REQUESTS` on a laptop.

```bash
TEMPLATE_MODE=durable ./setup.sh
LOAD_MODE=create REQUESTS=30 ./load.sh
```

### Configuration

| Var                 | Default     | Where it matters              |
| ------------------- | ----------- | ----------------------------- |
| `ATESPACE`          | `burst`     | setup, load, watch, teardown  |
| `NUM_ACTORS`        | `300`       | setup, load, teardown         |
| `POOL_REPLICAS`     | `3`         | setup                         |
| `CONCURRENCY`       | `300`       | load                          |
| `TEMPLATE_MODE`     | `fast`      | setup + load (`fast`/`durable`) |
| `LOAD_MODE`         | `reuse`     | load (`reuse` or `create`)    |
| `REQUESTS`          | `${NUM_ACTORS}` | load                      |
| `ENDPOINT`          | `http://localhost:8000` | load              |
| `CREATE_PARALLELISM`| `20`        | setup                         |
| `BUDGET`            | `5m`        | crank                         |

Smoke test on a slow laptop:

```bash
NUM_ACTORS=50 POOL_REPLICAS=2 ./setup.sh
CONCURRENCY=20 REQUESTS=500 NUM_ACTORS=50 ./load.sh
```

## Mode B: compare all four runs

`compare.sh` runs the full 2×2 — `TEMPLATE_MODE ∈ {fast, durable}` ×
`LOAD_MODE ∈ {reuse, create}` — back-to-back, times each run, and prints
per-run stats plus a summary table. It handles its own port-forwards and
runs `teardown.sh` on exit, Ctrl+C, or error, so a stuck run won't leave the
cluster with pinned HPA bounds or the crank patch attached.

```bash
./compare.sh
```

What it does, for each of the four combinations:

1. `TEMPLATE_MODE=<mode> ./setup.sh` — spawns actors from the right template.
2. `BUDGET=<budget> ./crank.sh` — bumps the parking budget so measurements
   reflect parking cost rather than truncation by the 5s default.
3. Starts port-forwards on `:8000` (data) and `:4041` (status), waits for
   them to accept connections.
4. Runs `load.sh` under `time`, captures the status-code tally and latency
   percentiles.
5. `./teardown.sh` between runs, so the next template is applied cleanly.

At the end you get a table like:

```
run              | wall       | p50      | p95      | p99      | max      | 200s/total
------------------------------------------------------------------------------------------
fast-reuse       | 0m8.4s     | 0.09s    | 0.71s    | 1.20s    | 1.32s    | 300/300
fast-create      | 1m12s      | 2.10s    | 6.80s    | 9.50s    | 11.4s    | 60/60
durable-reuse    | 2m41s      | 1.05s    | 24.10s   | 58.20s   | 92.4s    | 300/300
durable-create   | 3m30s      | 6.20s    | 44.80s   | 78.10s   | 108s     | 60/60
```

(Numbers are illustrative — laptop-dependent.)

### Configuration

All defaults are safe for a laptop-scale run; override any env var:

| Var                  | Default        | Purpose                              |
| -------------------- | -------------- | ------------------------------------ |
| `NUM_ACTORS`         | `300`          | Pre-spawned actor pool (reuse runs)  |
| `POOL_REPLICAS`      | `3`            | Worker pods pinned by `setup.sh`     |
| `CONCURRENCY`        | `300`          | Concurrency for reuse runs           |
| `REUSE_REQUESTS`     | `${NUM_ACTORS}`| Requests fired in reuse runs         |
| `CREATE_REQUESTS`    | `300`          | Requests fired in create runs        |
| `CREATE_CONCURRENCY` | `300`          | Concurrency for create runs          |
| `BUDGET`             | `5m`           | `--parked-request-budget` via `crank.sh` |
| `SKIP`               | *(empty)*      | Comma list, e.g. `SKIP=durable-create` |
| `RESULTS_DIR`        | `./compare-results-<ts>` | Where per-run logs land      |

Examples:

```bash
# Skip the slowest run:
SKIP=durable-create ./compare.sh

# Lighter run for a slower machine (the default 300/300 create burst can
# swamp kubectl/API-server on a laptop):
NUM_ACTORS=100 CREATE_REQUESTS=60 CREATE_CONCURRENCY=60 ./compare.sh

# Tighter budget — expect some 503s in the durable runs:
BUDGET=30s ./compare.sh
```

### Reading the 2×2

The four runs isolate two independent axes of substrate cost:

|              | reuse (resume path)                | create (full lifecycle)              |
| ------------ | ---------------------------------- | ------------------------------------ |
| **fast**     | Baseline: resume + parking         | + actor-create + golden snapshot + cold start |
| **durable**  | + full-memory snapshot + volume commit | Both durability tax and lifecycle tax stacked |

Useful deltas:

- **`fast-create` − `fast-reuse`** ≈ actor-lifecycle cost (create + cold
  start + delete), independent of durable state.
- **`durable-reuse` − `fast-reuse`** ≈ durability tax on the resume path
  (full-memory snapshot + durable-volume commit per request).
- **`durable-create` − `durable-reuse`** ≈ lifecycle cost with the durable
  template — usually superlinear vs. the fast version because the parking
  queue fills.

### Cleanup

`compare.sh` traps `EXIT`, `INT`, and `TERM`. Cleanup runs exactly once and:

1. Kills the port-forwards it started, then `pkill`s any orphaned
   `kubectl port-forward` for the atenet-router (that's the state Ctrl+C
   tends to leave behind mid-run).
2. Runs `./teardown.sh` best-effort — deletes actors, restores HPA bounds,
   removes the crank patch, deletes the fast template.

Ctrl+C is safe. If cleanup itself fails (e.g. cluster unreachable), the
error surfaces but the trap does not re-fire.

## Teardown

Two modes, controlled by `FULL_TEARDOWN`:

```bash
./teardown.sh                    # default: demo-specific state only
FULL_TEARDOWN=1 ./teardown.sh    # also delete atespace + autoscaled-workerpool
```

**Default (`FULL_TEARDOWN=0`)** — removes the 300 `b*` actors and any
`req-*` actors left behind by a Ctrl+C'd create run, restores the HPA to
its upstream bounds (min=1, max=10), deletes the `counter-fast`
ActorTemplate, and strips any `crank.sh` patch off the router deployment.
Leaves the `burst` atespace and the `autoscaled-workerpool` namespace in
place because other demos may share them.

**Full (`FULL_TEARDOWN=1`)** — does everything above, then also deletes the
`burst` atespace and the `autoscaled-workerpool` namespace (HPA, workerpool,
templates, prometheus-adapter bits). Leaves you with a clean Substrate
install (`ate-system` untouched) on the kind cluster. Use this when this
demo owns the whole substrate setup.

To reset Substrate itself as well, from your `substrate/` checkout:

```bash
./hack/install-ate-kind.sh --delete-ate-system
```

To delete the kind cluster entirely (nukes everything — cluster, registry,
all state):

```bash
kind delete cluster
```
