#!/bin/bash
# The nightmare scenario: both nodes alive, unable to see each other, both able
# to reach the arbiter. Exactly ONE must survive; the other must be fenced.
#
# This is what the qdevice exists for. Without it, two_node mode invites a fence
# race where both nodes shoot each other and the site goes dark.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

# Safety net first — if this script dies, rules clear themselves.
schedule_unblock "$NODE1" 300
schedule_unblock "$NODE2" 300

info "severing both corosync rings between the nodes (arbiter stays reachable)"
start=$(now_ms)
n1 "iptables -I INPUT -s 172.16.7.11 -j DROP; iptables -I OUTPUT -d 172.16.7.11 -j DROP;
    iptables -I INPUT -s 172.18.8.11 -j DROP; iptables -I OUTPUT -d 172.18.8.11 -j DROP"
n2 "iptables -I INPUT -s 172.16.7.10 -j DROP; iptables -I OUTPUT -d 172.16.7.10 -j DROP;
    iptables -I INPUT -s 172.18.8.10 -j DROP; iptables -I OUTPUT -d 172.18.8.10 -j DROP"

sleep 45   # allow membership loss, arbiter arbitration, and fencing

up1=0; up2=0
node_up "$NODE1" && on "$NODE1" true 2>/dev/null && up1=1
node_up "$NODE2" && on "$NODE2" true 2>/dev/null && up2=1
survivors=$(( up1 + up2 ))
record t06 survivors "$survivors" count
record t06 arbitration_time $(( $(now_ms) - start )) ms

case $survivors in
  1) pass "exactly one survivor — arbiter picked a winner and it fenced the loser" ;;
  2) fail "BOTH nodes alive — partition not resolved; check fencing and qdevice" ;;
  0) fail "BOTH nodes down — fence race. This is the failure two_node mode causes." ;;
esac

# Only the survivor should hold quorum and be running resources.
for ip in "$NODE1" "$NODE2"; do
  if node_up "$ip" && on "$ip" true 2>/dev/null; then
    q=$(on "$ip" "pcs quorum status 2>/dev/null | grep -c 'Quorate:.*Yes'" || echo 0)
    record t06 survivor_quorate "$q" bool
    r=$(on "$ip" "pcs status 2>/dev/null | grep -c Started" || echo 0)
    record t06 resources_on_survivor "$r" count
  fi
done

info "clearing the partition"
n1 "iptables -F INPUT; iptables -F OUTPUT" 2>/dev/null || true
n2 "iptables -F INPUT; iptables -F OUTPUT" 2>/dev/null || true
wait_node_up "$NODE1" 600; wait_node_up "$NODE2" 600
wait_settled
info "cluster restored"
