#!/bin/bash
# Confirms the reassurance we are giving the customer:
# losing the arbiter must NOT stop the store. Both nodes up = 2 of 3 votes.
set -u; source "$(dirname "$0")/lib.sh"

before=$(n1 "pcs quorum status | grep -c 'Quorate:.*Yes'")
record t05 quorate_before "$before" bool

echo "Blocking qnetd ($QNETD) from both nodes..."
n1 "iptables -I OUTPUT -d $QNETD -j DROP"
n2 "iptables -I OUTPUT -d $QNETD -j DROP"
sleep 40   # exceed qdevice sync_timeout (default 30s)

during=$(n1 "pcs quorum status | grep -c 'Quorate:.*Yes'" || echo 0)
record t05 quorate_without_arbiter "$during" bool
vms=$(n1 "pcs status | grep -c 'Started'" || echo 0)
record t05 resources_still_started "$vms" count

echo "Restoring arbiter..."
n1 "iptables -D OUTPUT -d $QNETD -j DROP"
n2 "iptables -D OUTPUT -d $QNETD -j DROP"
sleep 20
after=$(n1 "pcs quorum status | grep -c 'Qdevice.*A,V'" || echo 0)
record t05 qdevice_revote "$after" bool

[ "$during" -eq 1 ] && echo "  PASS: store stayed quorate without the arbiter" \
                    || echo "  FAIL: cluster lost quorum -- design assumption broken"
