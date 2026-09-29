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
    p50=$(awk '/p50/ {print $2}' "${out}" | head -n1)
    p95=$(awk '/p95/ {print $2}' "${out}" | head -n1)
    p99=$(awk '/p99/ {print $2}' "${out}" | head -n1)
    mx=$(awk '/^ *max/  {print $2}' "${out}" | head -n1)
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
