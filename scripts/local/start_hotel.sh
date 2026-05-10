#!/bin/bash
# Start the hotel benchmark locally.
#
# Topology (fan-out from frontend):
#   frontend:4000 → search:4001 → rate:4002
#                 → reservation:4004
#                 → profile:4003
#                 → user:4005
#   All services share Redis at localhost:6379
#
# Usage:
#   ./scripts/local/start_hotel.sh              # HTTP (baseline)
#   ./scripts/local/start_hotel.sh http         # same
#   ./scripts/local/start_hotel.sh tcs          # tcs shm service-to-service
#   ./scripts/local/start_hotel.sh cq           # counter queue
#   ./scripts/local/start_hotel.sh cq0          # counter queue no copy

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$REPO_ROOT/bin"
LOGS="$REPO_ROOT/logs/hotel"
SVC_URL_FILE="$REPO_ROOT/experiments/local_services/hotel.txt"
FLAME_BIN="/mydata/flame-benchmark/bin/flame_daemon"
FLAME_READY_DIR="/tmp/flame_ready"

MODE="${1:-http}"

mkdir -p "$LOGS" "$FLAME_READY_DIR"

# ── helpers ────────────────────────────────────────────────────────────────────

log() { echo "[start_hotel] $*"; }

stop_hotel() {
    log "Stopping all hotel processes..."
    pkill -f "hotel_" 2>/dev/null || true
    pkill -f "flame_daemon" 2>/dev/null || true
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

start_daemon() {
    local ch="$1"
    local ready_file="$FLAME_READY_DIR/flame_${ch}.ready"
    "$FLAME_BIN" \
        --channel-name "$ch" \
        --msg-size 2048 \
        --window-size 512 \
        --blocking \
        --ready-path "$ready_file" \
        > "$LOGS/flame_daemon_${ch}.log" 2>&1 &
}

# ── clean up ───────────────────────────────────────────────────────────────────
stop_hotel
rm -f "$FLAME_READY_DIR"/flame_*.ready
rm -f /dev/shm/fe_* /dev/shm/search_* /dev/shm/hop*

# ── Redis ──────────────────────────────────────────────────────────────────────
if ! redis-cli ping >/dev/null 2>&1; then
    log "Starting Redis..."
    redis-server --daemonize yes --logfile "$LOGS/redis.log"
    sleep 1
fi
redis-cli flushall >/dev/null
log "Redis OK"

# ── flame channels (tcs_api: each name is one bidirectional channel) ──────────
# frontend → search, rate, reservation, profile, user  (5 channels)
# search   → rate                                       (1 channel)
# Total: 6 bidirectional channels = 6 daemons

if [[ "$MODE" == "tcs" ]]; then
    log "Starting flame daemons (6 bidirectional channels)..."
    for ch in fe_search fe_rate fe_reservation fe_profile fe_user search_rate; do
        start_daemon "$ch"
        log "  daemon for $ch"
    done
    for ch in fe_search fe_rate fe_reservation fe_profile fe_user search_rate; do
        wait_file "$FLAME_READY_DIR/flame_${ch}.ready" "daemon_${ch}"
    done
fi

# ── binary suffix ──────────────────────────────────────────────────────────────
SUFFIX="http"
[[ "$MODE" == "tcs" ]] && SUFFIX="flame"
[[ "$MODE" == "cq" ]] && SUFFIX="flame"
[[ "$MODE" == "cq0" ]] && SUFFIX="flame"

# ── start services ─────────────────────────────────────────────────────────────
log "Starting hotel services (mode=$MODE)..."

# Leaf services first (no downstream)
env PORT=4002 REDIS_URL="localhost:6379" \
    APP_NAME_NO_UNDERSCORES="rate" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAMS="fe_rate,search_rate" \
    "$BIN/hotel_rate_${SUFFIX}" > "$LOGS/rate.log" 2>&1 &
log "  rate         → :4002  (upstream=fe_rate,search_rate)"

env PORT=4003 REDIS_URL="localhost:6379" \
    APP_NAME_NO_UNDERSCORES="profile" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="fe_profile" \
    "$BIN/hotel_profile_${SUFFIX}" > "$LOGS/profile.log" 2>&1 &
log "  profile      → :4003  (upstream=fe_profile)"

env PORT=4004 REDIS_URL="localhost:6379" \
    APP_NAME_NO_UNDERSCORES="reservation" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="fe_reservation" \
    "$BIN/hotel_reservation_${SUFFIX}" > "$LOGS/reservation.log" 2>&1 &
log "  reservation  → :4004  (upstream=fe_reservation)"

env PORT=4005 REDIS_URL="localhost:6379" \
    APP_NAME_NO_UNDERSCORES="user" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="fe_user" \
    "$BIN/hotel_user_${SUFFIX}" > "$LOGS/user.log" 2>&1 &
log "  user         → :4005  (upstream=fe_user)"

# Search (calls rate)
env PORT=4001 REDIS_URL="localhost:6379" \
    APP_NAME_NO_UNDERSCORES="search" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="fe_search" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/hotel_search.txt" \
    "$BIN/hotel_search_${SUFFIX}" > "$LOGS/search.log" 2>&1 &
log "  search       → :4001  (upstream=fe_search, downstream=rate)"

# Frontend (calls search, reservation, profile, user)
env PORT=4000 REDIS_URL="localhost:6379" \
    APP_NAME_NO_UNDERSCORES="frontend" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_MODE="$MODE" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/hotel_frontend.txt" \
    "$BIN/hotel_frontend_${SUFFIX}" > "$LOGS/frontend.log" 2>&1 &
log "  frontend     → :4000  (downstream=search,reservation,profile,user)"

# ── wait for heartbeats ───────────────────────────────────────────────────────
log "Waiting for services..."
wait_http http://localhost:4000/heartbeat "frontend"
wait_http http://localhost:4001/heartbeat "search"
wait_http http://localhost:4002/heartbeat "rate"
wait_http http://localhost:4003/heartbeat "profile"
wait_http http://localhost:4004/heartbeat "reservation"
wait_http http://localhost:4005/heartbeat "user"

log ""
log "All services up! (mode=$MODE)"
log ""
log "Populate data:"
log "  go run ./cmd/hotelpopulate/ (or see below)"
log ""
log "Benchmark:"
log "  oha -n 1000 -c 20 -m POST -H 'Content-Type: application/json' \\"
log "    -d '{\"in_date\":\"2024-01-01\",\"out_date\":\"2024-01-02\",\"location\":\"city0\"}' \\"
log "    http://localhost:4000/ro_search_hotels"
log ""
log "Logs: $LOGS/"
log "Stop: pkill -f hotel_; pkill -f flame_daemon"
