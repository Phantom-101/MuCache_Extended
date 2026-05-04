#!/bin/bash
# Start Redis on Node 2 (the backend tier).
# Bound to 0.0.0.0 so services on Node 1 can reach it via $N2_INTERNAL_IP.
#
# Run on Node 0; SSHes to N2.
#   bash scripts/distributed/start_redis_N2.sh
set -e
source "$(dirname "$0")/env.sh"

log "Starting Redis on N2 ($NODE2_HOST, $N2_INTERNAL_IP:$REDIS_PORT)..."

ssh_n2 "
    pgrep -u \$USER -x redis-server >/dev/null && pkill -u \$USER -x redis-server || true
    sleep 1
    redis-server \
        --bind 0.0.0.0 \
        --port $REDIS_PORT \
        --protected-mode no \
        --daemonize yes \
        --logfile /tmp/redis_n2.log
    for i in \$(seq 1 30); do
        redis-cli -h 127.0.0.1 -p $REDIS_PORT ping >/dev/null 2>&1 && break
        sleep 0.2
    done
    redis-cli -h 127.0.0.1 -p $REDIS_PORT flushall >/dev/null
    echo 'redis up on N2 ('\$(hostname)')'
"
log "N2 redis listening at $REDIS_ADDR"
