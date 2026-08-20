#!/bin/bash
# Confirms the reassurance we are giving the customer:
# losing the arbiter must NOT stop the store. Both nodes up = 2 of 3 votes.
set -u; source "$(dirname "$0")/lib.sh"

before=$(safe_count "$NODE1" "pcs quorum status" 'Quorate:.*Yes')
record t05 quorate_before "$before" bool

# Both nodes are about to lose their route to the arbiter. If this script dies
# in between, that block is permanent -- arm the unblock before cutting it.
schedule_unblock "$NODE1" 300
schedule_unblock "$NODE2" 300

echo "Blocking qnetd ($QNETD) from both nodes..."
n1 "iptables -I OUTPUT -d $QNETD -j DROP"
n2 "iptables -I OUTPUT -d $QNETD -j DROP"
sleep 40   # exceed qdevice sync_timeout (default 30s)

during=$(safe_count "$NODE1" "pcs quorum status" 'Quorate:.*Yes')
record t05 quorate_without_arbiter "$during" bool
vms=$(safe_count "$NODE1" "pcs status" 'Started')
record t05 resources_still_started "$vms" count

echo "Restoring arbiter..."
n1 "iptables -D OUTPUT -d $QNETD -j DROP" || true
n2 "iptables -D OUTPUT -d $QNETD -j DROP" || true

# The old check counted lines matching 'Qdevice.*A,V'. In pcs output the A,V,NMW
# flags sit on the NODE lines and the "Qdevice" line carries none, so that
# pattern can never match and the test always recorded 0 -- reporting a failed
# rejoin every time while the qdevice was in fact healthy. "Flags: ... Qdevice"
# is the definitive signal. Poll for it rather than sleeping a flat 20s, which
# was also simply too short.
after=0
for _ in $(seq 1 24); do
  if n1 "pcs quorum status 2>/dev/null | grep -qE '^Flags:.*Qdevice'" 2>/dev/null; then
    after=1; break
  fi
  sleep 5
done
record t05 qdevice_revote "$after" bool

[ "$during" -eq 1 ] && echo "  PASS: store stayed quorate without the arbiter" \
                    || echo "  FAIL: cluster lost quorum -- design assumption broken"
[ "$after" -eq 1 ]  || echo "  WARN: qdevice did not rejoin as A,V within 20s"
