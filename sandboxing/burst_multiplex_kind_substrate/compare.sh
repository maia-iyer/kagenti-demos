#!/usr/bin/env bash
# Run all four (TEMPLATE_MODE × LOAD_MODE) combinations back-to-back and print
# a comparison table to stdout. Times each run and captures load.sh's own
# status-code tally and latency percentiles.
#
# Cleanup is idempotent and runs on normal exit, Ctrl+C, or any error, so a
# stuck run won't leave the cluster in the pinned/patched state.
#
# Env overrides (all optional):
#   NUM_ACTORS       (default 300)   pre-spawned actor pool for reuse runs
#   POOL_REPLICAS    (default 3)     worker pods
#   CONCURRENCY      (default 300)   for reuse runs
#   REUSE_REQUESTS   (default = NUM_ACTORS)
#   CREATE_REQUESTS  (default 60)    create runs are heavier — fewer requests
#   CREATE_CONCURRENCY (default 60)
#   BUDGET           (default 2m)    parking budget applied via crank.sh
#   READY_TIMEOUT      (default 120)  seconds to wait for the crank-rolled router
#                                       pod to report ready via /statusz before
#                                       starting the measured load.
#   READY_STABLE_POLLS (default 3)    consecutive good /statusz polls required
#                                       before declaring the router ready. Guards
#                                       against a brief window where the new pod
#                                       reports LIVE but xDS routes are still
#                                       propagating.
#   SHAKEOUT_REQUESTS  (default 5)    for reuse runs only: small sequential data-
#                                       path probe fired after /statusz says
#                                       ready. If any come back 5xx we re-wait
#                                       for readiness. Set to 0 to disable.
#   SHAKEOUT_RETRIES   (default 2)    max readiness+shakeout retries per run.
#   SKIP             comma list of runs to skip, e.g. SKIP=fast-create,durable-create
#   RESULTS_DIR      (default ./compare-results-<timestamp>)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

NUM_ACTORS="${NUM_ACTORS:-300}"
POOL_REPLICAS="${POOL_REPLICAS:-3}"
CONCURRENCY="${CONCURRENCY:-300}"
REUSE_REQUESTS="${REUSE_REQUESTS:-${NUM_ACTORS}}"
CREATE_REQUESTS="${CREATE_REQUESTS:-300}"
CREATE_CONCURRENCY="${CREATE_CONCURRENCY:-300}"
BUDGET="${BUDGET:-5m}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
READY_STABLE_POLLS="${READY_STABLE_POLLS:-3}"
SHAKEOUT_REQUESTS="${SHAKEOUT_REQUESTS:-5}"
SHAKEOUT_RETRIES="${SHAKEOUT_RETRIES:-2}"
STATUS_URL="${STATUS_URL:-http://localhost:4041/statusz?format=json}"
DATA_URL="${DATA_URL:-http://localhost:8000}"
ATESPACE="${ATESPACE:-burst}"
SKIP="${SKIP:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="${RESULTS_DIR:-${HERE}/compare-results-${STAMP}}"

mkdir -p "${RESULTS_DIR}"

PF_DATA_PID=""
PF_STATUS_PID=""
CLEANUP_DONE=0

log() { printf '\n\033[1;34m[compare]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[compare]\033[0m %s\n' "$*" >&2; }

# ---------- cleanup ---------------------------------------------------------
cleanup() {
  local ec=$?
  if [[ "${CLEANUP_DONE}" == "1" ]]; then
    exit "${ec}"
  fi
  CLEANUP_DONE=1

  log "Cleanup (ec=${ec})..."

  # Kill port-forwards first so teardown's kubectl calls don't share the
  # broken forwards, and so Ctrl+C doesn't leave orphan kubectl processes.
  for pid in "${PF_DATA_PID}" "${PF_STATUS_PID}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  # Belt-and-suspenders: any stray port-forward for this router.
  pkill -f 'kubectl port-forward -n ate-system svc/atenet-router' 2>/dev/null || true

  # Best-effort teardown of demo-owned state. Don't abort if it fails — we're
  # already exiting. Suppress `set -e` for this block.
  set +e
  NUM_ACTORS="${NUM_ACTORS}" ./teardown.sh
  set -e

  exit "${ec}"
}
trap cleanup EXIT INT TERM

# ---------- port-forwards ---------------------------------------------------
start_port_forwards() {
  log "Starting port-forwards (data :8000, status :4041)..."
  # Kill anything already bound to these ports from a previous run.
  pkill -f 'kubectl port-forward -n ate-system svc/atenet-router' 2>/dev/null || true
  sleep 1

  kubectl port-forward -n ate-system svc/atenet-router 8000:80 \
    >"${RESULTS_DIR}/pf-data.log" 2>&1 &
  PF_DATA_PID=$!
  kubectl port-forward -n ate-system svc/atenet-router 4041:4040 \
    >"${RESULTS_DIR}/pf-status.log" 2>&1 &
  PF_STATUS_PID=$!

  # Wait for both to accept connections.
  for _ in $(seq 1 30); do
    if curl -sf -o /dev/null -m 1 "http://localhost:4041/statusz?format=json" \
       && curl -s -o /dev/null -m 1 "http://localhost:8000" ; then
      log "Port-forwards ready."
      return 0
    fi
    sleep 1
  done
  warn "Port-forwards did not become ready within 30s. Continuing anyway."
}

# ---------- readiness gate --------------------------------------------------
# Poll /statusz until the crank-patched router pod has taken over and reports
# healthy across the three components, has our template registered, and stays
# that way for READY_STABLE_POLLS consecutive polls. Returns 0 on ready, 1 on
# timeout.
#
# The parking-budget check is the strongest signal: after crank.sh patches the
# deployment, the OLD pod is still draining and will keep answering /statusz
# with the previous budget until it exits. Requiring the reported budget to
# match ${BUDGET} guarantees we're talking to the NEW pod.
wait_router_ready() {
  local template_ns="$1" template_name="$2" logfile="$3"
  local deadline=$(( $(date +%s) + READY_TIMEOUT ))
  local stable=0
  local last_reason="(none)"

  printf -- '--- readiness attempt starting at %s (want budget=%s, template=%s/%s) ---\n' \
    "$(date +%H:%M:%S)" "${BUDGET}" "${template_ns}" "${template_name}" >>"${logfile}"

  while (( $(date +%s) < deadline )); do
    local body
    if ! body=$(curl -sf -m 2 "${STATUS_URL}" 2>/dev/null); then
      last_reason="statusz unreachable"
      stable=0
      printf '%s  %s\n' "$(date +%H:%M:%S)" "${last_reason}" >>"${logfile}"
      sleep 1
      continue
    fi

    local reason
    reason=$(printf '%s' "${body}" | jq -r --arg budget "${BUDGET}" \
                                        --arg tns "${template_ns}" \
                                        --arg tn  "${template_name}" '
      # Parse Go-style durations ("5m", "5m0s", "30s", "1h30m") to seconds.
      # The router normalizes flag values via time.Duration.String(), so
      # "5m" round-trips to "5m0s" — string equality would spuriously fail.
      def to_secs:
        . as $s
        | [ $s | scan("[0-9.]+[hms]") ]
        | if length == 0 then null
          else
            map(
              (.[:-1] | tonumber) *
              (if endswith("h") then 3600
               elif endswith("m") then 60
               else 1 end)
            ) | add
          end;

      (.flags."parked-request-budget" // "") as $got
      | ($got | to_secs) as $got_s
      | ($budget | to_secs) as $want_s
      | if (.health.dataplane.healthy // false) != true then "dataplane not healthy: \(.health.dataplane.message // "?")"
        elif (.health.dataplane.message // "") != "LIVE" then "dataplane not LIVE: \(.health.dataplane.message // "?")"
        elif (.health.k8s_api.healthy // false) != true then "k8s_api not healthy"
        elif (.health.ate_api.healthy // false) != true then "ate_api not healthy"
        elif $got_s == null or $want_s == null or $got_s != $want_s then "budget mismatch: got \($got) want \($budget) (old pod?)"
        elif ([.templates[]? | select(.name == $tn and .namespace == $tns)] | length) == 0 then "template \($tns)/\($tn) not registered"
        else "OK"
        end
    ' 2>/dev/null || printf '%s' "jq parse failed")

    if [[ "${reason}" == "OK" ]]; then
      stable=$(( stable + 1 ))
      printf '%s  OK (stable=%d/%d)\n' "$(date +%H:%M:%S)" "${stable}" "${READY_STABLE_POLLS}" >>"${logfile}"
      if (( stable >= READY_STABLE_POLLS )); then
        return 0
      fi
    else
      last_reason="${reason}"
      stable=0
      printf '%s  %s\n' "$(date +%H:%M:%S)" "${last_reason}" >>"${logfile}"
    fi
    sleep 1
  done

  warn "router did not reach ready state within ${READY_TIMEOUT}s (last: ${last_reason})"
  return 1
}

# Data-path shakeout for reuse runs: after /statusz says ready, send a few
# low-concurrency requests through the real ingress path. If any come back
# 5xx, that means xDS route bindings weren't fully installed by the time the
# health probe went green — retry the readiness gate. For create runs this
# is skipped: per-request actor-create latency already staggers arrivals.
router_shakeout() {
  local n="$1" logfile="$2"
  local ok=0 bad=0 codes=""

  printf -- '--- shakeout starting at %s (n=%d) ---\n' \
    "$(date +%H:%M:%S)" "${n}" >>"${logfile}"
  local i actor host code
  for i in $(seq 1 "${n}"); do
    # Pick a random pre-spawned actor from the burst pool. Zero-padded to 3.
    actor=$(printf 'b%03d' $(( RANDOM % NUM_ACTORS )))
    host="${actor}.${ATESPACE}.actors.resources.substrate.ate.dev"
    code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" \
             -H "Host: ${host}" "${DATA_URL}")
    codes+="${code} "
    if [[ "${code}" == "200" ]]; then
      ok=$(( ok + 1 ))
    else
      bad=$(( bad + 1 ))
    fi
    printf '%s %s %s\n' "${host}" "${code}" "$(date +%H:%M:%S)" >>"${logfile}"
    # Suspend so the shakeout leaves the actor in the same "parked-ready"
    # shape the measured reuse run expects.
    kubectl ate suspend actor "${actor}" --atespace "${ATESPACE}" >/dev/null 2>&1 || true
  done

  log "shakeout: ${ok}/${n} 200 (codes: ${codes% })"
  (( bad == 0 ))
}

# ---------- one run ---------------------------------------------------------
should_skip() {
  local key="$1"
  [[ ",${SKIP}," == *",${key},"* ]]
}

run_one() {
  local key="$1" template="$2" load="$3" requests="$4" concurrency="$5"
  local outfile="${RESULTS_DIR}/${key}.txt"
  local timefile="${RESULTS_DIR}/${key}.time"

  if should_skip "${key}"; then
    log "SKIP ${key}"
    return 0
  fi

  log "===== ${key} : TEMPLATE_MODE=${template} LOAD_MODE=${load} REQUESTS=${requests} CONCURRENCY=${concurrency} ====="

  # Fresh setup each run so template + actor pool are correct for the mode.
  log "setup..."
  TEMPLATE_MODE="${template}" NUM_ACTORS="${NUM_ACTORS}" POOL_REPLICAS="${POOL_REPLICAS}" \
    ./setup.sh 2>&1 | tee "${RESULTS_DIR}/${key}.setup.log" >/dev/null

  log "crank BUDGET=${BUDGET}..."
  BUDGET="${BUDGET}" ./crank.sh 2>&1 | tee "${RESULTS_DIR}/${key}.crank.log" >/dev/null

  # Router rollout tears down existing port-forwards.
  start_port_forwards

  # Readiness gate. Replaces the previous fixed-count warmup, which was too
  # weak for the fast-template rollout: /statusz-based polling waits until the
  # crank-patched router pod (identified by its parking-budget flag) is
  # actually the one answering and has the current ActorTemplate registered.
  # For reuse runs we additionally send a small sequential data-path shakeout
  # — the only signal that catches xDS route bindings still propagating after
  # /statusz has gone green. If the shakeout sees any 5xx, we re-arm the gate.
  local template_ns="ate-demo-autoscaled-workerpool"
  local template_name
  case "${template}" in
    fast)    template_name="counter-fast" ;;
    durable) template_name="counter" ;;
    *) warn "unknown template mode: ${template}"; template_name="counter" ;;
  esac

  local attempt=0
  while : ; do
    log "readiness gate (attempt $(( attempt + 1 ))/$(( SHAKEOUT_RETRIES + 1 )))..."
    if ! wait_router_ready "${template_ns}" "${template_name}" \
           "${RESULTS_DIR}/${key}.ready.log"; then
      warn "readiness gate timed out for ${key} (continuing; expect 5xx)"
      break
    fi

    if [[ "${load}" != "reuse" || "${SHAKEOUT_REQUESTS}" -le 0 ]]; then
      break
    fi

    log "shakeout: ${SHAKEOUT_REQUESTS} sequential probes..."
    if router_shakeout "${SHAKEOUT_REQUESTS}" \
         "${RESULTS_DIR}/${key}.shakeout.log"; then
      break
    fi

    attempt=$(( attempt + 1 ))
    if (( attempt > SHAKEOUT_RETRIES )); then
      warn "shakeout kept failing after ${SHAKEOUT_RETRIES} retries; running measured load anyway"
      break
    fi
    log "shakeout saw 5xx; re-arming readiness gate after brief pause..."
    sleep 3
  done

  log "load..."
  # `time` output goes to stderr; capture separately from load.sh's stdout.
  { time TEMPLATE_MODE="${template}" LOAD_MODE="${load}" NUM_ACTORS="${NUM_ACTORS}" \
      REQUESTS="${requests}" CONCURRENCY="${concurrency}" \
      ./load.sh ; } >"${outfile}" 2>"${timefile}"

  # load.sh appends `time`'s stderr to our timefile; separate for display.
  # Print the stats block back to the operator immediately.
  echo
  echo "----- ${key} results -----"
  cat "${outfile}"
  echo "----- ${key} wall time -----"
  # `time`'s output is 3 lines: real / user / sys.
  grep -E '^(real|user|sys)' "${timefile}" || cat "${timefile}"
  echo

  log "teardown between runs..."
  NUM_ACTORS="${NUM_ACTORS}" ./teardown.sh \
    >"${RESULTS_DIR}/${key}.teardown.log" 2>&1 || warn "teardown after ${key} returned non-zero"
}

# ---------- summary ---------------------------------------------------------
summarize() {
  log "===== SUMMARY ====="
  printf '%-16s | %-10s | %-8s | %-8s | %-8s | %-8s | %-8s\n' \
    "run" "wall" "p50" "p95" "p99" "max" "200s/total"
  printf -- '-%.0s' {1..90}; echo

  local key
  for key in fast-reuse fast-create durable-reuse durable-create; do
    local out="${RESULTS_DIR}/${key}.txt"
    local tf="${RESULTS_DIR}/${key}.time"
    if [[ ! -f "${out}" ]]; then
      printf '%-16s | %s\n' "${key}" "(skipped or not run)"
      continue
    fi
    local wall="?" p50="?" p95="?" p99="?" mx="?" ok="?" total="?"
    wall=$(awk '/^real/ {print $2}' "${tf}" 2>/dev/null | head -n1)
    wall="${wall:-?}"
    p50=$(awk '/^ *p50/ {print $2}' "${out}" | head -n1)
    p95=$(awk '/^ *p95/ {print $2}' "${out}" | head -n1)
    p99=$(awk '/^ *p99/ {print $2}' "${out}" | head -n1)
    mx=$(awk '/^ *max/ {print $2}' "${out}" | head -n1)
    ok=$(awk '/Status-code tally/{f=1;next} f && /^[[:space:]]*[0-9]+[[:space:]]+200/{print $1; exit}' "${out}")
    total=$(awk '/Status-code tally/{f=1;next} f && /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/{s+=$1} /^$/ && f{print s; exit} END{if(f && !NF)print s}' "${out}")
    printf '%-16s | %-10s | %-8s | %-8s | %-8s | %-8s | %s/%s\n' \
      "${key}" "${wall:-?}" "${p50:-?}" "${p95:-?}" "${p99:-?}" "${mx:-?}" \
      "${ok:-0}" "${total:-?}"
  done
  echo
  log "Full per-run output: ${RESULTS_DIR}"
}

# ---------- main ------------------------------------------------------------
log "results dir: ${RESULTS_DIR}"
log "settings: NUM_ACTORS=${NUM_ACTORS} POOL_REPLICAS=${POOL_REPLICAS} BUDGET=${BUDGET}"
log "reuse:  REQUESTS=${REUSE_REQUESTS}  CONCURRENCY=${CONCURRENCY}"
log "create: REQUESTS=${CREATE_REQUESTS} CONCURRENCY=${CREATE_CONCURRENCY}"

run_one fast-reuse      fast    reuse  "${REUSE_REQUESTS}"  "${CONCURRENCY}"
run_one fast-create     fast    create "${CREATE_REQUESTS}" "${CREATE_CONCURRENCY}"
run_one durable-reuse   durable reuse  "${REUSE_REQUESTS}"  "${CONCURRENCY}"
run_one durable-create  durable create "${CREATE_REQUESTS}" "${CREATE_CONCURRENCY}"

summarize

# Trap will handle final cleanup.
