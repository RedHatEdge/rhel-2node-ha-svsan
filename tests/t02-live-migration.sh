#!/bin/bash
# THE decisive test for Option B.
#
# They have vMotion today. Shared storage (Option A) gives live migration for
# free. Single-primary DRBD (Option B) mounts the replicated filesystem on ONE
# node at a time, so the target cannot see the guest's disk and libvirt refuses
# the migration outright. Prove which case we are in, and do not report a
# migration time for a migration that did not happen.
set -u; source "$(dirname "$0")/lib.sh"

VM=${VM:-vm-pos}
DOM=${DOM:-${VM#vm-}}

from=$(rsc_node "$VM")
[ -n "$from" ] || { echo "  ERROR: $VM is not Started anywhere"; exit 1; }
TARGET=${TARGET:-$([ "$from" = "$N1NAME" ] && echo "$N2NAME" || echo "$N1NAME")}

VMIP=${VMIP:-$(guest_ip "$DOM" || true)}
before_boot=""
[ -n "$VMIP" ] && before_boot=$(guest_bootid "$VMIP")

echo "Migrating $VM: $from -> $TARGET"
[ -n "$VMIP" ] && info "guest $DOM at $VMIP (boot id ${before_boot:0:8}...)" \
               || info "guest address unknown -- downtime will not be sampled"

# Sample reachability every 100ms for the whole move.
PINGLOG=/tmp/t02-ping.log
PINGER=""
if [ -n "$VMIP" ]; then
  : > "$PINGLOG"
  # Stamp every probe. A FAILED ping costs ~1s (-W1) while a successful one
  # returns in ~1ms, so samples are NOT evenly spaced and counting them at a
  # fixed 100ms understates an outage by roughly 10x. Timestamps make the
  # measurement independent of how long each probe took.
  ( while :; do
      printf '%s %s\n' "$(( $(date +%s%N) / 1000000 ))" \
        "$(vm_reachable "$VMIP" && echo 1 || echo 0)"
      sleep 0.1
    done ) > "$PINGLOG" 2>/dev/null &
  PINGER=$!
fi

start=$(now_ms)
n1 "pcs resource move $VM $TARGET" >/dev/null 2>&1
wait_settled
wait_started "$VM" 300 || true

# Pacemaker reporting "Started" only means the domain launched. If the move was
# cold, the guest is still booting and the store is still down -- stopping the
# clock here understates the outage by the whole boot time. Wait for the guest
# itself to answer, and require several consecutive replies so a single stray
# ICMP response does not end the measurement early.
if [ -n "$VMIP" ]; then
  deadline=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ups=$(tail -5 "$PINGLOG" 2>/dev/null | awk '$2=="1"' | wc -l)
    [ "${ups//[^0-9]/}" = "5" ] && break
    sleep 2
  done
fi
end=$(now_ms)

# Did libvirt actually refuse? That is the finding, not a timing number.
refused=$(n1 "journalctl -u pacemaker --since '-5min' --no-pager 2>/dev/null" \
          | grep -ci 'Migration without shared storage is unsafe' || true)
refused=${refused//[^0-9]/}; refused=${refused:-0}
migrate_failed=$(n1 "pcs status --full 2>/dev/null" \
                 | grep -c "${VM}_migrate_to_0.*error" || true)
migrate_failed=${migrate_failed//[^0-9]/}; migrate_failed=${migrate_failed:-0}

[ -n "$PINGER" ] && { kill "$PINGER" 2>/dev/null; wait "$PINGER" 2>/dev/null; }

after=$(rsc_node "$VM")
after_boot=""
[ -n "$VMIP" ] && after_boot=$(guest_bootid "$VMIP")

if [ "$refused" -gt 0 ] || [ "$migrate_failed" -gt 0 ]; then
  echo "  FINDING: libvirt refused live migration -- the target cannot see the disk."
  echo "           Single-primary DRBD mounts the filesystem on one node only."
  record t02 live_migration_supported 0 bool
else
  record t02 live_migration_supported 1 bool
fi

# Boot id is the ground truth: unchanged means the guest never restarted.
if [ -n "$before_boot" ] && [ -n "$after_boot" ]; then
  if [ "$before_boot" = "$after_boot" ]; then
    record t02 guest_restarted 0 bool
    echo "  Guest kept running across the move (boot id unchanged)."
  else
    record t02 guest_restarted 1 bool
    echo "  Guest REBOOTED -- this was a cold move, not a live migration."
  fi
fi

# Only meaningful once we know what actually happened, so record it last.
record t02 move_wall_clock $(( end - start )) ms
echo "  moved: $from -> ${after:-unknown}"

# The outage is the largest gap between two SUCCESSFUL probes -- derived from
# the stamps, not from a sample count, for the reason noted above.
if [ -n "$VMIP" ] && [ -s "$PINGLOG" ]; then
  outage=$(awk '$2=="1" { if (prev != "" && $1-prev > max) max = $1-prev; prev = $1 }
                END { print (max+0) }' "$PINGLOG")
  record t02 guest_outage "$outage" ms
fi

n1 "pcs resource clear $VM" >/dev/null 2>&1 || true
