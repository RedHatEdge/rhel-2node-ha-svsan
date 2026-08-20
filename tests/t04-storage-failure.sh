#!/bin/bash
# Losing half the storage while both nodes stay up.
# The site must keep serving from the surviving copy.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

case "$BACKEND" in
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
