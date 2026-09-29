#!/usr/bin/env bash
# Burst load driver.
#
# Fires REQUESTS concurrent HTTP requests (CONCURRENCY at a time) through the
# port-forwarded atenet-router. Two load modes:
#
#   LOAD_MODE=reuse  (default) — sample one of NUM_ACTORS pre-spawned actors,
#     hit it, then `kubectl ate suspend` to free the worker for a parked
#     competitor. Exercises resume + parking. Fast in fast-template mode.
#
#   LOAD_MODE=create — create a brand-new actor, hit it once, delete it.
#     Exercises actor-create + golden-snapshot materialization + first-run
#     cold start on every request. Much slower and stresses a different path.
#
# Prints per-status tally, latency percentiles, and per-actor request counts.

set -euo pipefail

ATESPACE="${ATESPACE:-burst}"
NUM_ACTORS="${NUM_ACTORS:-300}"
CONCURRENCY="${CONCURRENCY:-300}"
REQUESTS="${REQUESTS:-${NUM_ACTORS}}"
ENDPOINT="${ENDPOINT:-http://localhost:8000}"
LOAD_MODE="${LOAD_MODE:-reuse}"

# TEMPLATE_MODE must match what setup.sh applied; used only by LOAD_MODE=create
# to know which ActorTemplate to instantiate.
TEMPLATE_MODE="${TEMPLATE_MODE:-fast}"
POOL_NS="ate-demo-autoscaled-workerpool"
case "${TEMPLATE_MODE}" in
  durable) TEMPLATE="${POOL_NS}/counter" ;;
  fast)    TEMPLATE="${POOL_NS}/counter-fast" ;;
  *) echo "TEMPLATE_MODE must be 'fast' or 'durable' (got: ${TEMPLATE_MODE})" >&2; exit 2 ;;
esac

HOSTS_FILE="$(mktemp)"
TALLY="$(mktemp)"
trap 'rm -f "${HOSTS_FILE}" "${TALLY}"' EXIT

for i in $(seq -w 1 "${NUM_ACTORS}"); do
  echo "b${i}"
done > "${HOSTS_FILE}"

echo "==> Firing ${REQUESTS} requests at ${ENDPOINT}"
echo "    load mode: ${LOAD_MODE}"
if [[ "${LOAD_MODE}" == "reuse" ]]; then
  echo "    across ${NUM_ACTORS} pre-spawned actors in atespace ${ATESPACE}"
else
  echo "    creating a new actor per request from template ${TEMPLATE}"
fi
echo "    with concurrency ${CONCURRENCY}..."
echo ""

case "${LOAD_MODE}" in
  reuse)
    # Positional args ($1..$4) sidestep the bash-array-across-bash-c scoping trap.
    # `sort -R` is available on both macOS and Linux. Each iteration: hit the
    # actor, then suspend it so its worker frees up for a parked request.
    seq 1 "${REQUESTS}" | xargs -n1 -P"${CONCURRENCY}" -I{} bash -c '
      actor=$(sort -R "$1" | head -n1)
      host="${actor}.$4.actors.resources.substrate.ate.dev"
      read code t < <(curl -s -o /dev/null -w "%{http_code} %{time_total}\n" \
                      -H "Host: $host" "$2")
      printf "%s %s %s\n" "$host" "$code" "$t" >> "$3"
      kubectl ate suspend actor "$actor" --atespace "$4" >/dev/null 2>&1 || true
    ' _ "${HOSTS_FILE}" "${ENDPOINT}" "${TALLY}" "${ATESPACE}"
    ;;

  create)
    # Per-request: create a uniquely-named actor from the template, hit it
    # once, delete it. The %{time_total} number here includes actor-create
    # round-trip + golden-snapshot materialization + first-run boot, which is
    # a different (much heavier) code path than the reuse mode above.
    seq 1 "${REQUESTS}" | xargs -n1 -P"${CONCURRENCY}" -I{} bash -c '
      i="$5"
      name="req-$(date +%s%N | tail -c 10)-${i}"
      kubectl ate create actor "$name" -a "$4" --template "$1" >/dev/null 2>&1 || {
        printf "%s %s %s\n" "$name" "CREATEFAIL" "0" >> "$3"; exit 0; }
      host="${name}.$4.actors.resources.substrate.ate.dev"
      read code t < <(curl -s -o /dev/null -w "%{http_code} %{time_total}\n" \
                      -H "Host: $host" "$2")
      printf "%s %s %s\n" "$host" "$code" "$t" >> "$3"
      # Suspend before delete: delete without a prior suspend can leave the
      # worker binding assigned, which stalls subsequent parked requests.
      kubectl ate suspend actor "$name" --atespace "$4" >/dev/null 2>&1 || true
      kubectl ate delete actor "$name" -a "$4" >/dev/null 2>&1 || true
    ' _ "${TEMPLATE}" "${ENDPOINT}" "${TALLY}" "${ATESPACE}" {}
    ;;

  *)
    echo "LOAD_MODE must be 'reuse' or 'create' (got: ${LOAD_MODE})" >&2
    exit 2
    ;;
esac

echo "==> Status-code tally (expect near-100% 200 under parking):"
awk '{print $2}' "${TALLY}" | sort | uniq -c | sort -rn
echo ""

echo "==> 200-response latency percentiles (parked requests show in p95+):"
awk '$2==200 {print $3}' "${TALLY}" | sort -n | awk '
  { a[NR-1]=$1 }
  END {
    c=NR
    if (c==0) { print "  (no 200s)"; exit }
    printf "    p50  %ss\n", a[int(c*0.50)]
    printf "    p95  %ss\n", a[int(c*0.95)]
    printf "    p99  %ss\n", a[int(c*0.99)]
    printf "    max  %ss\n", a[c-1]
  }
'
echo ""

TOTAL_HOSTS=$(awk '{print $1}' "${TALLY}" | sort -u | wc -l | tr -d ' ')
echo "==> Distributed across ${TOTAL_HOSTS} of ${NUM_ACTORS} actor hostnames."
echo "    Top 20 by request count:"
awk '{print $1}' "${TALLY}" | sort | uniq -c | sort -rn | head -20
