#!/bin/bash
# Resync throughput directly sets the migration no-redundancy window, which
# sets the achievable stores-per-day rate. This number drives the schedule.
set -u; source "$(dirname "$0")/lib.sh"

RES=${RES:-store-a}
echo "Disconnecting and invalidating $RES on node2 to force a full resync..."
n2 "drbdadm disconnect $RES; drbdadm invalidate $RES; drbdadm connect $RES"

start=$(now_ms)
while true; do
  out=$(n2 "drbdadm status $RES" 2>/dev/null || true)
  echo "$out" | grep -q 'peer-disk:UpToDate' && break
  echo "$out" | grep -oP 'done:\K[0-9.]+' | tail -1
  sleep 10
done
end=$(now_ms)

secs=$(( (end - start) / 1000 ))
size_mb=$(n2 "blockdev --getsize64 /dev/drbd0" | awk '{print int($1/1048576)}')
record t08 resync_seconds "$secs" s
record t08 resync_size "$size_mb" MB
[ "$secs" -gt 0 ] && record t08 resync_throughput $(( size_mb / secs )) MB/s
