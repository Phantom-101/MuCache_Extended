#!/bin/bash
# Start the chain microservices on Node 1.
#
# Topology (all services on N1; client + Redis on N2):
#   A-client → B:service1:3001 → service2:3002 → service3:3003 →
#              service4:3004 → backend:3005 → A:redis:6379
#
# Inter-service hops on N1 use:
#   nocm  → HTTP  (localhost:300x)
#   flame → shared memory (tcs_api channels)
#
# Usage on N1:
#   bash scripts/distributed/start_chain_N1.sh nocm
#   bash scripts/distributed/start_chain_N1.sh flame
#
# Required env: REDIS_ADDR  (e.g. 10.10.1.1:6379, pointing at Node 0)
set -e
source "$(dirname "$0")/env.sh"

BIN="$REPO_ROOT/bin"
LOGS="$REPO_ROOT/logs/chain"
SVC_URL_FILE="$REPO_ROOT/experiments/local_services/chain.txt"
FLAME_READY_DIR="/tmp/flame_ready"

MODE="${1:-nocm}"
mkdir -p "$LOGS" "$FLAME_READY_DIR"

# ── cleanup: kill by exact binary names to avoid matching this script ─────────
stop_chain() {
    log "Stopping stale chain processes on N1..."
    killall \
        chain_service1_nocm  chain_service2_nocm  chain_service3_nocm \
        chain_service4_nocm  chain_backend_nocm \
        chain_service1_flame chain_service2_flame chain_service3_flame \
        chain_service4_flame chain_backend_flame \
        flame_daemon \
        2>/dev/null || true
    sleep 1
}

wait_http() {
    local url="$1" name="$2"
    for i in $(seq 1 60); do
        curl -sf "$url" >/dev/null 2>&1 && { log "$name up"; return 0; }
        sleep 0.3
    done
    log "ERROR: $name at $url did not start in time"
    exit 1
}

wait_file() {
    local path="$1" name="$2"
    for i in $(seq 1 200); do
        [[ -f "$path" ]] && { log "$name ready"; return 0; }
        sleep 0.1
    done
    log "ERROR: $name ready-file $path missing"
    exit 1
}

stop_chain
rm -f "$FLAME_READY_DIR"/flame_*.ready
rm -f /dev/shm/hop*

# ── flame daemons (only in flame mode) ─────────────────────────────────────────
if [[ "$MODE" == "flame" ]]; then
    log "Starting flame daemons (4 bidirectional channels)..."
    for hop in hop1 hop2 hop3 hop4; do
        "$FLAME_BIN" \
            --channel-name "$hop" \
            --msg-size 2048 \
            --window-size 512 \
            --blocking \
            --ready-path "$FLAME_READY_DIR/flame_${hop}.ready" \
            > "$LOGS/flame_daemon_${hop}.log" 2>&1 &
    done
    for hop in hop1 hop2 hop3 hop4; do
        wait_file "$FLAME_READY_DIR/flame_${hop}.ready" "daemon_${hop}"
    done
fi

SUFFIX="nocm"
[[ "$MODE" == "flame" ]] && SUFFIX="flame"

# ── start microservices ────────────────────────────────────────────────────────
log "Starting chain services (mode=$MODE, redis=$REDIS_ADDR)..."

env PORT=3001 REDIS_URL="$REDIS_ADDR" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    APP_NAME_NO_UNDERSCORES="service1" \
    FLAME_DOWNSTREAM="hop1" \
    FLAME_DOWNSTREAM_APP="service2" \
    "$BIN/chain_service1_${SUFFIX}" > "$LOGS/service1.log" 2>&1 &

env PORT=3002 REDIS_URL="$REDIS_ADDR" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    APP_NAME_NO_UNDERSCORES="service2" \
    FLAME_UPSTREAM="hop1" \
    FLAME_DOWNSTREAM="hop2" \
    FLAME_DOWNSTREAM_APP="service3" \
    "$BIN/chain_service2_${SUFFIX}" > "$LOGS/service2.log" 2>&1 &

env PORT=3003 REDIS_URL="$REDIS_ADDR" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    APP_NAME_NO_UNDERSCORES="service3" \
    FLAME_UPSTREAM="hop2" \
    FLAME_DOWNSTREAM="hop3" \
    FLAME_DOWNSTREAM_APP="service4" \
    "$BIN/chain_service3_${SUFFIX}" > "$LOGS/service3.log" 2>&1 &

env PORT=3004 REDIS_URL="$REDIS_ADDR" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    APP_NAME_NO_UNDERSCORES="service4" \
    FLAME_UPSTREAM="hop3" \
    FLAME_DOWNSTREAM="hop4" \
    FLAME_DOWNSTREAM_APP="backend" \
    "$BIN/chain_service4_${SUFFIX}" > "$LOGS/service4.log" 2>&1 &

env PORT=3005 REDIS_URL="$REDIS_ADDR" \
    APP_NAME_NO_UNDERSCORES="backend" \
    FLAME_UPSTREAM="hop4" \
    "$BIN/chain_backend_${SUFFIX}" > "$LOGS/backend.log" 2>&1 &

# ── wait for heartbeats ───────────────────────────────────────────────────────
log "Waiting for services..."
wait_http http://localhost:3001/heartbeat "service1"
wait_http http://localhost:3002/heartbeat "service2"
wait_http http://localhost:3003/heartbeat "service3"
wait_http http://localhost:3004/heartbeat "service4"
wait_http http://localhost:3005/heartbeat "backend"

log "All chain services up on N1 (mode=$MODE). frontend = http://$N1_PUBLIC_IP:3001"
