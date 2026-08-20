#!/bin/bash
# THE decisive test for Option B.
#
# They have vMotion today. Shared storage (Option A) gives live migration for
# free. Single-primary DRBD (Option B) needs transient allow-two-primaries --
# if that cannot be made reliable, VM moves are cold and it is a visible
# regression. Prove it here, early.
set -u; source "$(dirname "$0")/lib.sh"

VM=${VM:-vm-pos}
TARGET=${TARGET:-$(n1 "crm_mon -1 | grep -q '$VM.*node1' && echo node2 || echo node1")}
VMIP=${VMIP:-}

echo "Migrating $VM -> $TARGET"

# Sample reachability every 100ms across the migration to catch the pause.
if [ -n "$VMIP" ]; then
  ( for _ in $(seq 1 600); do
      vm_reachable "$VMIP" && echo 1 || echo 0
      sleep 0.1
    done ) > /tmp/t02-ping.log &
  PINGER=$!
fi

start=$(now_ms)
n1 "pcs resource move $VM $TARGET"
wait_settled
end=$(now_ms)
record t02 migration_wall_clock $(( end - start )) ms

if [ -n "$VMIP" ]; then
  wait $PINGER 2>/dev/null || true
  drops=$(grep -c '^0$' /tmp/t02-ping.log || echo 0)
  record t02 guest_unreachable $(( drops * 100 )) ms
  if [ "$drops" -eq 0 ]; then
    record t02 live_migration 1 bool_true
  else
    record t02 live_migration 0 bool_false
  fi
fi

n1 "pcs resource clear $VM"
