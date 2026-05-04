#!/bin/bash
# Run the distributed chain benchmark across N0 (client) / N1 (services) / N2 (redis).
# Execute on Node 0.
#
# Usage on N0:
#   bash scripts/distributed/run_chain.sh nocm
#   bash scripts/distributed/run_chain.sh flame
set -e
source "$(dirname "$0")/env.sh"

MODE="${1:-nocm}"
RESULTS_DIR="$REPO_ROOT/latency_results/distributed"
mkdir -p "$RESULTS_DIR"

FRONTEND_URL="http://$N1_PUBLIC_IP:3001"

log "=== chain / $MODE ==="
log "  N0 (client)   : $(hostname)"
log "  N1 (services) : $NODE1_HOST ($N1_PUBLIC_IP)"
log "  N2 (redis)    : $NODE2_HOST ($N2_INTERNAL_IP)"
log "  frontend URL  : $FRONTEND_URL"
log "  redis         : $REDIS_ADDR"

# ── 1. Redis on N2 ─────────────────────────────────────────────────────────────
bash "$(dirname "$0")/start_redis_N2.sh"

# ── 2. Services on N1 ──────────────────────────────────────────────────────────
log "Starting chain services on N1..."
ssh_n1 "REDIS_ADDR='$REDIS_ADDR' N1_PUBLIC_IP='$N1_PUBLIC_IP' \
       bash $REPO_ROOT/scripts/distributed/start_chain_N1.sh $MODE" \
    > "$RESULTS_DIR/start_chain_${MODE}.log" 2>&1

# ── 3. Populate via HTTP to N1 ─────────────────────────────────────────────────
log "Populating chain keys..."
for k in $(seq 1 100); do
    curl -s -X POST "$FRONTEND_URL/write" \
        -H 'Content-Type: application/json' \
        -d "{\"k\":$k,\"v\":$k}" > /dev/null
done
log "  100 keys written"

# ── 4. Warmup + benchmark ──────────────────────────────────────────────────────
log "Warmup..."
oha -n 500 -c 10 -m POST \
    -H 'Content-Type: application/json' \
    -d '{"k":1}' "$FRONTEND_URL/ro_read" > /dev/null 2>&1
sleep "$WAIT_SECS"

log "Benchmark ($N_REQUESTS req, $CONCURRENCY concurrent)..."
OHA_OUT="$RESULTS_DIR/chain_${MODE}_oha.txt"
oha -n "$N_REQUESTS" -c "$CONCURRENCY" -m POST \
    -H 'Content-Type: application/json' \
    -d '{"k":1}' "$FRONTEND_URL/ro_read" 2>&1 | tee "$OHA_OUT" | \
    grep -E "50\.00%|95\.00%|99\.00%|Requests/sec|Success rate"
sleep "$WAIT_SECS"

# ── 5. Collect service logs from N1 ────────────────────────────────────────────
log "Collecting service logs from N1..."
OUTFILE="$RESULTS_DIR/chain_${MODE}.txt"
{
    echo "=== chain / $MODE (distributed N0/N1/N2) ==="
    echo "N1 (services): $NODE1_HOST ($N1_PUBLIC_IP)"
    echo "N2 (redis)   : $NODE2_HOST ($N2_INTERNAL_IP)"
    echo ""
    for svc in service1 service2 service3 service4 backend; do
        echo "--- $svc ---"
        ssh_n1 "grep -A 30 'LATENCY REPORT' $REPO_ROOT/logs/chain/${svc}.log | tail -30" \
            2>/dev/null || echo "(no report)"
        echo ""
    done
} > "$OUTFILE"
log "Results → $OUTFILE"
cat "$OUTFILE"

# ── 6. Stop services on N1 (Redis on N2 stays up for next run) ─────────────────
log "Stopping services on N1..."
ssh_n1 "bash $REPO_ROOT/scripts/distributed/stop_N1.sh" > /dev/null 2>&1 || true

log "=== done: chain / $MODE ==="
