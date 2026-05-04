#!/bin/bash
# Tear down all microservices and flame daemons on Node 1.
#
# Usage on N1:   bash scripts/distributed/stop_N1.sh
source "$(dirname "$0")/env.sh"

log "Stopping all benchmark processes on N1..."

killall \
    chain_service1_nocm  chain_service2_nocm  chain_service3_nocm \
    chain_service4_nocm  chain_backend_nocm \
    chain_service1_flame chain_service2_flame chain_service3_flame \
    chain_service4_flame chain_backend_flame \
    hotel_frontend_nocm  hotel_search_nocm  hotel_rate_nocm \
    hotel_reservation_nocm hotel_profile_nocm hotel_user_nocm \
    hotel_frontend_flame hotel_search_flame hotel_rate_flame \
    hotel_reservation_flame hotel_profile_flame hotel_user_flame \
    boutique_cart_nocm boutique_checkout_nocm boutique_currency_nocm \
    boutique_email_nocm boutique_payment_nocm boutique_product_catalog_nocm \
    boutique_recommendations_nocm boutique_shipping_nocm boutique_frontend_nocm \
    boutique_cart_flame boutique_checkout_flame boutique_currency_flame \
    boutique_email_flame boutique_payment_flame boutique_product_catalog_flame \
    boutique_recommendations_flame boutique_shipping_flame boutique_frontend_flame \
    flame_daemon \
    2>/dev/null || true

sleep 1
rm -f /dev/shm/hop* /dev/shm/fe_* /dev/shm/search_* /dev/shm/co_* /dev/shm/rec_*
rm -f /tmp/flame_ready/flame_*.ready

log "B torn down."
