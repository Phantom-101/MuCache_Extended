#!/bin/bash
# Start the boutique (Online Boutique) benchmark locally.
#
# Topology:
#   client → frontend:4100
#   frontend → currency:4103, cart:4101, productcatalog:4106, checkout:4102
#   checkout → productcatalog, currency, cart, shipping, payment, email
#   recommendations → productcatalog  (independent; no upstream)
#
# All services share Redis at localhost:6379.
#
# Usage:
#   ./scripts/local/start_boutique.sh              # HTTP baseline
#   ./scripts/local/start_boutique.sh http         # same
#   ./scripts/local/start_boutique.sh tcs          # tcs shm
#   ./scripts/local/start_boutique.sh cq           # counter queue
#   ./scripts/local/start_boutique.sh cq0          # counter queue no copy

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$REPO_ROOT/bin"
LOGS="$REPO_ROOT/logs/boutique"
SVC_URL_FILE="$REPO_ROOT/experiments/local_services/boutique.txt"
FLAME_BIN="/mydata/flame-benchmark/bin/flame_daemon"
FLAME_READY_DIR="/tmp/flame_ready"

MODE="${1:-http}"

mkdir -p "$LOGS" "$FLAME_READY_DIR"

log() { echo "[start_boutique] $*"; }

stop_boutique() {
    log "Stopping all boutique processes..."
    pkill -f "boutique_" 2>/dev/null || true
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
        [[ -f "$path" ]] && { log "$name is ready"; return 0; }
        sleep 0.1
    done
    log "ERROR: $name ready-file $path missing"
    exit 1
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

stop_boutique
rm -f "$FLAME_READY_DIR"/flame_*.ready
rm -f /dev/shm/fe_* /dev/shm/co_* /dev/shm/rec_* /dev/shm/search_* /dev/shm/hop*

# ── Redis ──────────────────────────────────────────────────────────────────────
if ! redis-cli ping >/dev/null 2>&1; then
    log "Starting Redis..."
    redis-server --daemonize yes --logfile "$LOGS/redis.log"
    sleep 1
fi
redis-cli flushall >/dev/null
log "Redis OK"

# ── flame daemons ──────────────────────────────────────────────────────────────
# frontend downstreams: fe_currency, fe_cart, fe_productcatalog, fe_checkout (4)
# checkout downstreams: co_productcatalog, co_currency, co_cart, co_shipping, co_payment, co_email (6)
# recommendations downstream: rec_productcatalog (1)
# Total: 11 bidirectional channels.

CHANNELS="fe_currency fe_cart fe_productcatalog fe_checkout \
co_productcatalog co_currency co_cart co_shipping co_payment co_email \
rec_productcatalog"

if [[ "$MODE" == "tcs" ]]; then
    log "Starting flame daemons (11 bidirectional channels)..."
    for ch in $CHANNELS; do
        start_daemon "$ch"
        log "  daemon for $ch"
    done
    for ch in $CHANNELS; do
        wait_file "$FLAME_READY_DIR/flame_${ch}.ready" "daemon_${ch}"
    done
fi

SUFFIX="http"
[[ "$MODE" == "tcs" ]] && SUFFIX="flame"
[[ "$MODE" == "cq" ]] && SUFFIX="flame"
[[ "$MODE" == "cq0" ]] && SUFFIX="flame"

# ── start services (leaves first, so the others find them on HTTP) ────────────
log "Starting boutique services (mode=$MODE)..."

# ─── leaf services (upstream-only) ─────────────────────────────────────────────
env PORT=4101 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="cart" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAMS="fe_cart,co_cart" \
    "$BIN/boutique_cart_${SUFFIX}" > "$LOGS/cart.log" 2>&1 &
log "  cart            → :4101  (upstream=fe_cart,co_cart)"

env PORT=4103 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="currency" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAMS="fe_currency,co_currency" \
    "$BIN/boutique_currency_${SUFFIX}" > "$LOGS/currency.log" 2>&1 &
log "  currency        → :4103  (upstream=fe_currency,co_currency)"

env PORT=4104 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="email" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="co_email" \
    "$BIN/boutique_email_${SUFFIX}" > "$LOGS/email.log" 2>&1 &
log "  email           → :4104  (upstream=co_email)"

env PORT=4105 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="payment" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="co_payment" \
    "$BIN/boutique_payment_${SUFFIX}" > "$LOGS/payment.log" 2>&1 &
log "  payment         → :4105  (upstream=co_payment)"

env PORT=4106 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="productcatalog" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAMS="fe_productcatalog,co_productcatalog,rec_productcatalog" \
    "$BIN/boutique_product_catalog_${SUFFIX}" > "$LOGS/product_catalog.log" 2>&1 &
log "  product_catalog → :4106  (upstream=fe_pc,co_pc,rec_pc)"

env PORT=4108 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="shipping" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="co_shipping" \
    "$BIN/boutique_shipping_${SUFFIX}" > "$LOGS/shipping.log" 2>&1 &
log "  shipping        → :4108  (upstream=co_shipping)"

# ─── recommendations (downstream=productcatalog, no upstream from others) ─────
env PORT=4107 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="recommendations" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_MODE="$MODE" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/boutique_recommendations.txt" \
    "$BIN/boutique_recommendations_${SUFFIX}" > "$LOGS/recommendations.log" 2>&1 &
log "  recommendations → :4107  (downstream=productcatalog)"

# ─── checkout (many downstreams, one upstream from frontend) ──────────────────
env PORT=4102 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="checkout" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_MODE="$MODE" \
    FLAME_UPSTREAM="fe_checkout" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/boutique_checkout.txt" \
    "$BIN/boutique_checkout_${SUFFIX}" > "$LOGS/checkout.log" 2>&1 &
log "  checkout        → :4102  (upstream=fe_checkout, downstream=pc,currency,cart,shipping,payment,email)"

# ─── frontend (HTTP in, flame out to 4 downstreams) ───────────────────────────
env PORT=4100 REDIS_URL="localhost:6379" APP_NAME_NO_UNDERSCORES="frontend" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_MODE="$MODE" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/boutique_frontend.txt" \
    "$BIN/boutique_frontend_${SUFFIX}" > "$LOGS/frontend.log" 2>&1 &
log "  frontend        → :4100  (downstream=currency,cart,productcatalog,checkout)"

# ── wait for heartbeats ───────────────────────────────────────────────────────
log "Waiting for services..."
wait_http http://localhost:4100/heartbeat "frontend"
wait_http http://localhost:4101/heartbeat "cart"
wait_http http://localhost:4102/heartbeat "checkout"
wait_http http://localhost:4103/heartbeat "currency"
wait_http http://localhost:4104/heartbeat "email"
wait_http http://localhost:4105/heartbeat "payment"
wait_http http://localhost:4106/heartbeat "product_catalog"
wait_http http://localhost:4107/heartbeat "recommendations"
wait_http http://localhost:4108/heartbeat "shipping"

log ""
log "All services up! (mode=$MODE)"
log ""
log "Populate data:"
log "  go run ./cmd/boutiquepopulate/"
log ""
log "Benchmark (example — /ro_home):"
log "  oha -n 1000 -c 20 -m POST -H 'Content-Type: application/json' \\"
log "    -d '{\"user_id\":\"user_0\",\"user_currency\":\"USD\"}' \\"
log "    http://localhost:4100/ro_home"
log ""
log "Logs: $LOGS/"
log "Stop: pkill -f boutique_; pkill -f flame_daemon"
