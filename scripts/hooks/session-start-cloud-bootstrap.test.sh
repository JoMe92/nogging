#!/usr/bin/env bash
# Focused checks for scripts/hooks/session-start-cloud-bootstrap (TASK-CSB-002).
#
# Offline only: this hook's real job (installing bd/dolt, running `bd
# bootstrap`) needs network access and a cloud container, so this test only
# exercises the CLAUDE_CODE_REMOTE guard — the part that must stay a no-op
# everywhere else.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/session-start-cloud-bootstrap"

fail=0

check_noop() {
  local desc="$1"
  shift
  local out rc=0
  out=$(env "$@" "$script" 2>&1) || rc=$?
  if [[ $rc -eq 0 && -z "$out" ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (rc=$rc, output: $out)"
    fail=1
  fi
}

check_noop "unset CLAUDE_CODE_REMOTE is a no-op" -u CLAUDE_CODE_REMOTE
check_noop "CLAUDE_CODE_REMOTE=false is a no-op" CLAUDE_CODE_REMOTE=false
check_noop "CLAUDE_CODE_REMOTE=1 (not the literal 'true') is a no-op" CLAUDE_CODE_REMOTE=1

if bash -n "$script"; then
  echo "ok   - script is syntactically valid"
else
  echo "FAIL - script is syntactically valid"
  fail=1
fi

if [[ -x "$script" ]]; then
  echo "ok   - script is executable"
else
  echo "FAIL - script is executable"
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  echo "session-start-cloud-bootstrap checks failed" >&2
  exit 1
fi
echo "all session-start-cloud-bootstrap checks passed"
