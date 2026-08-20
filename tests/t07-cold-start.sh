#!/bin/bash
# Cold start from full power loss. Retail sites lose power; the whole boot
# ordering chain has to hold unattended, thousands of times.
#
# For Option A this is the sharpest test of the bootstrap chain:
#   local storage -> VSA -> mirror quorum w/ witness -> iscsid -> multipath -> guests
# If the readiness gate is wrong, guests try to start before storage exists.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

info "powering both nodes off"
poweroff_both() {
  if [ "${FENCE:-}" = "redfish" ]; then
    n1 "pcs stonith fence $N2NAME --off" >/dev/null 2>&1 || true
    on "$NODE2" "true" 2>/dev/null && info "node2 still up; issuing local poweroff"
    n2 "systemctl poweroff" >/dev/null 2>&1 || true
    n1 "systemctl poweroff" >/dev/null 2>&1 || true
  else
    n2 "systemctl poweroff" >/dev/null 2>&1 || true
    n1 "systemctl poweroff" >/dev/null 2>&1 || true
  fi
}
poweroff_both

for _ in $(seq 1 60); do
  node_up "$NODE1" || node_up "$NODE2" || break
  sleep 5
done
info "both nodes down"

echo
echo "  >>> Power both nodes back on now (BMC, PDU, or physically)."
echo "  >>> Timing starts when the first node answers."
echo

# Wait for the first node to come back, then start the clock.
while ! node_up "$NODE1" && ! node_up "$NODE2"; do sleep 5; done
start=$(now_ms)
info "first node responding — timing to service"

wait_node_up "$NODE1" 900 || fail "node1 did not return"
wait_node_up "$NODE2" 900 || fail "node2 did not return"
record t07 both_nodes_up $(( $(now_ms) - start )) ms

# Storage layer must come up before Pacemaker will start guests.
case "$BACKEND" in
  drbd)
    until n1 "drbdadm status store-a 2>/dev/null | grep -q 'disk:UpToDate'"; do
      [ $(( $(now_ms) - start )) -gt 900000 ] && { fail "DRBD not UpToDate after 15m"; break; }
      sleep 5
    done ;;
  svsan)
    until n1 "test -b /dev/mapper/pos"; do
      [ $(( $(now_ms) - start )) -gt 900000 ] && { fail "LUNs never appeared after 15m"; break; }
      sleep 5
    done ;;
esac
record t07 storage_ready $(( $(now_ms) - start )) ms

if wait_started vm-pos 900 && wait_started vm-pgsql 900; then
  record t07 time_to_service $(( $(now_ms) - start )) ms
  pass "site returned to service unattended"
else
  fail "guests did not start — check boot ordering"
fi

q=$(n1 "pcs quorum status 2>/dev/null | grep -c 'Quorate:.*Yes'" || echo 0)
record t07 quorate_after_cold_start "$q" bool
wait_settled
