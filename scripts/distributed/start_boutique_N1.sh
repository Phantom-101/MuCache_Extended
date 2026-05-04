#!/bin/bash
# Start the boutique (OnlineBoutique) microservices on Node 1.
#
# Topology (all services on N1; client + Redis on N2):
#   A-client → B:frontend:4100
#   frontend → currency:4103, cart:4101, productcatalog:4106, checkout:4102
#   checkout → productcatalog, currency, cart, shipping, payment, email
#   recommendations → productcatalog  (independent)
#
# Usage on N1:
#   bash scripts/distributed/start_boutique_N1.sh nocm
#   bash scripts/distributed/start_boutique_N1.sh flame
set -e
source "$(dirname "$0")/env.sh"

BIN="$REPO_ROOT/bin"
LOGS="$REPO_ROOT/logs/boutique"
SVC_URL_FILE="$REPO_ROOT/experiments/local_services/boutique.txt"
FLAME_READY_DIR="/tmp/flame_ready"

MODE="${1:-nocm}"
mkdir -p "$LOGS" "$FLAME_READY_DIR"

stop_boutique() {
    log "Stopping stale boutique processes on N1..."
    killall \
        boutique_cart_nocm boutique_checkout_nocm boutique_currency_nocm \
        boutique_email_nocm boutique_payment_nocm boutique_product_catalog_nocm \
        boutique_recommendations_nocm boutique_shipping_nocm boutique_frontend_nocm \
        boutique_cart_flame boutique_checkout_flame boutique_currency_flame \
        boutique_email_flame boutique_payment_flame boutique_product_catalog_flame \
        boutique_recommendations_flame boutique_shipping_flame boutique_frontend_flame \
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

stop_boutique
rm -f "$FLAME_READY_DIR"/flame_*.ready
rm -f /dev/shm/fe_* /dev/shm/co_* /dev/shm/rec_* /dev/shm/search_* /dev/shm/hop*

CHANNELS="fe_currency fe_cart fe_productcatalog fe_checkout \
co_productcatalog co_currency co_cart co_shipping co_payment co_email \
rec_productcatalog"

if [[ "$MODE" == "flame" ]]; then
    log "Starting flame daemons (11 bidirectional channels)..."
    for ch in $CHANNELS; do start_daemon "$ch"; done
    for ch in $CHANNELS; do wait_file "$FLAME_READY_DIR/flame_${ch}.ready" "daemon_${ch}"; done
fi

SUFFIX="nocm"
[[ "$MODE" == "flame" ]] && SUFFIX="flame"

log "Starting boutique services (mode=$MODE, redis=$REDIS_ADDR)..."

# Leaves
env PORT=4101 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="cart" \
    FLAME_UPSTREAMS="fe_cart,co_cart" \
    "$BIN/boutique_cart_${SUFFIX}" > "$LOGS/cart.log" 2>&1 &

env PORT=4103 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="currency" \
    FLAME_UPSTREAMS="fe_currency,co_currency" \
    "$BIN/boutique_currency_${SUFFIX}" > "$LOGS/currency.log" 2>&1 &

env PORT=4104 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="email" \
    FLAME_UPSTREAM="co_email" \
    "$BIN/boutique_email_${SUFFIX}" > "$LOGS/email.log" 2>&1 &

env PORT=4105 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="payment" \
    FLAME_UPSTREAM="co_payment" \
    "$BIN/boutique_payment_${SUFFIX}" > "$LOGS/payment.log" 2>&1 &

env PORT=4106 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="productcatalog" \
    FLAME_UPSTREAMS="fe_productcatalog,co_productcatalog,rec_productcatalog" \
    "$BIN/boutique_product_catalog_${SUFFIX}" > "$LOGS/product_catalog.log" 2>&1 &

env PORT=4108 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="shipping" \
    FLAME_UPSTREAM="co_shipping" \
    "$BIN/boutique_shipping_${SUFFIX}" > "$LOGS/shipping.log" 2>&1 &

env PORT=4107 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="recommendations" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/boutique_recommendations.txt" \
    "$BIN/boutique_recommendations_${SUFFIX}" > "$LOGS/recommendations.log" 2>&1 &

env PORT=4102 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="checkout" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_UPSTREAM="fe_checkout" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/boutique_checkout.txt" \
    "$BIN/boutique_checkout_${SUFFIX}" > "$LOGS/checkout.log" 2>&1 &

env PORT=4100 REDIS_URL="$REDIS_ADDR" APP_NAME_NO_UNDERSCORES="frontend" \
    SERVICE_URLS_FILE="$SVC_URL_FILE" \
    FLAME_CHANNELS_FILE="$REPO_ROOT/experiments/local_flame/boutique_frontend.txt" \
    "$BIN/boutique_frontend_${SUFFIX}" > "$LOGS/frontend.log" 2>&1 &

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

log "All boutique services up on N1 (mode=$MODE). frontend = http://$N1_PUBLIC_IP:4100"
