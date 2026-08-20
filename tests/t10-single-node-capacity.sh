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
running=$(on "$SURVIVOR_IP" "virsh list --name | grep -vc '^$'" || echo 0)
record t10 guests_on_survivor "$running" count

free_after=$(on "$SURVIVOR_IP" "free -m | awk '/^Mem:/{print \$7}'")
load=$(on "$SURVIVOR_IP" "cut -d' ' -f1 /proc/loadavg")
cores=$(on "$SURVIVOR_IP" "nproc")
record t10 available_mb_after "$free_after" MB
record t10 loadavg_1m "$load" load
record t10 cores "$cores" count

[ "$free_after" -gt 2048 ] && pass "survivor has ${free_after}MB headroom" \
                           || fail "survivor down to ${free_after}MB — too tight"
awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l < c)}' \
  && pass "load $load within $cores cores" \
  || fail "load $load exceeds $cores cores — oversubscribed under failover"

info "restoring $STANDBY"
n1 "pcs node unstandby $STANDBY"
wait_settled
