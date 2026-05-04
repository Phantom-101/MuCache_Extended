#!/bin/bash
# Throughput–latency sweep for boutique (distributed N0/N1/N2).
# Mirrors the local reference script but drives N1 over ssh + N2 redis.
#
#   For each MODE in (nocm, flame):
#     - start_redis_N2 + start_boutique_N1
#     - populate
#     - for c in CONCURRENCIES: oha -n N_REQUESTS -c c
#     - tear down N1
#
# Run on Node 0:
#   bash scripts/distributed/sweep_boutique.sh
#   N_REQUESTS=50000 CONCURRENCIES="25 50 100 200" bash scripts/distributed/sweep_boutique.sh
set -e
source "$(dirname "$0")/env.sh"

MODES=(${MODES:-nocm flame})
N_REQUESTS="${N_REQUESTS:-100000}"
CONCURRENCIES=(${CONCURRENCIES:-25 50 75 100 125 150 175 200})

OUTDIR="${OUTDIR:-$REPO_ROOT/results/boutique_distributed}"
mkdir -p "$OUTDIR"

FRONTEND_URL="http://$N1_PUBLIC_IP:4100"
PRODUCT_URL="http://$N1_PUBLIC_IP:4106"
CURRENCY_URL="http://$N1_PUBLIC_IP:4103"

SUMMARY="$OUTDIR/summary.csv"
echo "mode,concurrency,requests,p50_ms,p95_ms,p99_ms,rps,success_rate" > "$SUMMARY"

log "Sweep config:"
log "  modes         = ${MODES[*]}"
log "  concurrencies = ${CONCURRENCIES[*]}"
log "  N_REQUESTS    = $N_REQUESTS"
log "  N1            = $NODE1_HOST ($N1_PUBLIC_IP)"
log "  N2            = $NODE2_HOST ($N2_INTERNAL_IP)"
log "  output dir    = $OUTDIR"

# ── helper: parse oha output, append a row to summary ─────────────────────────
parse_and_append() {
    local mode="$1" c="$2" file="$3"
    local p50 p95 p99 rps succ
    # Strip ANSI escape codes so awk field indices are stable
    local tmp; tmp=$(mktemp)
    sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[?[0-9]*[lh]//g' "$file" > "$tmp"
    # oha percentile lines: "  50.00% in 0.0020 secs"  →  $1=50.00%, $2=in, $3=<value>
    p50=$(awk '/50\.00%/ {print $3; exit}' "$tmp")
    p95=$(awk '/95\.00%/ {print $3; exit}' "$tmp")
    p99=$(awk '/99\.00%/ {print $3; exit}' "$tmp")
    # "  Requests/sec:   12345"  →  $2=value
    rps=$(awk '/Requests\/sec/ {print $2; exit}' "$tmp")
    # "  Success rate:   100.00%"  →  $3=value
    succ=$(awk '/Success rate/ {print $3; exit}' "$tmp")
    rm -f "$tmp"
    echo "$mode,$c,$N_REQUESTS,$p50,$p95,$p99,$rps,$succ" >> "$SUMMARY"
    printf "    [%s c=%-3d] p50=%s  p95=%s  p99=%s  rps=%s  succ=%s\n" \
        "$mode" "$c" "${p50:-?}" "${p95:-?}" "${p99:-?}" "${rps:-?}" "${succ:-?}"
}

for MODE in "${MODES[@]}"; do
    echo ""
    echo "================================================================"
    echo "  boutique / $MODE"
    echo "================================================================"

    # ── (re)start redis on N2 ──────────────────────────────────────────────────
    bash "$(dirname "$0")/start_redis_N2.sh"

    # ── start services on N1 ───────────────────────────────────────────────────
    log "Starting boutique services on N1 ($MODE)..."
    ssh_n1 "REDIS_ADDR='$REDIS_ADDR' N1_PUBLIC_IP='$N1_PUBLIC_IP' \
            bash $REPO_ROOT/scripts/distributed/start_boutique_N1.sh $MODE" \
        > "$OUTDIR/start_${MODE}.log" 2>&1
    sleep 3

    # ── populate (curl from N0 to N1 frontend) ─────────────────────────────────
    log "Populating boutique data..."
    bash "$REPO_ROOT/scripts/local/populate_boutique.sh" \
        "$FRONTEND_URL" "$PRODUCT_URL" "$CURRENCY_URL" 100 > /dev/null
    sleep 3

    # ── short warmup so JIT / connections settle ──────────────────────────────
    oha -n 1000 -c 20 -m POST --no-tui \
        -H 'Content-Type: application/json' \
        -d '{"user_id":"user_0","user_currency":"USD"}' \
        "$FRONTEND_URL/ro_home" > /dev/null 2>&1 || true
    sleep 2

    # ── sweep ──────────────────────────────────────────────────────────────────
    for c in "${CONCURRENCIES[@]}"; do
        out_file="$OUTDIR/${MODE}_c${c}.txt"
        log "Running n=$N_REQUESTS c=$c..."
        oha -n "$N_REQUESTS" -c "$c" -m POST --no-tui \
            -H 'Content-Type: application/json' \
            -d '{"user_id":"user_0","user_currency":"USD"}' \
            "$FRONTEND_URL/ro_home" > "$out_file" 2>&1 || true
        parse_and_append "$MODE" "$c" "$out_file"
    done

    # ── tear down N1 (Redis on N2 stays up across modes; we just flush) ───────
    log "Stopping services on N1..."
    ssh_n1 "bash $REPO_ROOT/scripts/distributed/stop_N1.sh" > /dev/null 2>&1 || true
    sleep 3
done

echo ""
log "DONE. Summary:"
column -ts, "$SUMMARY"
log "Per-run oha output: $OUTDIR/*.txt"
log "CSV:                $SUMMARY"
