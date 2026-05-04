#!/bin/bash
# Sync the working tree and prebuilt binaries from Node 0 to Node 1.
# Skips .git, logs, and latency_results.
#
# Usage on N0:   bash scripts/distributed/sync_to_N1.sh
set -e
source "$(dirname "$0")/env.sh"

log "Syncing $REPO_ROOT → $SSH_USER@$NODE1_HOST:$REPO_ROOT ..."
ssh_n1 "mkdir -p $REPO_ROOT"
rsync_to_n1
log "Repo sync done."

log "Verifying binaries on N1..."
ssh_n1 "ls $REPO_ROOT/bin | grep -E '(chain|hotel|boutique)_.*_(flame|nocm)' | wc -l"
log "If the count looks wrong, run 'go build' on N1 or re-sync."
