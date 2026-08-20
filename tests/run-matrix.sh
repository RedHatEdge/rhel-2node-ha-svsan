#!/bin/bash
# Runs the acceptance matrix against whichever storage backend is staged.
# Same tests, same measurements, both options.
#
#   ./run-matrix.sh                    non-disruptive tests only
#   CONFIRM=yes ./run-matrix.sh        include disruptive tests
#   ./run-matrix.sh t02 t08            selected tests
#   CONFIRM=yes PGHOST=1.2.3.4 ./run-matrix.sh t09
set -u
cd "$(dirname "$0")"
source ./lib.sh

echo "Backend : $BACKEND"
echo "Results : $CSV"
[ "${CONFIRM:-}" = "yes" ] && echo "Mode    : DISRUPTIVE tests enabled" \
                           || echo "Mode    : safe tests only (CONFIRM=yes to enable the rest)"

if [ $# -gt 0 ]; then
  TESTS=("$@")
else
  mapfile -t TESTS < <(ls t*.sh | sed 's/-.*//')
fi

FAILCOUNT=0
for t in "${TESTS[@]}"; do
  f=$(ls "${t}"*.sh 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "no such test: $t"; continue; }
  banner "$f"
  bash "$f" || { echo "  ERROR in $f"; FAILCOUNT=$((FAILCOUNT+1)); }
done

banner "Results"
column -s, -t < "$CSV"
echo
echo "Tests with errors: $FAILCOUNT"
echo
echo "To compare storage options, run this matrix once per backend and diff the"
echo "rows — the backend column separates them."
