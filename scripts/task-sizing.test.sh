#!/usr/bin/env bash
# `task_sizing` (.nogging/config.json) and its advisory checks: `nogg
# task-sizing` prints the configured Bead/commit line ranges (defaults when the
# key is absent), and `validate` reports a NOTE — never a FAIL, never a changed
# exit code — for open tasks whose `[~N loc]` estimate is below the configured
# minimum or above the configured maximum without a reason, or for a change
# whose open tasks mostly carry none.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/test-env.sh
source "$here/lib/test-env.sh"
nogg="$here/nogg"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# validate runs doctor, which walks CODEX_HOME: never the operator's real one.
mkdir -p "$work/codex-home"
export CODEX_HOME="$work/codex-home"

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

mkdir -p "$work/bin"
printf '#!/usr/bin/env bash\n[[ ${1:-} == list ]] && { echo "[]"; exit 0; }\nexit 1\n' > "$work/bin/bd"
chmod +x "$work/bin/bd"
export PATH="$work/bin:$PATH"

repo="$work/repo"
mkdir -p "$repo/.nogging" "$repo/openspec/changes"
git -C "$repo" init -q
write_config() { # <task_sizing JSON or empty>
  local extra=""
  [[ -n "$1" ]] && extra=", \"task_sizing\": $1"
  printf '{"name": "fixture", "beads_command": "bd", "planning_lock_ttl_seconds": 7200, "sync_lock_ttl_seconds": 120%s}\n' \
    "$extra" > "$repo/.nogging/config.json"
}
change() { # <name> <tasks.md body>
  mkdir -p "$repo/openspec/changes/$1"
  printf '# Tasks\n\n%s\n' "$2" > "$repo/openspec/changes/$1/tasks.md"
}
sizing() { NOGGING_ROOT="$repo" "$nogg" task-sizing 2>&1; }
validate() { local rc=0; NOGGING_ROOT="$repo" "$nogg" validate >"$work/validate.out" 2>&1 || rc=$?; echo "$rc"; }

# --- task-sizing: defaults, configured values, malformed values ---------------
write_config ""
out=$(sizing)
check "absent key prints the default Bead range" has "$out" "bead_prod_lines: 400-1000 (default)"
check "absent key prints the default commit range" has "$out" "commit_lines: 100-600 (default)"
check "absent key prints the default test budget" has "$out" "bead_test_lines: 1-1500 (default)"

write_config '{"bead_prod_lines": [200, 800]}'
out=$(sizing)
check "a configured Bead range is printed as configured" has "$out" "bead_prod_lines: 200-800 (configured)"
check "an unset commit range keeps its default" has "$out" "commit_lines: 100-600 (default)"

write_config '{"bead_test_lines": [10, 800]}'
out=$(sizing)
check "a configured test budget is printed as configured" has "$out" "bead_test_lines: 10-800 (configured)"

write_config '{"bead_test_lines": [0, 99], "bead_prod_lines": [900, 100], "commit_lines": "many", "bogus": 1}'
out=$(sizing)
check "an inverted range falls back to the default" has "$out" "bead_prod_lines: 400-1000 (default)"
check "a mistyped range falls back to the default" has "$out" "commit_lines: 100-600 (default)"
check "a malformed range is a WARN" has "$out" "WARN  task_sizing.bead_prod_lines"
check "an unknown key is a WARN" has "$out" "WARN  task_sizing.bogus"
check "a malformed test budget falls back to the default" has "$out" "bead_test_lines: 1-1500 (default)"
check "a malformed test budget is a WARN" has "$out" "WARN  task_sizing.bead_test_lines"

# --- validate: NOTEs only, the exit code never changes -------------------------
write_config ""
change sized '- [ ] TASK-SZ-001 Feature slice [~600 loc]
- [ ] TASK-SZ-002 Security fix [~40 loc: security fix]
- [x] TASK-SZ-003 Done small slice [~20 loc]'
baseline_rc=$(validate)
out=$(cat "$work/validate.out")
check "a well-sized change gets no task sizing NOTE" lacks "$out" "task sizing: sized"
sizing_notes=$(grep 'task sizing:' <<<"$out" || true)
check "a below-minimum task with a reason gets no NOTE" lacks "$sizing_notes" "TASK-SZ-002"
check "a ticked task is not checked" lacks "$out" "TASK-SZ-003 (~20 loc)"

change small '- [ ] TASK-SM-001 Contracts only [~80 loc]
- [ ] TASK-SM-002 Logic, wrapped over
      two lines [~ 120 loc]
- [ ] TASK-SM-003 Full slice [~500 loc]'
change lone '- [ ] TASK-LN-001 Lone task without its own estimate
  - nested note citing [~80 loc] from the design'
change bare '- [ ] TASK-BR-001 No estimate
- [ ] TASK-BR-002 No estimate either
- [ ] TASK-BR-003 One estimate [~450 loc]'
rc=$(validate)
out=$(cat "$work/validate.out")
check "undersized tasks without a reason get one NOTE naming them" \
  has "$out" "NOTE  task sizing: small: TASK-SM-001 (~80 loc), TASK-SM-002 (~120 loc) below the configured 400-line Bead minimum"
check "an estimate on a continuation line is read" has "$out" "TASK-SM-002 (~120 loc)"
check "a change whose open tasks mostly lack estimates gets a NOTE" \
  has "$out" "NOTE  task sizing: bare: 2 of 3 open tasks carry no [~N loc] estimate"
check "a single unestimated open task is not 'many'" lacks "$out" "task sizing: lone"
check "a nested bullet's estimate is not read as the task's" lacks "$out" "TASK-LN-001 (~80 loc)"
check "task sizing findings are never a FAIL" bash -c '! grep -q "^FAIL.*task sizing" "$0"' "$work/validate.out"
check "task sizing findings never change the validate exit code" test "$rc" = "$baseline_rc"

change large '- [ ] TASK-LG-001 Whole subsystem in one go [~2400 loc]
- [ ] TASK-LG-002 Generated schema, kept whole [~1800 loc: generated code, one unit]
- [ ] TASK-LG-003 Right at the maximum [~1000 loc]'
rc=$(validate)
out=$(cat "$work/validate.out")
check "an oversized task without a reason gets one NOTE naming it" \
  has "$out" "NOTE  task sizing: large: TASK-LG-001 (~2400 loc) above the configured 1000-line Bead maximum without a reason"
sizing_notes=$(grep 'task sizing:' <<<"$out" || true)
check "an above-maximum task with a reason gets no NOTE" lacks "$sizing_notes" "TASK-LG-002"
check "an estimate equal to the maximum gets no NOTE" lacks "$sizing_notes" "TASK-LG-003"
check "the oversized NOTE asks for a split" has "$out" "split it or state why"
check "an oversized task is never a FAIL" bash -c '! grep -q "^FAIL.*TASK-LG" "$0"' "$work/validate.out"
check "an oversized task never changes the validate exit code" test "$rc" = "$baseline_rc"

write_config '{"bead_prod_lines": [50, 3000]}'
rc=$(validate)
out=$(cat "$work/validate.out")
check "the configured minimum is the one applied" lacks "$out" "task sizing: small"
check "the configured maximum is the one applied" lacks "$out" "task sizing: large"
write_config '{"bead_prod_lines": "broken"}'
rc=$(validate)
out=$(cat "$work/validate.out")
check "validate reports a malformed task_sizing as a WARN" has "$out" "WARN  task_sizing.bead_prod_lines"
check "a malformed task_sizing never changes the validate exit code" test "$rc" = "$baseline_rc"

if [[ $fail -ne 0 ]]; then
  echo "task sizing checks failed" >&2
  exit 1
fi
echo "all task sizing checks passed"
