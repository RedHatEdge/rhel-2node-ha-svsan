#!/bin/bash
# Shared helpers for the acceptance matrix.
#
# Same tests, same measurements, both storage options — that is the point.
# Anything backend-specific branches on $BACKEND rather than living in a
# separate test.

NODE1=${NODE1:-172.16.7.10}
NODE2=${NODE2:-172.16.7.11}
QNETD=${QNETD:-172.16.7.20}
# Second corosync ring. Needed by the partition test, which has to sever BOTH
# rings -- cutting only ring0 proves nothing, knet just keeps using ring1.
NODE1_RING1=${NODE1_RING1:-172.18.8.10}
NODE2_RING1=${NODE2_RING1:-172.18.8.11}
N1NAME=${N1NAME:-node1}
N2NAME=${N2NAME:-node2}

RESULTS=${RESULTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results}
mkdir -p "$RESULTS"
CSV="$RESULTS/matrix.csv"
[ -f "$CSV" ] || echo "timestamp,backend,test,metric,value,unit" > "$CSV"

ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
n1() { ssh $ssh_opts root@"$NODE1" "$@"; }
n2() { ssh $ssh_opts root@"$NODE2" "$@"; }
on() { ssh $ssh_opts root@"$1" "${@:2}"; }   # on <ip> <cmd...>

# Which storage layer the WORKLOAD is actually on.
#
# Asking "is DRBD present" or "is iscsid running" answers a different question:
# on a host where both layers have been staged, both are true at once and the
# first check simply wins. That silently mislabels every row in the results file,
# which is worse than failing. The guests' own disk backing is the ground truth,
# so look there first and fall back to the presence checks only if no workload
# guest is defined yet.
detect_backend() {
  local src
  src=$(n1 "virsh dumpxml pos 2>/dev/null || virsh dumpxml pgsql 2>/dev/null" 2>/dev/null \
        | grep -oE "source (dev|file)='[^']+'" | grep -v 'seed.iso' | head -1)
  case "$src" in
    *'/dev/mapper/'*)   echo svsan; return ;;
    *'/var/store-'*)    echo drbd;  return ;;
  esac
  # No workload guest defined yet -- fall back to what is installed.
  if n1 "virsh list --all --name 2>/dev/null | grep -q '^svsan-'" 2>/dev/null; then echo svsan
  elif n1 "test -e /proc/drbd" 2>/dev/null; then echo drbd
  else echo unknown; fi
}
BACKEND=${BACKEND:-$(detect_backend)}

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

record() {  # record <test> <metric> <value> <unit>
  printf '%s,%s,%s,%s,%s,%s\n' "$(date -Is)" "$BACKEND" "$1" "$2" "$3" "$4" >> "$CSV"
  printf '  %-30s %12s %s\n' "$2" "$3" "$4"
}

pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=1; }
info() { echo "  ..    $*"; }
banner() { echo; echo "=== $* ==="; }

# Destructive tests must be opted into.
require_confirm() {
  if [ "${CONFIRM:-}" != "yes" ]; then
    echo "  SKIPPED — this test is disruptive. Re-run with CONFIRM=yes"
    exit 0
  fi
}

wait_settled() { n1 "crm_resource --wait" >/dev/null 2>&1 || true; }

# Node currently running a resource, by Pacemaker node name.
resource_node() {
  n1 "crm_mon -1 --output-as=xml 2>/dev/null" \
    | tr '>' '>\n' \
    | grep -A2 "id=\"$1\"" \
    | grep -oP 'name="\K[^"]+' \
    | tail -1
}

resource_started() {  # resource_started <name> -> 0 if Started
  n1 "crm_mon -1 2>/dev/null | grep -q '$1.*Started'"
}

# Block until a resource is Started somewhere, or timeout.
wait_started() {  # wait_started <name> <timeout_s>
  local end=$(( $(date +%s) + ${2:-300} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    resource_started "$1" && return 0
    sleep 2
  done
  return 1
}

node_up() { ping -c1 -W1 "$1" >/dev/null 2>&1; }

wait_node_up() {  # wait_node_up <ip> <timeout_s>
  local end=$(( $(date +%s) + ${2:-600} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    node_up "$1" && on "$1" true 2>/dev/null && return 0
    sleep 5
  done
  return 1
}

# Safety net: schedule a firewall flush on a node so a partition test cannot
# lock us out permanently if the script dies mid-run.
schedule_unblock() {  # schedule_unblock <ip> <seconds>
  on "$1" "nohup bash -c 'sleep ${2:-300}; iptables -F INPUT; iptables -F OUTPUT' \
    >/dev/null 2>&1 &" || true
}

# ── guest helpers ──────────────────────────────────────────────────────────
# Address of a guest via the qemu guest agent, asking whichever node runs it.
guest_ip() {  # guest_ip <domain>
  local d=$1 ip h
  for h in "$NODE1" "$NODE2"; do
    ip=$(on "$h" "virsh domifaddr $d --source agent 2>/dev/null" 2>/dev/null \
         | grep -oP '\b\d+\.\d+\.\d+\.\d+(?=/)' | grep -v '^127\.' | head -1)
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  done
  return 1
}

GUESTUSER=${GUESTUSER:-lab}

# A guest's boot id changes if and only if it rebooted. This is what separates a
# genuine live migration from a stop/start that merely looks like one from the
# cluster's point of view.
guest_bootid() {  # guest_bootid <ip>
  ssh $ssh_opts -o BatchMode=yes "$GUESTUSER@$1" \
    'cat /proc/sys/kernel/random/boot_id' 2>/dev/null
}

vm_reachable() { ping -c1 -W1 "$1" >/dev/null 2>&1; }

# Node currently running a resource, as a Pacemaker node name.
rsc_node() {  # rsc_node <resource>
  n1 "crm_mon -1 2>/dev/null" | grep -E "\b$1\b.*Started" \
    | grep -oE "$N1NAME|$N2NAME" | tail -1
}

# dd reports kB/s or MB/s depending on how slow the device is, so matching a
# literal " MB/s" silently yields nothing on a slow volume. Derive the rate from
# the byte count and elapsed time instead of trusting dd's chosen unit.
dd_rate_mbs() {  # dd_rate_mbs <dd stderr text>
  awk '/copied|bytes/ {
         for (i=1; i<=NF; i++) if ($i=="copied," || $i=="copied") { b=$1 }
         for (i=1; i<=NF; i++) if ($i=="s,") { s=$(i-1) }
       }
       END { if (b>0 && s>0) printf "%.2f", (b/1048576)/s; }' <<<"$1"
}
dd_seconds() {  # dd_seconds <dd stderr text>
  awk '{ for (i=1; i<=NF; i++) if ($i=="s,") { print $(i-1); exit } }' <<<"$1"
}

# `grep -c` prints 0 AND exits non-zero when nothing matches, so the common
# idiom `$(cmd | grep -c X || echo 0)` yields a two-line "0\n0" that splits the
# CSV row in half and corrupts the comparison. Count through this instead.
safe_count() {  # safe_count <host-ip> <remote-cmd> <pattern>
  local out
  out=$(on "$1" "$2" 2>/dev/null | grep -c "$3" 2>/dev/null | head -1)
  out=${out//[^0-9]/}
  echo "${out:-0}"
}

# A fenced node answers SSH while it is still in early boot, long before
# corosync starts -- so "can I ssh to it" is not "is it back in the cluster".
# Ask the surviving node what it can actually see.
wait_node_online() {  # wait_node_online <pcmk-node-name> <timeout_s>
  local end=$(( $(date +%s) + ${2:-600} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    n1 "crm_mon -1 2>/dev/null" | grep -qE "Online:.*\b$1\b" && return 0
    sleep 5
  done
  return 1
}

# The appliance domain is named per node (svsan-node1 / svsan-node2), not
# "svsan-vsa". Hardcoding the wrong name made backend detection fall through to
# "unknown", which silently skipped every test in the matrix.
svsan_domain() {  # svsan_domain <host-ip>
  on "$1" "virsh list --all --name 2>/dev/null" 2>/dev/null | grep '^svsan-' | head -1
}

# Bounded wait for a remote condition. Every wait in this harness must have a
# deadline: an unbounded `until ...; do sleep 5; done` turns a failed test into a
# hung run that has to be killed by hand.
wait_for() {  # wait_for <timeout_s> <host-ip> <remote test command>
  local end=$(( $(date +%s) + $1 )); shift
  local host=$1; shift
  while [ "$(date +%s)" -lt "$end" ]; do
    on "$host" "$*" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
