#!/bin/bash
# Run all 3 distributed benchmarks × {nocm, flame}. Execute on Node 0.
#
# Usage:    bash scripts/distributed/run_all.sh [benches]  [modes]
# Examples:
#   bash scripts/distributed/run_all.sh                    # all benches, all modes
#   bash scripts/distributed/run_all.sh "chain hotel"      # 2 benches, both modes
#   bash scripts/distributed/run_all.sh "chain" "flame"    # chain + flame only
set -e
source "$(dirname "$0")/env.sh"

BENCHES="${1:-chain hotel boutique}"
MODES="${2:-nocm flame}"

log "Running benchmarks: [$BENCHES] × modes: [$MODES]"
log "  N0=$(hostname)  N1=$NODE1_HOST ($N1_PUBLIC_IP)  N2=$NODE2_HOST ($N2_INTERNAL_IP)"

for bench in $BENCHES; do
    for mode in $MODES; do
        echo ""
        echo "================================================================"
        echo "  $bench / $mode"
        echo "================================================================"
        bash "$(dirname "$0")/run_${bench}.sh" "$mode"
        sleep 2
    done
done

echo ""
log "=== ALL DONE ==="
ls -la "$REPO_ROOT/latency_results/distributed/" 2>/dev/null
