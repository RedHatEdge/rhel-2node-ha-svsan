#!/bin/bash
# Losing half the storage while both nodes stay up.
# The site must keep serving from the surviving copy.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

case "$BACKEND" in
  drbd)
    RES=${RES:-store-b}
    info "disconnecting DRBD replication for $RES on node2"
    start=$(now_ms)
    n2 "drbdadm disconnect $RES"
    sleep 10
    n1 "drbdadm status $RES" | grep -q 'connection:Connecting\|connection:StandAlone' \
      && pass "peer disconnected as expected" || fail "unexpected connection state"
    resource_started vm-pgsql && pass "guest still running on the surviving copy" \
                              || fail "guest stopped when the peer went away"
    info "reconnecting"
    rstart=$(now_ms)
    n2 "drbdadm connect $RES"
    # Bounded: an unbounded until-loop here turns a failed resync into a run
    # that hangs until someone kills it.
    if wait_for 1800 "$NODE1" "drbdadm status $RES 2>/dev/null | grep -q peer-disk:UpToDate"; then
      # Timed from the reconnect, not from the disconnect -- the old version
      # included the outage window and the fixed sleep in a figure labelled
      # "resync".
      record t04 reconnect_resync $(( $(now_ms) - rstart )) ms
      pass "replicas back in sync"
    else
      fail "replicas did not return to UpToDate within 30 minutes"
    fi

    # `drbdadm status` does not print "split-brain"; it shows StandAlone and the
    # detection is logged by the kernel. Grepping status for the phrase always
    # passed, so it was never actually testing for split brain.
    sb=$(n1 "dmesg 2>/dev/null | grep -ci 'split.brain'" 2>/dev/null | tr -d '[:space:]')
    conn=$(n1 "drbdadm status $RES 2>/dev/null" 2>/dev/null | grep -c 'connection:StandAlone' | tr -d '[:space:]')
    if [ "${sb:-0}" -gt 0 ] || [ "${conn:-0}" -gt 0 ]; then
      fail "SPLIT BRAIN indicated (dmesg matches: ${sb:-0}, StandAlone: ${conn:-0})"
      record t04 split_brain 1 bool
    else
      pass "no split brain after reconnect"
      record t04 split_brain 0 bool
    fi
    ;;
  svsan)
    info "stopping the VSA on node2 — node2 must keep reaching storage via node1's VSA"
    start=$(now_ms)
    VSA=$(svsan_domain "$NODE2")
    [ -n "$VSA" ] || { fail "no svsan-* domain found on node2"; exit 1; }
    info "stopping $VSA on node2"
    n2 "virsh destroy $VSA"
    sleep 15
    n2 "dd if=/dev/mapper/pgsql of=/dev/null bs=4k count=1 iflag=direct" 2>/dev/null \
      && pass "node2 still reaching storage through the peer VSA" \
      || fail "node2 lost storage when its local VSA died"
    resource_started vm-pgsql && pass "guest survived local VSA loss" \
                              || fail "guest stopped"
    info "restarting the VSA"
    n2 "virsh start $VSA"
    sleep 60
    record t04 vsa_recovery $(( $(now_ms) - start )) ms
    ;;
  *)
    echo "  SKIPPED — no storage backend detected"; exit 0 ;;
esac
