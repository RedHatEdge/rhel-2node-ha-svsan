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
    n2 "drbdadm connect $RES"
    until n1 "drbdadm status $RES" | grep -q 'peer-disk:UpToDate'; do sleep 5; done
    record t04 reconnect_resync $(( $(now_ms) - start )) ms
    n1 "drbdadm status $RES" | grep -qi 'split-brain' \
      && fail "SPLIT BRAIN detected" || pass "no split brain after reconnect"
    ;;
  svsan)
    info "stopping the VSA on node2 — node2 must keep reaching storage via node1's VSA"
    start=$(now_ms)
    n2 "virsh destroy svsan-vsa"
    sleep 15
    n2 "dd if=/dev/mapper/pgsql of=/dev/null bs=4k count=1 iflag=direct" 2>/dev/null \
      && pass "node2 still reaching storage through the peer VSA" \
      || fail "node2 lost storage when its local VSA died"
    resource_started vm-pgsql && pass "guest survived local VSA loss" \
                              || fail "guest stopped"
    info "restarting the VSA"
    n2 "virsh start svsan-vsa"
    sleep 60
    record t04 vsa_recovery $(( $(now_ms) - start )) ms
    ;;
  *)
    echo "  SKIPPED — no storage backend detected"; exit 0 ;;
esac
