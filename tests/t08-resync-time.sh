#!/bin/bash
# Resync throughput directly sets the migration no-redundancy window, which
# sets the achievable stores-per-day rate. This number drives the schedule.
set -u; source "$(dirname "$0")/lib.sh"

[ "$BACKEND" = drbd ] || { echo "  SKIPPED — resync test is DRBD-specific"; exit 0; }
require_confirm

RES=${RES:-store-a}

# Ask DRBD for the device rather than assuming /dev/drbd0 -- the minor number
# depends on declaration order, so store-b on a two-resource host is drbd1.
DEV=$(n2 "drbdadm sh-dev $RES" 2>/dev/null | head -1)
[ -n "$DEV" ] || { echo "  ERROR: cannot resolve device for $RES"; exit 1; }

echo "Disconnecting and invalidating $RES on node2 to force a full resync..."
n2 "drbdadm disconnect $RES; drbdadm invalidate $RES; drbdadm connect $RES"

# Wait for the resync to actually BEGIN before starting the clock. Immediately
# after connect, status can still carry the pre-invalidate peer-disk:UpToDate
# line; the previous version matched that and reported a resync of a few
# seconds at an impossible throughput. Time the sync, not the race.
started=0
for _ in $(seq 1 60); do
  if n2 "drbdadm status $RES" 2>/dev/null \
       | grep -qE 'replication:Sync(Target|Source)|peer-disk:Inconsistent'; then
    started=1; break
  fi
  sleep 1
done
[ "$started" = 1 ] || { echo "  ERROR: resync never started -- nothing to measure"; exit 1; }

start=$(now_ms)
# Bounded. A full 430GB resync runs about 25 minutes, so 90 minutes is generous
# while still guaranteeing the run ends rather than hanging until killed.
deadline=$(( $(date +%s) + 5400 ))
done_ok=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  out=$(n2 "drbdadm status $RES" 2>/dev/null || true)
  if ! echo "$out" | grep -qE 'replication:Sync(Target|Source)'; then
    echo "$out" | grep -q 'peer-disk:UpToDate' && { done_ok=1; break; }
  fi
  pct=$(echo "$out" | grep -oP 'done:\K[0-9.]+' | tail -1)
  [ -n "$pct" ] && echo "    ${pct}%"
  sleep 10
done
end=$(now_ms)
[ "$done_ok" = 1 ] || { echo "  ERROR: resync did not finish within 90 minutes"; exit 1; }

secs=$(( (end - start) / 1000 ))
size_mb=$(n2 "blockdev --getsize64 $DEV" 2>/dev/null | awk '{print int($1/1048576)}')
record t08 resync_seconds "$secs" s
record t08 resync_size "$size_mb" MB
if [ "$secs" -gt 0 ] && [ -n "$size_mb" ]; then
  record t08 resync_throughput $(( size_mb / secs )) MB/s
else
  echo "  WARN: resync completed under 1s -- throughput not meaningful"
fi
