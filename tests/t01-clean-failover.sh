#!/bin/bash
# Planned failover: standby a node, measure how long until resources are back.
# Models the patching workflow.
set -u; source "$(dirname "$0")/lib.sh"

start=$(now_ms)
n1 "pcs node standby $(n1 hostname)"
wait_settled
end=$(now_ms)
record t01 planned_failover $(( end - start )) ms

n1 "pcs node unstandby $(n1 hostname)"
wait_settled
record t01 unstandby_settle $(( $(now_ms) - end )) ms
