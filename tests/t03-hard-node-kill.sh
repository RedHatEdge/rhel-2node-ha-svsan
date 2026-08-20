#!/bin/bash
# Hard node loss — the real failure case, not a graceful standby.
# Fences node2 and measures how long until its workload is running on node1.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

VICTIM=${VICTIM:-$N2NAME}
VICTIM_IP=${VICTIM_IP:-$NODE2}
WATCH=${WATCH:-vm-pgsql}

before=$(resource_node "$WATCH")
info "$WATCH currently on ${before:-unknown}; fencing $VICTIM"

# Pacemaker reporting Started is not the same as the store serving again. Sample
# the guest itself so this is comparable to the appliance-backed result, which
# was measured the same way. Stamp each probe -- a failed ping costs ~1s under
# -W1, so sample spacing is not uniform and a fixed interval would understate.
DOM=${DOM:-${WATCH#vm-}}
VMIP=${VMIP:-$(guest_ip "$DOM" || true)}
PINGLOG=/tmp/t03-ping.log
PINGER=""
if [ -n "$VMIP" ]; then
  info "guest $DOM at $VMIP"
  : > "$PINGLOG"
  ( while :; do
      printf '%s %s\n' "$(( $(date +%s%N) / 1000000 ))" \
        "$(vm_reachable "$VMIP" && echo 1 || echo 0)"
      sleep 0.1
    done ) > "$PINGLOG" 2>/dev/null &
  PINGER=$!
fi

start=$(now_ms)
n1 "pcs stonith fence $VICTIM" >/dev/null 2>&1 || fail "fence command returned non-zero"

# Fence completion: victim stops answering.
while node_up "$VICTIM_IP"; do
  [ $(( $(now_ms) - start )) -gt 120000 ] && { fail "victim still up after 120s"; break; }
  sleep 1
done
fenced=$(now_ms)
record t03 fence_time $(( fenced - start )) ms

if wait_started "$WATCH" 300; then
  record t03 cluster_rto $(( $(now_ms) - start )) ms
  after=$(resource_node "$WATCH")
  [ "$after" != "$before" ] && pass "$WATCH relocated to $after" || fail "$WATCH did not relocate"
else
  fail "$WATCH did not restart within 300s"
fi

# Now wait for the workload itself, which is the number the business cares about.
if [ -n "$VMIP" ]; then
  deadline=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ups=$(tail -5 "$PINGLOG" 2>/dev/null | awk '$2=="1"' | wc -l)
    [ "${ups//[^0-9]/}" = "5" ] && break
    sleep 2
  done
  record t03 workload_rto $(( $(now_ms) - start )) ms
  kill "$PINGER" 2>/dev/null; wait "$PINGER" 2>/dev/null
  outage=$(awk '$2=="1" { if (prev != "" && $1-prev > max) max = $1-prev; prev = $1 }
                END { print (max+0) }' "$PINGLOG")
  record t03 guest_outage "$outage" ms
fi

info "waiting for $VICTIM to power back on"
if wait_node_up "$VICTIM_IP" 600; then
  record t03 node_ssh_back $(( $(now_ms) - start )) ms
else
  fail "$VICTIM did not power back on — may need manual intervention"
fi

# SSH answering is not cluster membership; measure the thing we actually mean.
info "waiting for $VICTIM to rejoin the cluster"
if wait_node_online "$VICTIM" 600; then
  record t03 node_rejoin $(( $(now_ms) - start )) ms
  wait_settled
  pass "$VICTIM back in the cluster"
else
  fail "$VICTIM answered SSH but did not rejoin the cluster"
fi
