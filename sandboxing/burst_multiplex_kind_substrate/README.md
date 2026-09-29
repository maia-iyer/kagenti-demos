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
  request→suspend pattern to stand in for that.) The `assigned` worker
  gauge stays near 3, not 300.
- **Request parking.** When more actors need to run than there are workers
  free, the atenet router *holds* inbound requests for up to
  `--parked-request-budget` (default 5s) while substrate resumes actors,
  instead of returning `503`. Under the burst, `parking.active` spikes to
  double digits and drains after.

## What you'll see

- Status-code tally is near-100% `200`, with rare or zero `503`.
- Response-latency `p95` is well above `p50` — the tail is parked requests.
- `assigned` workers stays near `POOL_REPLICAS` (default 3) for the whole run,
  even though 300 actors are registered.
- `kubectl ate get actors -a burst` shows actors cycling between `Running`
  and `Suspended` as the load driver rotates through them.

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
     │  50 concurrent                   │  ...   │ 300 actors
     │  curl requests +                 │        │  (counter template)
     │  kubectl ate suspend             └─ b300 ─┘
     ▼                                      │
  localhost:8000                            │ assigns / suspends / resumes
     │ (port-forward)                       ▼
     ▼                          counter WorkerPool (pinned to 3 replicas)
  atenet-router  ─────────►          │
     │  parks bursts up to                  ▼
     │  --parked-request-budget=5s      rustfs (in-cluster S3, snapshots)
     ▼
  /statusz?format=json → live parking gauge on :4040
```

## Setup

From this directory:

```bash
./setup.sh
```

This pins the `counter` HPA to `min=max=POOL_REPLICAS` (default 3), scales the
`counter` workerpool to match, applies a stripped `counter-fast` ActorTemplate
(cheap suspend/resume — see below), creates the `burst` atespace, and spawns
`NUM_ACTORS` (default 300) actors in parallel. Takes ~30–60s.

### Template mode

`TEMPLATE_MODE` (default `fast`) picks which ActorTemplate the actors use:

- `fast` — minimal `snapshotsConfig` (no durable volume, no readyz, no
  `onPause: Full` / `onCommit: Data`). Suspend/resume is cheap, so a burst
  rotates 300 actors across 3 workers in seconds. Best for showing off the
  multiplex + parking story cleanly.
- `durable` — reuses the upstream `autoscaled-workerpool/counter` template
  as-is: full memory snapshot on suspend, durable volume committed on every
  request. Suspend/resume is much slower (one round-trip ≈ 1s+), so a burst
  looks *ugly*: `p50` seconds, `p99` tens of seconds, some `503`s past the
  parking budget. That's what the durable-state path costs — real workload,
  real snapshots. Useful for showing the price of durability.

```bash
TEMPLATE_MODE=durable ./setup.sh   # slow but honest
TEMPLATE_MODE=fast    ./setup.sh   # (default) clean multiplex demo
```

Then, in two separate terminals, start the port-forwards:

```bash
# Terminal A — data plane (curl target for ./load.sh)
kubectl port-forward -n ate-system svc/atenet-router 8000:80

# Terminal B — status port (parking gauge for ./watch.sh)
kubectl port-forward -n ate-system svc/atenet-router 4041:4040
```

## Run

```bash
# In three or four more terminals, paste the commands ./watch.sh prints:
./watch.sh

# Drive the burst:
./load.sh
```

`load.sh` defaults to 3000 requests at concurrency 300 — takes a minute or two
on a warm cluster in `fast` mode, much longer in `durable` mode. Each
iteration issues one HTTP request and then calls `kubectl ate suspend` on
that actor, so the worker rotates onto whichever actor the router next
resumes.

### Configuration

All scripts honor the same env vars, with sane defaults:

| Var                 | Default     | Where it matters              |
| ------------------- | ----------- | ----------------------------- |
| `ATESPACE`          | `burst`     | setup, load, watch, teardown  |
| `NUM_ACTORS`        | `300`       | setup, load, teardown         |
| `POOL_REPLICAS`     | `3`         | setup                         |
| `CONCURRENCY`       | `300`       | load                          |
| `TEMPLATE_MODE`     | `fast`      | setup (`fast` or `durable`)   |
| `REQUESTS`          | `3000`      | load                          |
| `ENDPOINT`          | `http://localhost:8000` | load              |
| `CREATE_PARALLELISM`| `20`        | setup                         |

Example: quick smoke test on a slow laptop —

```bash
NUM_ACTORS=50 POOL_REPLICAS=2 ./setup.sh
CONCURRENCY=20 REQUESTS=500 NUM_ACTORS=50 ./load.sh
```

### Cranking harder

At 300 actors on 3 workers with the default 5s parking budget, a slow laptop
may shed some requests (`503`) if the resume queue backs up beyond 5s. That's
still a valid demo — parking has a budget on purpose — but if you want a
clean 100% `200` run:

```bash
BUDGET=30s ./crank.sh
```

`crank.sh` patches the `atenet-router` deployment to raise
`--parked-request-budget`. `teardown.sh` strips the patch back out.

## Verification

Under load, multiplexing and parking are both real when:

```bash
# assigned-workers stays near POOL_REPLICAS, not NUM_ACTORS
kubectl get --raw \
  '/apis/external.metrics.k8s.io/v1beta1/namespaces/ate-demo-autoscaled-workerpool/ate_workerpool_workers?labelSelector=ate_worker_state%3Dassigned,ate_workerpool_namespace%3Date-demo-autoscaled-workerpool,ate_workerpool_name%3Dcounter' \
  | jq '.items[0].value'

# parking.active > 0 during the burst, 0 at rest
curl -s 'http://localhost:4041/statusz?format=json' | jq .parking.active

# pool held at POOL_REPLICAS
kubectl -n ate-demo-autoscaled-workerpool get workerpool counter

# load.sh output: near-100% 200s, p95 latency >> p50
```

## Teardown

```bash
./teardown.sh
```

Removes the 300 actors, restores the HPA to its upstream bounds (min=1,
max=10), and strips any `crank.sh` patch off the router deployment. Does not
delete the `burst` atespace or the upstream `autoscaled-workerpool` demo —
those may be shared. The teardown script prints the commands to remove them
if you want to.
