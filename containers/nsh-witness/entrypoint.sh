#!/bin/bash
# Run the two NSH daemons in the foreground and tie their lifetimes together, so
# the container dies if either does and the orchestrator can restart it.
#
#   smclusterd  the witness proper — arbitrates mirror ownership
#   smdiscod    discovery — lets VSAs find the witness without being told
#
# Set NSH_DISCOVERY=false where discovery is unwanted (typically across a WAN,
# where multicast will not traverse and VSAs are pointed at the witness by
# address anyway).
set -euo pipefail

BIN=/opt/stormagic/SvSAN/bin
: "${NSH_DISCOVERY:=true}"
: "${NSH_SERIAL:=}"

pids=()
term() {
    echo "nsh-witness: stopping"
    for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
    exit 0
}
trap term SIGTERM SIGINT

args=(--foreground)
[ -n "$NSH_SERIAL" ] && args+=(--serial "$NSH_SERIAL")

echo "nsh-witness: starting smclusterd ${args[*]}"
"$BIN/smclusterd" "${args[@]}" &
pids+=($!)

if [ "$NSH_DISCOVERY" = "true" ]; then
    echo "nsh-witness: starting smdiscod --foreground --standalone"
    "$BIN/smdiscod" --foreground --standalone &
    pids+=($!)
fi

# Exit as soon as ANY daemon exits — a half-running witness is worse than a
# stopped one, because it can still answer discovery while unable to arbitrate.
wait -n
echo "nsh-witness: a daemon exited; shutting down so the unit restarts cleanly"
term
