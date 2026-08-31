#!/usr/bin/env bash
# Focused checks for scripts/hooks/commit-msg (TASK-BOUNDARY-003).
# Covers: valid Beads ID accepted, missing ID rejected, planning exemption,
# sync exemption, and that Conventional Commit validation still applies.
set -euo pipefail

hook="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/commit-msg"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

fail=0

# run <expect: pass|fail> <description> <env-assignment-or-> <subject>
run() {
  local expect="$1" desc="$2" env_kv="$3" subject="$4"
  printf '%s\n' "$subject" >"$tmp"
  local rc=0
  if [[ "$env_kv" == "-" ]]; then
    "$hook" "$tmp" >/dev/null 2>&1 || rc=$?
  else
    env "$env_kv" "$hook" "$tmp" >/dev/null 2>&1 || rc=$?
  fi
  local got="pass"; [[ $rc -ne 0 ]] && got="fail"
  if [[ "$got" == "$expect" ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (expected $expect, got $got, rc=$rc)"
    fail=1
  fi
}

run pass "valid Beads ID accepted"            -                        "feat: harden commit-msg hook [SPEC-gjw]"
run fail "missing Beads ID rejected"           -                        "feat: harden commit-msg hook"
run fail "placeholder [BEAD-XXX] rejected"     -                        "feat: harden commit-msg hook [BEAD-XXX]"
run pass "planning exemption accepted"         SPECFORGE_WRITER=planning "docs: revise openspec change"
run pass "sync exemption accepted"             SPECFORGE_WRITER=sync     "chore(sync): mirror Beads execution evidence"
run fail "non-conventional subject rejected"   -                        "harden commit-msg hook [SPEC-gjw]"
run fail "planning writer still needs Conventional Commit" SPECFORGE_WRITER=planning "revise openspec change"

if [[ $fail -ne 0 ]]; then
  echo "commit-msg checks failed" >&2
  exit 1
fi
echo "all commit-msg checks passed"
