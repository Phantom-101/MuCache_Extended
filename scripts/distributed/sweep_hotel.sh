#!/bin/bash
# Throughput–latency sweep for hotel (distributed N0/N1/N2).
# Endpoint: /ro_search_hotels.
set -e
source "$(dirname "$0")/env.sh"

MODES=(${MODES:-nocm flame})
N_REQUESTS="${N_REQUESTS:-100000}"
CONCURRENCIES=(${CONCURRENCIES:-25 50 75 100 125 150 175 200})

OUTDIR="${OUTDIR:-$REPO_ROOT/results/hotel_distributed}"
mkdir -p "$OUTDIR"

FRONTEND_URL="http://$N1_PUBLIC_IP:4000"
USER_URL="http://$N1_PUBLIC_IP:4005"

SUMMARY="$OUTDIR/summary.csv"
echo "mode,concurrency,requests,p50_secs,p95_secs,p99_secs,rps,success_rate" > "$SUMMARY"

log "hotel sweep: modes=${MODES[*]}  c=${CONCURRENCIES[*]}  n=$N_REQUESTS  → $OUTDIR"

parse_and_append() {
    local mode="$1" c="$2" file="$3"
    local p50 p95 p99 rps succ
    local tmp; tmp=$(mktemp)
    sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[?[0-9]*[lh]//g' "$file" > "$tmp"
    p50=$(awk '/50\.00%/ {print $3; exit}' "$tmp")
    p95=$(awk '/95\.00%/ {print $3; exit}' "$tmp")
    p99=$(awk '/99\.00%/ {print $3; exit}' "$tmp")
    rps=$(awk '/Requests\/sec/ {print $2; exit}' "$tmp")
    succ=$(awk '/Success rate/ {print $3; exit}' "$tmp")
    rm -f "$tmp"
    echo "$mode,$c,$N_REQUESTS,$p50,$p95,$p99,$rps,$succ" >> "$SUMMARY"
    printf "    [%s c=%-3d] p50=%s  p95=%s  p99=%s  rps=%s  succ=%s\n" \
        "$mode" "$c" "${p50:-?}" "${p95:-?}" "${p99:-?}" "${rps:-?}" "${succ:-?}"
}

for MODE in "${MODES[@]}"; do
    echo ""
    echo "=== hotel / $MODE ==="
    bash "$(dirname "$0")/start_redis_N2.sh"

    log "Starting hotel services on N1 ($MODE)..."
    ssh_n1 "REDIS_ADDR='$REDIS_ADDR' N1_PUBLIC_IP='$N1_PUBLIC_IP' \
            bash $REPO_ROOT/scripts/distributed/start_hotel_N1.sh $MODE" \
        > "$OUTDIR/start_${MODE}.log" 2>&1
    sleep 3

    log "Populating 100 hotels + 20 users..."
    bash "$REPO_ROOT/scripts/local/populate_hotel.sh" "$FRONTEND_URL" "$USER_URL" 100 20 > /dev/null
    sleep 2

    oha -n 1000 -c 20 -m POST --no-tui \
        -H 'Content-Type: application/json' \
        -d '{"in_date":"2024-01-01","out_date":"2024-01-02","location":"city0"}' \
        "$FRONTEND_URL/ro_search_hotels" > /dev/null 2>&1 || true
    sleep 2

    for c in "${CONCURRENCIES[@]}"; do
        out_file="$OUTDIR/${MODE}_c${c}.txt"
        log "Running n=$N_REQUESTS c=$c..."
        oha -n "$N_REQUESTS" -c "$c" -m POST --no-tui \
            -H 'Content-Type: application/json' \
            -d '{"in_date":"2024-01-01","out_date":"2024-01-02","location":"city0"}' \
            "$FRONTEND_URL/ro_search_hotels" > "$out_file" 2>&1 || true
        parse_and_append "$MODE" "$c" "$out_file"
    done

    ssh_n1 "bash $REPO_ROOT/scripts/distributed/stop_N1.sh" > /dev/null 2>&1 || true
    sleep 3
done

echo ""
log "DONE."
column -ts, "$SUMMARY"
