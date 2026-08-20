#!/bin/bash
# The synchronous mirroring tax. Every write waits for the second copy, so this
# lands directly in POS response time and Postgres commit latency.
set -u; source "$(dirname "$0")/lib.sh"

case "$BACKEND" in
  drbd|svsan) MNT=${MNT:-/var/store-a} ;;
  *) echo "  SKIPPED — no backend detected"; exit 0 ;;
esac
TARGET="$MNT/.latency-probe"
LOCAL=/var/tmp/.latency-probe
COUNT=${COUNT:-16384}   # 4k blocks -> 64MB

# The replicated filesystem is mounted on exactly one node, and it is not
# necessarily node1. Probing the wrong node measures a path that does not exist
# and silently reports zero, so find the node that actually has it mounted.
HOST=""
for h in "$NODE1" "$NODE2"; do
  on "$h" "mountpoint -q $MNT" 2>/dev/null && { HOST=$h; break; }
done
[ -n "$HOST" ] || { echo "  SKIPPED — $MNT is not mounted on either node"; exit 0; }
info "$MNT is mounted on $HOST"

probe() {  # probe <host> <path> -> raw dd stderr
  on "$1" "dd if=/dev/zero of=$2 bs=4k count=$COUNT oflag=direct,dsync 2>&1 | tail -2"
}

info "measuring replicated volume"
rep=$(probe "$HOST" "$TARGET")
rep_bw=$(dd_rate_mbs "$rep"); rep_s=$(dd_seconds "$rep")

info "measuring node-local disk on the same host for comparison"
loc=$(probe "$HOST" "$LOCAL")
loc_bw=$(dd_rate_mbs "$loc")

on "$HOST" "rm -f $TARGET $LOCAL" >/dev/null 2>&1 || true

if [ -z "$rep_bw" ] || [ -z "$loc_bw" ]; then
  echo "  ERROR: could not parse dd output -- not recording a misleading zero"
  echo "  replicated: $rep"
  echo "  local     : $loc"
  exit 1
fi

record t11 replicated_sync_write "$rep_bw" MB/s
record t11 local_sync_write      "$loc_bw" MB/s
[ -n "$rep_s" ] && record t11 per_write_latency \
  "$(awk -v s="$rep_s" -v c="$COUNT" 'BEGIN{printf "%.3f", (s*1000)/c}')" ms

# The "replication tax" is only a real number if both probes hit the same
# physical disk. The replicated volume sits on the NVMe the backing LV is on,
# while /var/tmp is on the OS disk -- comparing those measures the difference
# between two devices, not the cost of replication, and can even come out
# negative. Emit the percentage only when the comparison is actually valid.
phys_of() {  # phys_of <host> <path> -> parent physical device
  on "$1" "findmnt -no SOURCE --target $2 2>/dev/null" 2>/dev/null | head -1 \
    | xargs -r -I{} sh -c "lsblk -nso PKNAME {} 2>/dev/null | tail -1"
}
rep_disk=$(on "$HOST" "drbdadm sh-ll-dev ${MNT##*/} 2>/dev/null" 2>/dev/null | head -1)
[ -n "$rep_disk" ] && rep_disk=$(on "$HOST" "lsblk -nso PKNAME $rep_disk 2>/dev/null | tail -1" 2>/dev/null)
loc_disk=$(phys_of "$HOST" "$LOCAL")
info "replicated volume on ${rep_disk:-unknown}, local probe on ${loc_disk:-unknown}"

if [ -n "$rep_disk" ] && [ "$rep_disk" = "$loc_disk" ]; then
  record t11 replication_overhead_pct \
    "$(awk -v r="$rep_bw" -v l="$loc_bw" 'BEGIN{ if (l>0) printf "%.1f", (1-r/l)*100; else print "0" }')" pct
else
  echo "  NOTE: probes are on different physical disks (${rep_disk:-?} vs ${loc_disk:-?})."
  echo "        Not recording an overhead percentage -- it would not mean what it says."
fi
