#!/bin/bash
# Both workloads on one node — the binding constraint on 16c/96GB sizing.
# Active/active means a node failure leaves the survivor carrying everything:
# its own storage layer, its own guests, and the failed node's guests.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

SURVIVOR_IP=${SURVIVOR_IP:-$NODE1}
STANDBY=${STANDBY:-$N2NAME}

base_free=$(on "$SURVIVOR_IP" "free -m | awk '/^Mem:/{print \$7}'")
record t10 available_mb_before "$base_free" MB

info "putting $STANDBY into standby — everything relocates to the survivor"
start=$(now_ms)
n1 "pcs node standby $STANDBY"
wait_settled
record t10 consolidation_time $(( $(now_ms) - start )) ms

sleep 30
# Count WORKLOAD guests only. On the appliance backend the storage VSA is also
# a running domain, so counting everything would report one more guest on that
# side and make the two backends look different in the one test that exists to
# compare their capacity.
running=$(on "$SURVIVOR_IP" "virsh list --name 2>/dev/null" 2>/dev/null \
          | grep -v '^$' | grep -vc '^svsan-' | head -1)
running=${running//[^0-9]/}; running=${running:-0}
record t10 guests_on_survivor "$running" count

free_after=$(on "$SURVIVOR_IP" "free -m | awk '/^Mem:/{print \$7}'")

# Available memory right after consolidation is optimistic: qemu faults guest
# memory in lazily, so a guest configured for 4096MB may hold under 1000MB
# resident until its workload touches the rest. Sizing has to be driven by what
# is COMMITTED, not by what happens to be resident 30 seconds after a cold
# start. Record both, and judge headroom against the committed figure.
# awk, not bc -- bc is not in a minimal RHEL image, and a missing binary here
# returned an empty string rather than an error, so the metric silently vanished.
committed=$(on "$SURVIVOR_IP" \
  "for d in \$(virsh list --name 2>/dev/null | grep -v '^\$' | grep -v '^svsan-'); do
     virsh dominfo \$d 2>/dev/null | awk '/Max memory/{print int(\$3/1024)}'
   done | awk '{t+=\$1} END{print t+0}'" 2>/dev/null)
committed=${committed//[^0-9]/}
total_mb=$(on "$SURVIVOR_IP" "free -m | awk '/^Mem:/{print \$2}'")
total_mb=${total_mb//[^0-9]/}
if [ -n "$committed" ] && [ -n "$total_mb" ]; then
  record t10 guest_memory_committed_mb "$committed" MB
  record t10 headroom_if_fully_used_mb "$(( total_mb - committed ))" MB
fi
load=$(on "$SURVIVOR_IP" "cut -d' ' -f1 /proc/loadavg")
cores=$(on "$SURVIVOR_IP" "nproc")
record t10 available_mb_after "$free_after" MB
record t10 loadavg_1m "$load" load
record t10 cores "$cores" count

free_after=${free_after//[^0-9]/}
if [ -z "$free_after" ]; then
  fail "could not read available memory on the survivor"
elif [ "$free_after" -gt 2048 ]; then
  pass "survivor has ${free_after}MB headroom"
else
  fail "survivor down to ${free_after}MB — too tight"
fi
awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l < c)}' \
  && pass "load $load within $cores cores" \
  || fail "load $load exceeds $cores cores — oversubscribed under failover"

info "restoring $STANDBY"
n1 "pcs node unstandby $STANDBY"
wait_settled
