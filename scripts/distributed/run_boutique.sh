#!/bin/bash
# Run the distributed boutique benchmark. Execute on Node 0.
#
# Usage on N0:
#   bash scripts/distributed/run_boutique.sh nocm
#   bash scripts/distributed/run_boutique.sh flame
set -e
source "$(dirname "$0")/env.sh"

MODE="${1:-nocm}"
RESULTS_DIR="$REPO_ROOT/latency_results/distributed"
mkdir -p "$RESULTS_DIR"

FRONTEND_URL="http://$N1_PUBLIC_IP:4100"
PRODUCT_URL="http://$N1_PUBLIC_IP:4106"
CURRENCY_URL="http://$N1_PUBLIC_IP:4103"

log "=== boutique / $MODE ==="
log "  N0=$(hostname)  N1=$NODE1_HOST ($N1_PUBLIC_IP)  N2=$NODE2_HOST ($N2_INTERNAL_IP)"
log "  frontend=$FRONTEND_URL  redis=$REDIS_ADDR"

# ── 1. Redis on N2 ─────────────────────────────────────────────────────────────
bash "$(dirname "$0")/start_redis_N2.sh"

# ── 2. Services on N1 ──────────────────────────────────────────────────────────
log "Starting boutique services on N1..."
ssh_n1 "REDIS_ADDR='$REDIS_ADDR' N1_PUBLIC_IP='$N1_PUBLIC_IP' \
       bash $REPO_ROOT/scripts/distributed/start_boutique_N1.sh $MODE" \
    > "$RESULTS_DIR/start_boutique_${MODE}.log" 2>&1

# ── 3. Populate via HTTP to B ─────────────────────────────────────────────────
log "Populating currencies & products..."
bash "$REPO_ROOT/scripts/local/populate_boutique.sh" \
    "$FRONTEND_URL" "$PRODUCT_URL" "$CURRENCY_URL" 100 > /dev/null
log "  data populated"

# ── 4. Warmup + benchmark ──────────────────────────────────────────────────────
log "Warmup..."
oha -n 200 -c 10 -m POST \
    -H 'Content-Type: application/json' \
    -d '{"user_id":"user_0","user_currency":"USD"}' \
    "$FRONTEND_URL/ro_home" > /dev/null 2>&1
sleep "$WAIT_SECS"

log "Benchmark ($N_REQUESTS req, $CONCURRENCY concurrent)..."
OHA_OUT="$RESULTS_DIR/boutique_${MODE}_oha.txt"
oha -n "$N_REQUESTS" -c "$CONCURRENCY" -m POST \
    -H 'Content-Type: application/json' \
    -d '{"user_id":"user_0","user_currency":"USD"}' \
    "$FRONTEND_URL/ro_home" 2>&1 | tee "$OHA_OUT" | \
    grep -E "50\.00%|95\.00%|99\.00%|Requests/sec|Success rate"
sleep "$WAIT_SECS"

# ── 5. Collect logs ────────────────────────────────────────────────────────────
log "Collecting service logs from B..."
OUTFILE="$RESULTS_DIR/boutique_${MODE}.txt"
{
    echo "=== boutique / $MODE (distributed) ==="
    echo "N1: $NODE1_HOST ($N1_PUBLIC_IP)   N2: $NODE2_HOST ($N2_INTERNAL_IP)"
    echo ""
    for svc in frontend cart checkout currency email payment product_catalog recommendations shipping; do
        echo "--- $svc ---"
        ssh_n1 "grep -A 30 'LATENCY REPORT' $REPO_ROOT/logs/boutique/${svc}.log | tail -30" \
            2>/dev/null || echo "(no report)"
        echo ""
    done
} > "$OUTFILE"
log "Results → $OUTFILE"
cat "$OUTFILE"

log "Stopping services on N1..."
ssh_n1 "bash $REPO_ROOT/scripts/distributed/stop_N1.sh" > /dev/null 2>&1 || true
log "=== done: boutique / $MODE ==="
