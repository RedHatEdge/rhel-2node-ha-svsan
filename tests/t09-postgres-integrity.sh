#!/bin/bash
# The zero-RPO proof, and the most important test in the matrix.
#
# Writes committed transactions continuously, recording locally what the
# database ACKNOWLEDGED. Then kills the node hosting it. After failover, every
# acknowledged transaction must still be present. Anything missing is data the
# store told a customer was saved and then lost.
set -u; source "$(dirname "$0")/lib.sh"; require_confirm

PGHOST=${PGHOST:?set PGHOST to the pgsql guest address}
PGUSER=${PGUSER:-postgres}
PGDB=${PGDB:-postgres}
ACKLOG=$(mktemp)

psql_q() { PGCONNECT_TIMEOUT=5 psql -h "$PGHOST" -U "$PGUSER" -d "$PGDB" -tAc "$1" 2>/dev/null; }

command -v psql >/dev/null || { echo "  SKIPPED — psql not installed on the test host"; exit 0; }
psql_q "select 1" >/dev/null || { echo "  SKIPPED — cannot reach postgres at $PGHOST"; exit 0; }

info "preparing table"
psql_q "drop table if exists rpo_test;
        create table rpo_test(id bigserial primary key, ts timestamptz default now());
        alter system set synchronous_commit = on; select pg_reload_conf();" >/dev/null

info "starting committed-write loop"
(
  i=0
  while true; do
    i=$((i+1))
    if out=$(psql_q "insert into rpo_test default values returning id;"); then
      [ -n "$out" ] && echo "$out" >> "$ACKLOG"
    else
      sleep 0.2
    fi
  done
) &
WRITER=$!
trap 'kill $WRITER 2>/dev/null || true' EXIT

sleep 20
acked_before=$(wc -l < "$ACKLOG")
info "acknowledged $acked_before writes; now killing the host node"

VICTIM=$(resource_node vm-pgsql)
VICTIM=${VICTIM:-$N2NAME}
start=$(now_ms)
n1 "pcs stonith fence $VICTIM" >/dev/null 2>&1

# The writer keeps trying across the outage; it simply stops getting acks.
if wait_started vm-pgsql 420; then
  record t09 guest_rto $(( $(now_ms) - start )) ms
else
  fail "pgsql guest did not restart within 420s"
fi

info "waiting for postgres to accept connections again"
for _ in $(seq 1 120); do psql_q "select 1" >/dev/null && break; sleep 5; done
record t09 db_available $(( $(now_ms) - start )) ms

kill $WRITER 2>/dev/null || true; sleep 1

last_acked=$(tail -1 "$ACKLOG" 2>/dev/null || echo 0)
total_acked=$(wc -l < "$ACKLOG")
surviving=$(psql_q "select count(*) from rpo_test;" || echo 0)
max_id=$(psql_q "select coalesce(max(id),0) from rpo_test;" || echo 0)

record t09 acked_writes "$total_acked" count
record t09 surviving_rows "$surviving" count
record t09 last_acked_id "$last_acked" id
record t09 max_id_in_db "$max_id" id

# Every acked id must still be present. Count any that are missing.
missing=$(psql_q "select count(*) from (
            select generate_series(1,$last_acked) as id
            except select id from rpo_test) m;" || echo -1)
record t09 lost_acked_writes "$missing" count

if [ "$missing" = "0" ]; then
  pass "zero RPO confirmed — every acknowledged write survived the node kill"
else
  fail "$missing acknowledged writes LOST — RPO is not zero"
fi

wait_node_up "${VICTIM_IP:-$NODE2}" 600 || info "victim still recovering"
wait_settled
rm -f "$ACKLOG"
