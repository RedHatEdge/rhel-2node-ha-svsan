#!/bin/bash
# The synchronous mirroring tax. Every write waits for the second copy, so this
# lands directly in POS response time and Postgres commit latency.
#
# Measured INSIDE the guest, deliberately. The appliance presents a raw iSCSI LUN
# that a running guest already owns, so there is no host-side filesystem to probe
# — and writing to the raw LUN to benchmark it would corrupt that guest's disk.
# The guest's own view is the honest measurement, and it is what the workload
# actually experiences.
set -u; source "$(dirname "$0")/lib.sh"

DOM=${DOM:-pos}
COUNT=${COUNT:-16384}   # 4k blocks -> 64MB
GUEST=${GUEST:-$(guest_ip "$DOM" || true)}
[ -n "$GUEST" ] || { echo "  SKIPPED — cannot find the $DOM guest"; exit 0; }
info "probing inside guest $DOM at $GUEST (backend: $BACKEND)"

probe() {  # probe <path>
  ssh $ssh_opts -o BatchMode=yes "$GUESTUSER@$GUEST" \
    "dd if=/dev/zero of=$1 bs=4k count=$COUNT oflag=direct,dsync 2>&1 | tail -2; rm -f $1" 2>/dev/null
}

out=$(probe /var/tmp/.latency-probe)
bw=$(dd_rate_mbs "$out"); secs=$(dd_seconds "$out")

if [ -z "$bw" ] || [ -z "$secs" ]; then
  echo "  ERROR: could not parse dd output -- not recording a misleading zero"
  echo "  $out"
  exit 1
fi

record t11 guest_sync_write "$bw" MB/s
record t11 per_write_latency \
  "$(awk -v s="$secs" -v c="$COUNT" 'BEGIN{printf "%.3f", (s*1000)/c}')" ms
info "$COUNT x 4k O_DIRECT|O_DSYNC writes through the full stack"
