#!/bin/bash
# Shared configuration for the 3-node distributed benchmark.
#
# Topology:
#   Node 0 — this host. Runs the orchestrator (`run_*.sh`, `sweep_*.sh`)
#            and the load generator (oha). Talks to N1's frontend over TCP.
#   Node 1 — microservice tier. All services + flame daemons run here.
#            HTTP-baseline traffic and shared-memory RPC are local to N1.
#   Node 2 — Redis backend. All services on N1 read/write Redis on N2.
#
# Source this from every distributed script:
#     source "$(dirname "$0")/env.sh"
#
# Override any variable by exporting it before invoking a script:
#     N1_HOST=foo NODE2_HOST=bar bash scripts/distributed/run_chain.sh flame

# ── Hosts ─────────────────────────────────────────────────────────────────────
export NODE1_HOST="${NODE1_HOST:-c220g5-111311.wisc.cloudlab.us}"   # services
export NODE2_HOST="${NODE2_HOST:-c220g5-111306.wisc.cloudlab.us}"   # redis
export SSH_USER="${SSH_USER:-$USER}"

# ── IPs ───────────────────────────────────────────────────────────────────────
# N0→N1 traffic goes over the public/control network (these nodes are in a
# different CloudLab project from N0 in our setup). N1→N2 traffic should
# use the experiment network (10.10.1.x) for low-latency, high-bandwidth.
#
# Override these to use whatever network you actually have.
export N1_PUBLIC_IP="${N1_PUBLIC_IP:-$(getent hosts "$NODE1_HOST" | awk '{print $1}' | head -1)}"
export N2_INTERNAL_IP="${N2_INTERNAL_IP:-10.10.1.3}"   # N2 on experiment net (set after probing)

# ── Paths (assumed identical on N1 and N2) ────────────────────────────────────
export REPO_ROOT="${REPO_ROOT:-/mydata/MuCache_Extended}"
export FLAME_BIN="${FLAME_BIN:-/mydata/flame-benchmark/bin/flame_daemon}"

# ── Redis ─────────────────────────────────────────────────────────────────────
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_ADDR="${N2_INTERNAL_IP}:${REDIS_PORT}"   # what N1 services dial

# ── Default benchmark parameters ──────────────────────────────────────────────
export N_REQUESTS="${N_REQUESTS:-3000}"
export CONCURRENCY="${CONCURRENCY:-20}"
export WAIT_SECS="${WAIT_SECS:-5}"

# ── SSH helpers ───────────────────────────────────────────────────────────────
export SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ConnectTimeout=10}"

ssh_n1() { ssh $SSH_OPTS "$SSH_USER@$NODE1_HOST" "$@"; }
ssh_n2() { ssh $SSH_OPTS "$SSH_USER@$NODE2_HOST" "$@"; }

rsync_to_n1() {
    rsync -az --delete \
        -e "ssh $SSH_OPTS" \
        --exclude='.git' --exclude='logs' --exclude='latency_results' --exclude='results' \
        "$REPO_ROOT/" "$SSH_USER@$NODE1_HOST:$REPO_ROOT/"
}

log() { echo "[dist $(date +%H:%M:%S)] $*"; }
