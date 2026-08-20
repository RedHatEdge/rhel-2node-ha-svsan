#!/bin/bash
# Hard node loss — the real failure case, not a graceful standby.
# Fences node2 and measures how long until its workload is running on node1.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

VICTIM=${VICTIM:-$N2NAME}
VICTIM_IP=${VICTIM_IP:-$NODE2}
WATCH=${WATCH:-vm-pgsql}

before=$(resource_node "$WATCH")
info "$WATCH currently on ${before:-unknown}; fencing $VICTIM"

start=$(now_ms)
n1 "pcs stonith fence $VICTIM" >/dev/null 2>&1 || fail "fence command returned non-zero"

# Fence completion: victim stops answering.
while node_up "$VICTIM_IP"; do
  [ $(( $(now_ms) - start )) -gt 120000 ] && { fail "victim still up after 120s"; break; }
  sleep 1
done
fenced=$(now_ms)
record t03 fence_time $(( fenced - start )) ms

if wait_started "$WATCH" 300; then
  record t03 total_rto $(( $(now_ms) - start )) ms
  after=$(resource_node "$WATCH")
  [ "$after" != "$before" ] && pass "$WATCH relocated to $after" || fail "$WATCH did not relocate"
else
  fail "$WATCH did not restart within 300s"
fi

info "waiting for $VICTIM to rejoin"
if wait_node_up "$VICTIM_IP" 600; then
  record t03 node_rejoin $(( $(now_ms) - start )) ms
  wait_settled
  pass "$VICTIM back in the cluster"
else
  fail "$VICTIM did not come back — may need manual power-on"
fi
