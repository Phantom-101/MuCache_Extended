#!/bin/bash
# Run latency benchmarks for all 3 workloads × 2 modes (HTTP + flame).
# Collects LATENCY REPORT from service logs.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

RESULTS_DIR="$REPO_ROOT/latency_results"
mkdir -p "$RESULTS_DIR"

N_REQUESTS=3000
CONCURRENCY=20
WAIT_SECS=8  # wait for latency report to flush (5s interval + margin)

cleanup_all() {
    pkill -f "chain_service\|chain_backend\|hotel_\|boutique_\|flame_daemon" 2>/dev/null || true
    sleep 1
    rm -f /dev/shm/hop* /dev/shm/fe_* /dev/shm/search_* /dev/shm/ch_* /dev/shm/co_* /dev/shm/rec_*
}

collect_logs() {
    local workload="$1" mode="$2" logdir="$3"
    local outfile="$RESULTS_DIR/${workload}_${mode}.txt"
    echo "=== $workload / $mode ===" > "$outfile"
    for f in "$logdir"/*.log; do
        svc=$(basename "$f" .log)
        # Skip daemon logs
        [[ "$svc" == flame_daemon* ]] && continue
        [[ "$svc" == redis* ]] && continue
        echo "" >> "$outfile"
        echo "--- $svc ---" >> "$outfile"
        # Get the LAST latency report block (from the benchmark run, not warmup)
        grep -A 30 "LATENCY REPORT" "$f" | tail -30 >> "$outfile" 2>/dev/null || echo "(no report)" >> "$outfile"
    done
    echo ""
    echo ">>> Results saved to $outfile"
    cat "$outfile"
}

run_oha() {
    local url="$1" data="$2"
    echo "  Running: oha -n $N_REQUESTS -c $CONCURRENCY $url"
    oha -n "$N_REQUESTS" -c "$CONCURRENCY" -m POST \
        -H 'Content-Type: application/json' \
        -d "$data" "$url" 2>&1 | grep -E "50\.00%|95\.00%|99\.00%|Requests/sec"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "================================================================"
echo "  CHAIN BENCHMARK"
echo "================================================================"

for MODE in nocm flame; do
    echo ""
    echo ">>> Chain / $MODE"
    cleanup_all
    bash scripts/local/start_chain.sh "$MODE"

    # Populate
    for k in $(seq 1 100); do
        curl -s -X POST http://localhost:3001/write \
            -H 'Content-Type: application/json' \
            -d "{\"k\":$k,\"v\":$k}" > /dev/null
    done
    echo "  Populated 100 keys"

    # Warmup
    oha -n 500 -c 10 -m POST -H 'Content-Type: application/json' \
        -d '{"k":1}' http://localhost:3001/ro_read > /dev/null 2>&1
    sleep "$WAIT_SECS"  # flush warmup report

    # Benchmark
    run_oha "http://localhost:3001/ro_read" '{"k":1}'
    sleep "$WAIT_SECS"

    collect_logs "chain" "$MODE" "$REPO_ROOT/logs/chain"
    cleanup_all
done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  HOTEL BENCHMARK"
echo "================================================================"

for MODE in nocm flame; do
    echo ""
    echo ">>> Hotel / $MODE"
    cleanup_all
    bash scripts/local/start_hotel.sh "$MODE"

    # Populate
    bash scripts/local/populate_hotel.sh http://localhost:4000 http://localhost:4005 100 20
    echo "  Hotel data populated"

    # Warmup
    oha -n 200 -c 10 -m POST -H 'Content-Type: application/json' \
        -d '{"in_date":"2024-01-01","out_date":"2024-01-02","location":"city0"}' \
        http://localhost:4000/ro_search_hotels > /dev/null 2>&1
    sleep "$WAIT_SECS"

    # Benchmark
    run_oha "http://localhost:4000/ro_search_hotels" \
        '{"in_date":"2024-01-01","out_date":"2024-01-02","location":"city0"}'
    sleep "$WAIT_SECS"

    collect_logs "hotel" "$MODE" "$REPO_ROOT/logs/hotel"
    cleanup_all
done

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  BOUTIQUE BENCHMARK"
echo "================================================================"

for MODE in nocm flame; do
    echo ""
    echo ">>> Boutique / $MODE"
    cleanup_all
    bash scripts/local/start_boutique.sh "$MODE"

    # Populate
    bash scripts/local/populate_boutique.sh http://localhost:4100 http://localhost:4106 http://localhost:4103 100
    echo "  Boutique data populated"

    # Warmup
    oha -n 200 -c 10 -m POST -H 'Content-Type: application/json' \
        -d '{}' http://localhost:4100/ro_home > /dev/null 2>&1
    sleep "$WAIT_SECS"

    # Benchmark
    run_oha "http://localhost:4100/ro_home" '{}'
    sleep "$WAIT_SECS"

    collect_logs "boutique" "$MODE" "$REPO_ROOT/logs/boutique"
    cleanup_all
done

echo ""
echo "================================================================"
echo "  ALL DONE — results in $RESULTS_DIR/"
echo "================================================================"
ls -la "$RESULTS_DIR/"
