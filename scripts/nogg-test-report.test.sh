#!/usr/bin/env bash
# `nogg test report`, `nogg test integrity` and the integrity and budget lines of
# `nogg test bead`, plus the `doctor` trend NOTE. The aggregation and the trend
# rule are small cases in scripts/lib/testing_report_test.py; this file runs the
# commands on temporary repositories. Offline; every runner and `bd` is a stub.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/test-env.sh
source "$here/lib/test-env.sh"
nogg="$here/nogg"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export TMPDIR="$work/tmp" NOGG_TEST_SLOT_ROOT="$work/slots" NOGG_TEST_SLOT_POLL_SECONDS=0.05
mkdir -p "$TMPDIR"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

if [[ -f "$here/lib/testing_report_test.py" ]]; then
  python3 "$here/lib/testing_report_test.py" >"$work/unit.out" 2>&1 && ok "testing_report_test.py" \
    || { bad "testing_report_test.py"; cat "$work/unit.out"; }
fi

# A repository whose develop holds one test file; <config JSON> is the whole config.
make_repo() { # <dir> <config JSON>
  local dir="$1"
  mkdir -p "$dir/.nogging" "$dir/scripts"
  git -C "$dir" init -q -b develop
  printf '%s' "$2" >"$dir/.nogging/config.json"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/scripts/test"
  chmod +x "$dir/scripts/test"
  printf '.nogging/state/\n.nogging/locks/\n' >"$dir/.gitignore"
  printf 'def test_one():\n    assert 1\n\ndef test_two():\n    assert 2\n' >"$dir/calc_test.py"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: start"
}
config() { # <testing block JSON or null> [task_sizing JSON] [bd command]
  python3 - "$1" "${2:-null}" "${3:-bd}" <<'PY'
import json, sys
config = {"name": "fixture", "beads_command": sys.argv[3]}
if json.loads(sys.argv[1]) is not None:
    config["testing"] = json.loads(sys.argv[1])
if json.loads(sys.argv[2]) is not None:
    config["task_sizing"] = json.loads(sys.argv[2])
print(json.dumps(config))
PY
}
run() { # <dir> <nogg test args...>: sets rc and out, stdout and stderr merged
  local dir="$1"; shift
  rc=0
  out=$(NOGGING_ROOT="$dir" "$nogg" test "$@" 2>&1) || rc=$?
}
last() { # <dir> <python expression over r>: a field of the newest run record
  python3 - "$1/.nogging/state/testing/runs.jsonl" "$2" <<'PY'
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
print(eval(sys.argv[2]))
PY
}
seed() { # <dir> <stage> <days ago> <seconds> [status]: one run record, written by the real writer
  python3 - "$here/lib" "$1/.nogging/state/testing" "$2" "$3" "$4" "${5:-passed}" <<'PY'
import datetime as dt, sys
sys.path.insert(0, sys.argv[1])
import testing_runs as runs
at = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=float(sys.argv[4]), minutes=1)).isoformat()
record = runs.build_record(stage=sys.argv[3], trigger="stage", status=sys.argv[6], exit_code=0,
                           seconds=float(sys.argv[5]), at=at)
runs.append_record(sys.argv[2], record)
PY
}

# --- nogg test report ---------------------------------------------------------
repo="$work/report"
make_repo "$repo" "$(config null)"
run "$repo" report
check "no record yet says so" has "$out" "no test runs recorded yet"
check "no record yet exits 0" test "$rc" -eq 0
run "$repo" report --json
check "no record yet is still valid JSON" python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["records"]==0 and d["daily"]==[]' "$out"

seed "$repo" bead 0 120
seed "$repo" bead 0 80
seed "$repo" commit 0 15
seed "$repo" bead 40 999
run "$repo" report
check "report exits 0" test "$rc" -eq 0
check "report prints a row per day and stage" has "$out" "bead"
check "report names the median" has "$out" "100.0"
check "report prints the week over week section" has "$out" "week over week"
check "a run older than the window is not counted" lacks "$out" "999"
run "$repo" report --json --days 7
check "report --json carries the schema" python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["schema"]=="nogg.test.report/v1" and d["days"]==7 and len(d["daily"])==2' "$out"
run "$repo" report --days 0
check "a non-positive --days is refused" test "$rc" -eq 2
run "$repo" changed --days 3
check "--days belongs to report" test "$rc" -eq 2

# --- the doctor trend NOTE ------------------------------------------------------
repo="$work/trend"
make_repo "$repo" "$(config null)"
for d in 1 2 3; do seed "$repo" bead "$d" 500; done
for d in 8 9 10; do seed "$repo" bead "$d" 300; done
doctor=$(NOGGING_ROOT="$repo" "$nogg" doctor 2>&1 || true)
check "a suite that grows prints a NOTE naming stage and change" has "$doctor" "NOTE  test trend: the bead stage's median rose 67%"
repo="$work/few"
make_repo "$repo" "$(config null)"
for d in 1 2; do seed "$repo" bead "$d" 500; done
for d in 8 9 10; do seed "$repo" bead "$d" 300; done
doctor=$(NOGGING_ROOT="$repo" "$nogg" doctor 2>&1 || true)
check "too few runs print no trend NOTE" lacks "$doctor" "test trend:"

# --- nogg test bead: the Bead's test-line budget ---------------------------------
repo="$work/budget"
make_repo "$repo" "$(config '{"stages": {"bead": "true"}}' '{"bead_test_lines": [1, 5]}')"
git -C "$repo" switch -q -c feat/example
printf 'def test_big():\n%s' "$(printf '    assert %s\n' 1 2 3 4 5 6 7 8)" >"$repo/big_test.py"
git -C "$repo" add -A && git -C "$repo" commit -qm "feat: example [SPEC-t1]"
run "$repo" bead --base develop
check "a Bead above its test budget keeps the stage's exit code" test "$rc" -eq 0
check "it names the count" has "$out" "9 test lines"
check "it names the budget" has "$out" "maximum of 5"
check "the record is the stage's own" test "$(last "$repo" 'r["status"], r["exit"]')" = "('passed', 0)"
repo="$work/inrange"
make_repo "$repo" "$(config '{"stages": {"bead": "true"}}')"
git -C "$repo" switch -q -c feat/example
printf 'def test_new():\n    assert 1\n' >"$repo/new_test.py"
git -C "$repo" add -A && git -C "$repo" commit -qm "feat: example [SPEC-t1]"
run "$repo" bead --base develop
check "a Bead inside the budget prints its count" has "$out" "test lines: 2 (task_sizing.bead_test_lines 1-1500)"

# --- nogg test bead: the integrity rule -------------------------------------------
repo="$work/consumer"
make_repo "$repo" "$(config null)"
git -C "$repo" switch -q -c feat/example
git -C "$repo" rm -q calc_test.py
git -C "$repo" commit -qm "test: drop calc tests [SPEC-t1]"
run "$repo" bead --base develop
check "the default in a consumer: the finding prints" has "$out" "FLAGGED"
check "the default in a consumer: the exit code is the stage's own" test "$rc" -eq 0
check "the stage ran its fallback" test "$(last "$repo" 'r["status"]')" = passed

repo="$work/enforced"
make_repo "$repo" "$(config '{"integrity": "enforce"}')"
git -C "$repo" switch -q -c feat/example
git -C "$repo" rm -q calc_test.py
git -C "$repo" commit -qm "test: drop calc tests [SPEC-t1]"
run "$repo" bead --base develop
check "at enforce an uncleared finding fails the stage" test "$rc" -eq 1
check "the record says failed" test "$(last "$repo" 'r["status"], r["exit"]')" = "('failed', 1)"

repo="$work/own-failure"
make_repo "$repo" "$(config '{"integrity": "enforce", "stages": {"bead": "false"}}')"
run "$repo" bead --base develop
check "a stage that fails keeps its own code" test "$rc" -eq 1

repo="$work/unresolved"
make_repo "$repo" "$(config null)"
run "$repo" bead --base nowhere
check "a base that does not resolve is reported without changing the code" has "$out" "did not resolve"
check "and the stage's code stays" test "$rc" -eq 0

# --- nogg test integrity -----------------------------------------------------------
bd="$work/bd"
cat >"$bd" <<'SH'
#!/usr/bin/env bash
[[ "$1 $2" == "show SPEC-t1" ]] || exit 1
printf '[{"id":"SPEC-t1","labels":%s}]\n' "${BD_LABELS:-[]}"
SH
chmod +x "$bd"
weakened() { # <dir> <config>: develop plus a branch that justifies deleting a test with a trailer
  make_repo "$1" "$2"
  git -C "$1" switch -q -c feat/example
  git -C "$1" rm -q calc_test.py
  git -C "$1" commit -q -m "test: drop obsolete tests [SPEC-t1]" -m "Test-Integrity: the module they covered is gone"
}
repo="$work/trailer"
weakened "$repo" "$(config '{"integrity": "enforce"}' null "$bd")"
rc=0; out=$(BD_LABELS='[]' NOGGING_ROOT="$repo" "$nogg" test integrity --base develop 2>&1) || rc=$?
check "a trailer without a discovery note is flagged" has "$out" "Bead SPEC-t1 has no \`discovery\` label"
check "and fails at enforce" test "$rc" -eq 1
rc=0; out=$(BD_LABELS='["discovery"]' NOGGING_ROOT="$repo" "$nogg" test integrity --base develop 2>&1) || rc=$?
check "a trailer with the note passes" test "$rc" -eq 0
check "and prints the finding as justified" has "$out" "justified"
repo="$work/notracker"
weakened "$repo" "$(config '{"integrity": "enforce"}' null "$work/missing-bd")"
run "$repo" integrity --base develop
check "an unreachable tracker is no gap" test "$rc" -eq 0
repo="$work/report-mode"
weakened "$repo" "$(config null null "$bd")"
rc=0; out=$(BD_LABELS='[]' NOGGING_ROOT="$repo" "$nogg" test integrity --base develop 2>&1) || rc=$?
check "at report the gap prints and the code stays 0" test "$rc" -eq 0 -a -n "$(grep -F 'no `discovery` label' <<<"$out")"
run "$repo" integrity --base nowhere
check "an unresolved base is exit 2" test "$rc" -eq 2

[[ $fail -eq 0 ]] && echo "nogg-test-report: all checks passed" || { echo "nogg-test-report: FAILED"; exit 1; }
