#!/usr/bin/env bash
# Focused checks for scripts/check-branch-name (TASK-BRANCH-003).
#
# Self-contained: builds a scratch git repo with its own openspec/changes/ tree
# and runs check-branch-name from inside it, so this test passes in any repo
# Nogging is installed into — it does not depend on this repo's change names
# (SPEC-9s1 / SPEC-kbh: hard-coded names broke scripts/test in every target repo).
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-branch-name"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
mkdir -p "$repo/openspec/changes/example-feature"
mkdir -p "$repo/openspec/changes/archive/2026-01-01-old-feature"
: > "$repo/openspec/changes/example-feature/proposal.md"
: > "$repo/openspec/changes/archive/2026-01-01-old-feature/proposal.md"

fail=0

# run <expect: pass|fail> <description> <ref>
run() {
  local expect="$1" desc="$2" ref="$3"
  local rc=0
  ( cd "$repo" && "$script" "$ref" ) >/dev/null 2>&1 || rc=$?
  local got="pass"; [[ $rc -ne 0 ]] && got="fail"
  if [[ "$got" == "$expect" ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (expected $expect, got $got, rc=$rc)"
    fail=1
  fi
}

run pass "live change branch accepted"               "feat/example-feature"
run pass "refs/heads/ prefix stripped"               "refs/heads/feat/example-feature"
run pass "archived change branch accepted"           "fix/old-feature"
run pass "planning hierarchy accepted"                "plan/authentication/oauth-login"
run pass "planning hierarchy supports kebab segments" "plan/agent-runtime/parallel-execution"
run pass "chore/<topic> accepted"                    "chore/upgrade-ci"
run fail "unknown type wip/x rejected"               "wip/example-feature"
run fail "change branch with no directory rejected"  "feat/no-such-change-here"
run fail "'archive' is not a change slug"            "feat/archive"
run fail "legacy two-part planning branch rejected"   "plan/multi-change-cleanup"
run fail "planning branch needs description"          "plan/authentication"
run fail "planning ID must be kebab-case"             "plan/Auth/login"
run fail "planning description must be kebab-case"    "plan/authentication/OAuth-Login"
run fail "planning branch has exactly three parts"    "plan/a/b/c"
run pass "main accepted"                             "main"
run pass "develop accepted"                          "develop"
run fail "empty ref fails closed"                    ""
run fail "detached HEAD fails closed"                "HEAD"

if [[ $fail -ne 0 ]]; then
  echo "check-branch-name checks failed" >&2
  exit 1
fi
echo "all check-branch-name checks passed"
