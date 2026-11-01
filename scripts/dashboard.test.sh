#!/usr/bin/env bash
# The dashboard's Python tests: every scripts/lib/dashboard_*_test.py, by glob, so a
# later change adds a test file with no wiring. Offline: no Dolt, no real `bd`, no
# sleeps. An installed copy ships no test file and skips them.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob
tests=("$here"/lib/dashboard_*_test.py)
if [[ ${#tests[@]} -eq 0 ]]; then
  echo "ok   - dashboard tests skipped (installed consumer copy)"
  exit 0
fi

fail=0
out=$(mktemp); trap 'rm -f "$out"' EXIT
for test in "${tests[@]}"; do
  if PYTHONDONTWRITEBYTECODE=1 python3 "$test" >"$out" 2>&1; then
    echo "ok   - $(basename "$test")"
  else
    echo "FAIL - $(basename "$test")"
    cat "$out"
    fail=1
  fi
done
exit "$fail"
