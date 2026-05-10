#!/bin/bash
# Start the chain benchmark locally.
#
# Topology:
#   client → service1:3001 → service2:3002 → service3:3003 → service4:3004 → backend:3005
#   (inter-service: HTTP in http mode, tcs shm in tcs mode, counter queue in cq mode, counter queue no copy in cq0 mode)
#   backend reads/writes Redis at localhost:6379
#
# Usage:
#   ./scripts/local/start_chain.sh              # HTTP service-to-service (baseline)
#   ./scripts/local/start_chain.sh http         # same as above (explicit)
#   ./scripts/local/start_chain.sh tcs          # tcs shm service-to-service
#   ./scripts/local/start_chain.sh cq           # counter queue
#   ./scripts/local/start_chain.sh cq0          # counter queue no copy

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$REPO_ROOT/bin"
LOGS="$REPO_ROOT/logs/chain"
SVC_URL_FILE="$REPO_ROOT/experiments/local_services/chain.txt"
FLAME_BIN="/mydata/flame-benchmark/bin/flame_daemon"
FLAME_READY_DIR="/tmp/flame_ready"

MODE="${1:-http}"   # http | tcs | cq | cq0

mkdir -p "$LOGS" "$FLAME_READY_DIR"

# ── helpers ────────────────────────────────────────────────────────────────────

log() { echo "[start_chain] $*"; }

stop_chain() {
    log "Stopping all chain processes..."
    pkill -f "chain_service" 2>/dev/null || true
    pkill -f "chain_backend" 2>/dev/null || true
    pkill -f "flame_daemon"  2>/dev/null || true
    sleep 0.5
}

wait_http() {
    local url="$1" name="$2"
    for i in $(seq 1 30); do
        if curl -sf "$url" >/dev/null 2>&1; then
            log "$name is up"
            return 0
        fi
        sleep 0.3
    done
    log "ERROR: $name at $url did not start in time"
    exit 1
}

wait_file() {
    local path="$1" name="$2"
    for i in $(seq 1 100); do
        if [[ -f "$path" ]]; then
            log "$name is ready"
            return 0
        fi
        sleep 0.1
    done
    log "ERROR: $name ready-file $path not found in time"
    exit 1
}

# ── clean up ───────────────────────────────────────────────────────────────────
stop_chain
rm -f "$FLAME_READY_DIR"/flame_*.ready
rm -f /dev/shm/hop*   # clean up leftover shm regions

# ── Redis ──────────────────────────────────────────────────────────────────────
if ! redis-cli ping >/dev/null 2>&1; then
    log "Starting Redis..."
    redis-server --daemonize yes --logfile "$LOGS/redis.log"
    sleep 1
fi
redis-cli flushall >/dev/null
log "Redis OK"

# ── flame daemons (one per hop, each hop = req + resp channel) ─────────────────
# hop1: service1 → service2
# hop2: service2 → service3
# hop3: service3 → service4
# hop4: service4 → backend
if [[ "$MODE" == "tcs" ]]; then
    log "Starting flame daemons (4 bidirectional channels, one per hop)..."
    # tcs_api model: each channel name is bidirectional (req + resp inside one
    # PeerSharedMemory pair). One daemon per hop does both directions.
    for hop in hop1 hop2 hop3 hop4; do
        ready_file="$FLAME_READY_DIR/flame_${hop}.ready"
        "$FLAME_BIN" \
            --channel-name "$hop" \
            --msg-size 2048 \
            --window-size 512 \
            --blocking \
            --ready-path "$ready_file" \
            > "$LOGS/flame_daemon_${hop}.log" 2>&1 &
        log "  daemon for $hop"
    done

    for hop in hop1 hop2 hop3 hop4; do
        wait_file "$FLAME_READY_DIR/flame_${hop}.ready" "daemon_${hop}"
    done
fi

# ── binary suffix ──────────────────────────────────────────────────────────────
SUFFIX="http"
[[ "$MODE" == "tcs" ]] && SUFFIX="flame"
[[ "$MODE" == "cq" ]] && SUFFIX="flame"
[[ "$MODE" == "cq0" ]] && SUFFIX="flame"

# ── start microservices ────────────────────────────────────────────────────────
log "Starting microservices (mode=$MODE)..."

# service1: HTTP in from client (oha), flame out to service2 (hop1)
env PORT=3001 \
    REDIS_URL="localhost:6379" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    APP_NAME_NO_UNDERSCORES="service1" \
    FLAME_MODE="$MODE" \
    FLAME_DOWNSTREAM="hop1" \
    FLAME_DOWNSTREAM_APP="service2" \
    "$BIN/chain_service1_${SUFFIX}" > "$LOGS/service1.log" 2>&1 &
log "  service1 → :3001  (HTTP in, downstream=hop1)"

# service2: flame in from service1 (hop1), flame out to service3 (hop2)
env PORT=3002 \
    REDIS_URL="localhost:6379" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    APP_NAME_NO_UNDERSCORES="service2" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="hop1" \
    FLAME_DOWNSTREAM="hop2" \
    FLAME_DOWNSTREAM_APP="service3" \
    "$BIN/chain_service2_${SUFFIX}" > "$LOGS/service2.log" 2>&1 &
log "  service2 → :3002  (upstream=hop1, downstream=hop2)"

# service3: flame in from service2 (hop2), flame out to service4 (hop3)
env PORT=3003 \
    REDIS_URL="localhost:6379" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    APP_NAME_NO_UNDERSCORES="service3" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="hop2" \
    FLAME_DOWNSTREAM="hop3" \
    FLAME_DOWNSTREAM_APP="service4" \
    "$BIN/chain_service3_${SUFFIX}" > "$LOGS/service3.log" 2>&1 &
log "  service3 → :3003  (upstream=hop2, downstream=hop3)"

# service4: flame in from service3 (hop3), flame out to backend (hop4)
env PORT=3004 \
    REDIS_URL="localhost:6379" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    APP_NAME_NO_UNDERSCORES="service4" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="hop3" \
    FLAME_DOWNSTREAM="hop4" \
    FLAME_DOWNSTREAM_APP="backend" \
    "$BIN/chain_service4_${SUFFIX}" > "$LOGS/service4.log" 2>&1 &
log "  service4 → :3004  (upstream=hop3, downstream=hop4)"

# backend: flame in from service4 (hop4), no downstream (reads Redis)
env PORT=3005 \
    REDIS_URL="localhost:6379" \
    APP_NAME_NO_UNDERSCORES="backend" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="hop4" \
    "$BIN/chain_backend_${SUFFIX}" > "$LOGS/backend.log" 2>&1 &
log "  backend  → :3005  (upstream=hop4)"

# ── wait for heartbeats ───────────────────────────────────────────────────────
log "Waiting for services..."
wait_http http://localhost:3001/heartbeat "service1"
wait_http http://localhost:3002/heartbeat "service2"
wait_http http://localhost:3003/heartbeat "service3"
wait_http http://localhost:3004/heartbeat "service4"
wait_http http://localhost:3005/heartbeat "backend"

log ""
log "All services up! (mode=$MODE)"
log ""
log "  curl -s -X POST http://localhost:3001/ro_read -H 'Content-Type: application/json' -d '{\"k\":1}'"
log "  oha -n 5000 -c 50 -m POST -H 'Content-Type: application/json' -d '{\"k\":1}' http://localhost:3001/ro_read"
log ""
log "Logs: $LOGS/"
log "Stop: pkill -f chain_service; pkill -f chain_backend; pkill -f flame_daemon"
