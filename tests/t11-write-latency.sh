#!/bin/bash
# The synchronous mirroring tax. Every write waits for the second copy, so this
# lands directly in POS response time and Postgres commit latency.
set -u; source "$(dirname "$0")/lib.sh"

case "$BACKEND" in
  drbd)  TARGET=${TARGET:-/var/store-a/.latency-probe} ;;
  svsan) TARGET=${TARGET:-/var/store-a/.latency-probe} ;;
  *)     echo "  SKIPPED — no backend detected"; exit 0 ;;
esac
LOCAL=/var/tmp/.latency-probe

probe() {  # probe <path> -> writes 64MB with O_DIRECT|O_DSYNC, prints MB/s
  n1 "dd if=/dev/zero of=$1 bs=4k count=16384 oflag=direct,dsync 2>&1 | tail -1"
}

info "measuring replicated volume"
rep=$(probe "$TARGET")
rep_bw=$(echo "$rep" | grep -oP '[0-9.]+(?= MB/s)' | tail -1)
rep_s=$(echo "$rep"  | grep -oP '[0-9.]+(?= s,)' | tail -1)

info "measuring node-local disk for comparison"
loc=$(probe "$LOCAL")
loc_bw=$(echo "$loc" | grep -oP '[0-9.]+(?= MB/s)' | tail -1)

n1 "rm -f $TARGET $LOCAL" 2>/dev/null || true

record t11 replicated_sync_write "${rep_bw:-0}" MB/s
record t11 local_sync_write "${loc_bw:-0}" MB/s
[ -n "${rep_s:-}" ] && record t11 per_write_latency \
  "$(awk -v s="$rep_s" 'BEGIN{printf "%.3f", (s*1000)/16384}')" ms

if [ -n "${rep_bw:-}" ] && [ -n "${loc_bw:-}" ]; then
  record t11 replication_overhead_pct \
    "$(awk -v r="$rep_bw" -v l="$loc_bw" 'BEGIN{printf "%.1f", (1-r/l)*100}')" pct
fi
