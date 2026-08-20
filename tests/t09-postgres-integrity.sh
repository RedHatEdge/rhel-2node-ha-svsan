#!/bin/bash
# The zero-RPO proof, and the most important test in the matrix.
#
# Writes committed transactions continuously, recording ON THE CONTROL NODE
# which ids the database ACKNOWLEDGED. Then kills the node hosting it. After
# failover, every acknowledged id must still be present. Anything missing is
# data the store told a customer was saved and then lost.
#
# The ack record deliberately lives outside the guest: a log kept inside the
# thing being killed is not evidence.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

DOM=${DOM:-pgsql}
PGHOST=${PGHOST:-$(guest_ip "$DOM" || true)}
[ -n "$PGHOST" ] || { echo "  SKIPPED — cannot find the $DOM guest address"; exit 0; }

ACKLOG=$(mktemp); DBIDS=$(mktemp); ACKSORT=$(mktemp)
cleanup() { kill "${WRITER:-}" 2>/dev/null; rm -f "$ACKLOG" "$DBIDS" "$ACKSORT"; }
trap cleanup EXIT

# psql runs INSIDE the guest. Postgres listens on localhost and pg_hba allows
# local connections only -- which is correct for a store workload, so the test
# adapts to the deployment rather than opening the database to the network to
# make itself easier to write.
# -q matters: without it psql prints the command status tag ("INSERT 0 1") on
# its own line after the returned id. That line contains digits, so a loose
# numeric filter counts it as a second acknowledgement -- which reported exactly
# 2x the real writes and made half of them look lost. Every id filter below is
# anchored to a whole-line integer for the same reason.
pg() { ssh $ssh_opts -o BatchMode=yes "$GUESTUSER@$PGHOST" \
        "sudo -u postgres psql -tAqc \"$1\"" 2>/dev/null; }

pg "select 1" >/dev/null || { echo "  SKIPPED — cannot reach postgres in $DOM"; exit 0; }

info "preparing table"
pg "drop table if exists rpo_test;
    create table rpo_test(id bigserial primary key, ts timestamptz default now());" >/dev/null
pg "show synchronous_commit" | grep -q on \
  && info "synchronous_commit is on" \
  || info "WARNING: synchronous_commit is not on -- RPO claim would be weaker"

info "starting committed-write loop"
# One persistent SSH session; each acknowledged id streams back and lands in a
# file on THIS machine. When the guest dies the stream simply stops.
ssh $ssh_opts -o BatchMode=yes "$GUESTUSER@$PGHOST" \
  'while true; do sudo -u postgres psql -tAqc "insert into rpo_test default values returning id;" 2>/dev/null; done' \
  > "$ACKLOG" 2>/dev/null &
WRITER=$!

sleep 20
acked_before=$(grep -cE '^[0-9]+$' "$ACKLOG" || true)
info "acknowledged ${acked_before:-0} writes; now killing the host node"
[ "${acked_before:-0}" -gt 0 ] || { fail "no writes acknowledged -- nothing to prove"; exit 1; }

VICTIM=$(rsc_node vm-pgsql); VICTIM=${VICTIM:-$N2NAME}
VICTIM_IP=$([ "$VICTIM" = "$N1NAME" ] && echo "$NODE1" || echo "$NODE2")
start=$(now_ms)
n1 "pcs stonith fence $VICTIM" >/dev/null 2>&1

if wait_started vm-pgsql 420; then
  record t09 guest_rto $(( $(now_ms) - start )) ms
else
  fail "pgsql guest did not restart within 420s"
fi

# The guest gets a new SSH host key only if cloud-init re-runs; either way the
# old session is dead, so re-resolve and reconnect rather than reusing it.
kill "$WRITER" 2>/dev/null; WRITER=""
info "waiting for postgres to accept connections again"
PGHOST=$(guest_ip "$DOM" || echo "$PGHOST")
for _ in $(seq 1 120); do pg "select 1" >/dev/null && break; sleep 5; done
record t09 db_available $(( $(now_ms) - start )) ms

# Compare the acknowledged ids against what is actually in the table. Using the
# ack list rather than generate_series matters: a bigserial can burn a sequence
# value on a rolled-back insert, and that gap is not a lost write.
pg "select id from rpo_test order by id" | tr -d ' \r' | grep -E '^[0-9]+$' | sort -u > "$DBIDS"
tr -d ' \r' < "$ACKLOG" | grep -E '^[0-9]+$' | sort -u > "$ACKSORT"

total_acked=$(wc -l < "$ACKSORT")
surviving=$(wc -l < "$DBIDS")
missing=$(comm -23 "$ACKSORT" "$DBIDS" | wc -l)

record t09 acked_writes   "$total_acked" count
record t09 surviving_rows "$surviving"   count
record t09 lost_acked_writes "$missing"  count

if [ "$missing" -eq 0 ]; then
  pass "zero RPO confirmed — all $total_acked acknowledged writes survived the node kill"
else
  fail "$missing of $total_acked acknowledged writes LOST — RPO is not zero"
  comm -23 "$ACKSORT" "$DBIDS" | head -5 | sed 's/^/    missing id: /'
fi

info "waiting for $VICTIM to rejoin"
wait_node_up "$VICTIM_IP" 600 || info "victim still powering up"
wait_node_online "$VICTIM" 600 || info "victim has not rejoined the cluster yet"
wait_settled
