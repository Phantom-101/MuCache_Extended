#!/bin/bash
# Start the hotel microservices on Node 1.
#
# Topology (all services on N1; client + Redis on N2):
#   A-client → B:frontend:4000
#            → search:4001 → rate:4002
#            → reservation:4004
#            → profile:4003
#            → user:4005
#   all reads/writes go to A:redis:6379
#
# Usage on N1:
#   bash scripts/distributed/start_hotel_N1.sh nocm
#   bash scripts/distributed/start_hotel_N1.sh flame
set -e
source "$(dirname "$0")/env.sh"

BIN="$REPO_ROOT/bin"
LOGS="$REPO_ROOT/logs/hotel"
SVC_URL_FILE="$REPO_ROOT/experiments/local_services/hotel.txt"
FLAME_READY_DIR="/tmp/flame_ready"

MODE="${1:-nocm}"
mkdir -p "$LOGS" "$FLAME_READY_DIR"

stop_hotel() {
    log "Stopping stale hotel processes on N1..."
    killall \
        hotel_frontend_nocm  hotel_search_nocm  hotel_rate_nocm \
        hotel_reservation_nocm hotel_profile_nocm hotel_user_nocm \
        hotel_frontend_flame hotel_search_flame hotel_rate_flame \
        hotel_reservation_flame hotel_profile_flame hotel_user_flame \
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
    log "ERROR: $name at $url did not start in time"; exit 1
}

wait_file() {
    local path="$1" name="$2"
    for i in $(seq 1 200); do
        [[ -f "$path" ]] && { log "$name ready"; return 0; }
        sleep 0.1
    done
    log "ERROR: $name ready-file $path missing"; exit 1
}

start_daemon() {
    local ch="$1"
    "$FLAME_BIN" \
        --channel-name "$ch" \
        --msg-size 2048 \
        --window-size 512 \
        --blocking \
        --ready-path "$FLAME_READY_DIR/flame_${ch}.ready" \
        > "$LOGS/flame_daemon_${ch}.log" 2>&1 &
}

stop_hotel
rm -f "$FLAME_READY_DIR"/flame_*.ready
rm -f /dev/shm/fe_* /dev/shm/search_* /dev/shm/hop*

CHANNELS="fe_search fe_rate fe_reservation fe_profile fe_user search_rate"
if [[ "$MODE" == "flame" ]]; then
    log "Starting flame daemons (6 bidirectional channels)..."
    for ch in $CHANNELS; do start_daemon "$ch"; done
    for ch in $CHANNELS; do wait_file "$FLAME_READY_DIR/flame_${ch}.ready" "daemon_${ch}"; done
fi

SUFFIX="nocm"
[[ "$MODE" == "flame" ]] && SUFFIX="flame"

log "Starting hotel services (mode=$MODE, redis=$REDIS_ADDR)..."

# Leaves first
env PORT=4002 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="rate" \
    FLAME_UPSTREAMS="fe_rate,search_rate" \
    "$BIN/hotel_rate_${SUFFIX}" > "$LOGS/rate.log" 2>&1 &

env PORT=4003 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="profile" \
    FLAME_UPSTREAM="fe_profile" \
    "$BIN/hotel_profile_${SUFFIX}" > "$LOGS/profile.log" 2>&1 &

env PORT=4004 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="reservation" \
    FLAME_UPSTREAM="fe_reservation" \
    "$BIN/hotel_reservation_${SUFFIX}" > "$LOGS/reservation.log" 2>&1 &

env PORT=4005 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="user" \
    FLAME_UPSTREAM="fe_user" \
    "$BIN/hotel_user_${SUFFIX}" > "$LOGS/user.log" 2>&1 &

env PORT=4001 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="search" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_UPSTREAM="fe_search" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/hotel_search.txt" \
    "$BIN/hotel_search_${SUFFIX}" > "$LOGS/search.log" 2>&1 &

env PORT=4000 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="frontend" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/hotel_frontend.txt" \
    "$BIN/hotel_frontend_${SUFFIX}" > "$LOGS/frontend.log" 2>&1 &

log "Waiting for services..."
wait_http http://localhost:4000/heartbeat "frontend"
wait_http http://localhost:4001/heartbeat "search"
wait_http http://localhost:4002/heartbeat "rate"
wait_http http://localhost:4003/heartbeat "profile"
wait_http http://localhost:4004/heartbeat "reservation"
wait_http http://localhost:4005/heartbeat "user"

log "All hotel services up on N1 (mode=$MODE). frontend = http://$N1_PUBLIC_IP:4000"
