#!/bin/bash
# Sanity-check connectivity and paths before running the real benchmarks.
# Execute on Node 0 (this host).
source "$(dirname "$0")/env.sh"

pass=1
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  [ok]   $label"
    else
        echo "  [FAIL] $label"
        pass=0
    fi
}

echo "Configuration:"
echo "  N0 (this host)  = $(hostname)"
echo "  N1 (services)   = $NODE1_HOST  ($N1_PUBLIC_IP)"
echo "  N2 (redis)      = $NODE2_HOST  ($N2_INTERNAL_IP)"
echo "  SSH_USER        = $SSH_USER"
echo "  REPO_ROOT       = $REPO_ROOT"
echo "  FLAME_BIN       = $FLAME_BIN"
echo "  REDIS_ADDR      = $REDIS_ADDR  (N1 will dial this)"
echo ""

echo "N0-side (this host):"
check "repo present on N0"             test -d "$REPO_ROOT"
check "oha installed"                  command -v oha
check "curl installed"                 command -v curl

echo ""
echo "N1-side (services, via ssh):"
check "ssh to N1 (BatchMode)"          ssh_n1 "true"
check "repo present on N1"             ssh_n1 "test -d $REPO_ROOT"
check "bin/chain_service1_nocm  on N1" ssh_n1 "test -x $REPO_ROOT/bin/chain_service1_nocm"
check "bin/chain_service1_flame on N1" ssh_n1 "test -x $REPO_ROOT/bin/chain_service1_flame"
check "flame_daemon on N1"             ssh_n1 "test -x $FLAME_BIN"

echo ""
echo "N2-side (redis, via ssh):"
check "ssh to N2 (BatchMode)"          ssh_n2 "true"
check "redis-server on N2"             ssh_n2 "command -v redis-server"

echo ""
echo "Network:"
check "N0 → N1 reachable"              ping -c1 -W2 "$N1_PUBLIC_IP"
check "N1 → N2 reachable ($N2_INTERNAL_IP)"  ssh_n1 "ping -c1 -W2 $N2_INTERNAL_IP"

echo ""
if [[ "$pass" == "1" ]]; then
    log "ALL CHECKS PASSED — ready to run benchmarks."
    exit 0
else
    log "Some checks failed — fix above before running benchmarks."
    exit 1
fi
