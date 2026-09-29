#!/usr/bin/env bash
# Burst load driver.
#
# Fires REQUESTS concurrent HTTP requests (CONCURRENCY at a time) uniformly
# distributed across NUM_ACTORS actor hostnames, through the port-forwarded
# atenet-router. Prints per-status tally, latency percentiles, and per-actor
# request counts so multiplexing (actors share workers) and parking (requests
# wait during the resume gap) are both visible in the output.

set -euo pipefail

ATESPACE="${ATESPACE:-burst}"
NUM_ACTORS="${NUM_ACTORS:-300}"
CONCURRENCY="${CONCURRENCY:-50}"
REQUESTS="${REQUESTS:-3000}"
ENDPOINT="${ENDPOINT:-http://localhost:8000}"

HOSTS_FILE="$(mktemp)"
TALLY="$(mktemp)"
trap 'rm -f "${HOSTS_FILE}" "${TALLY}"' EXIT

for i in $(seq -w 1 "${NUM_ACTORS}"); do
  echo "b${i}.${ATESPACE}.actors.resources.substrate.ate.dev"
done > "${HOSTS_FILE}"

echo "==> Firing ${REQUESTS} requests at ${ENDPOINT}"
echo "    across ${NUM_ACTORS} actors in atespace ${ATESPACE}"
echo "    with concurrency ${CONCURRENCY}..."
echo ""

# Positional args ($1/$2/$3) sidestep the bash-array-across-bash-c scoping trap.
# `sort -R` is available on both macOS and Linux.
seq 1 "${REQUESTS}" | xargs -n1 -P"${CONCURRENCY}" -I{} bash -c '
  h=$(sort -R "$1" | head -n1)
  read code t < <(curl -s -o /dev/null -w "%{http_code} %{time_total}\n" \
                  -H "Host: $h" "$2")
  printf "%s %s %s\n" "$h" "$code" "$t" >> "$3"
' _ "${HOSTS_FILE}" "${ENDPOINT}" "${TALLY}"

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
