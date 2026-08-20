#!/bin/bash
# Shared helpers for the acceptance matrix.
#
# Same tests, same measurements, both storage options — that is the point.
# Anything backend-specific branches on $BACKEND rather than living in a
# separate test.

NODE1=${NODE1:-172.16.7.10}
NODE2=${NODE2:-172.16.7.11}
QNETD=${QNETD:-172.16.7.20}
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

# Which storage layer is staged right now.
detect_backend() {
  if n1 "test -e /proc/drbd" 2>/dev/null; then echo drbd
  elif n1 "systemctl is-active --quiet iscsid && virsh dominfo svsan-vsa >/dev/null 2>&1" 2>/dev/null; then echo svsan
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
