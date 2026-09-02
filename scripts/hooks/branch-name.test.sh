#!/usr/bin/env bash
# Focused checks for scripts/check-branch-name (TASK-BRANCH-003).
# Covers: existing change branch accepted, plan/ and chore/ topic branches
# accepted, unknown type rejected, change branch with no matching directory
# rejected, main and develop accepted.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-branch-name"

fail=0

# run <expect: pass|fail> <description> <ref>
run() {
  local expect="$1" desc="$2" ref="$3"
  local rc=0
  "$script" "$ref" >/dev/null 2>&1 || rc=$?
  local got="pass"; [[ $rc -ne 0 ]] && got="fail"
  if [[ "$got" == "$expect" ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (expected $expect, got $got, rc=$rc)"
    fail=1
  fi
}

run pass "live change branch accepted"               "feat/end-to-end-acceptance"
run pass "refs/heads/ prefix stripped"              "refs/heads/feat/end-to-end-acceptance"
run pass "archived change branch accepted"           "feat/enforce-conventional-branching"
run pass "plan/<topic> accepted"                    "plan/multi-change-cleanup"
run pass "chore/<topic> accepted"                   "chore/upgrade-ci"
run fail "unknown type wip/x rejected"              "wip/enforce-conventional-branching"
run fail "change branch with no directory rejected" "feat/no-such-change-here"
run pass "main accepted"                            "main"
run pass "develop accepted"                         "develop"
run fail "empty ref fails closed"                   ""
run fail "detached HEAD fails closed"               "HEAD"

if [[ $fail -ne 0 ]]; then
  echo "check-branch-name checks failed" >&2
  exit 1
fi
echo "all check-branch-name checks passed"
