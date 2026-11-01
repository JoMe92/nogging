#!/usr/bin/env bash
# `nogg test nightly`: the gates and the record are small cases in
# scripts/lib/testing_nightly_test.py; this file runs real firings on a temporary
# repository with a bare origin, and with a stub suite. Offline, a private slot root,
# no systemd: the units are covered by scripts/cli.test.sh.
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

if [[ -f "$here/lib/testing_nightly_test.py" ]]; then
  python3 "$here/lib/testing_nightly_test.py" >"$work/unit.out" 2>&1 && ok "testing_nightly_test.py" \
    || { bad "testing_nightly_test.py"; cat "$work/unit.out"; }
fi

# One firing with the host's facts injected: nogg stays a real file, its git and its
# inner `test full --nightly` stay real processes.
cat >"$work/fire.py" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
sys.dont_write_bytecode = True
m = SourceFileLoader("nogg_nightly", sys.argv[1]).load_module()
m.test_nightly_host = lambda: (float(sys.argv[2]), 4, int(sys.argv[3]))
m.test_nightly()
PY
fire() { # <load> <hour>: sets rc and out
  rc=0
  out=$(cd "$main" && NOGGING_ROOT="$main" SUITE_RUNS="$work/suite-runs" python3 "$work/fire.py" "$nogg" "$1" "$2" 2>&1) || rc=$?
}
suite_runs() { if [[ -f "$work/suite-runs" ]]; then wc -l <"$work/suite-runs" | tr -d ' '; else echo 0; fi; }
state() { echo "$main/.nogging/state/testing"; }
record() { # <python expression over r>: a field of nightly-last.json
  python3 - "$(state)/nightly-last.json" "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
PY
}
last_run() { # <python expression over r>: a field of the newest run record
  python3 - "$(state)/runs.jsonl" "$1" <<'PY'
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
print(eval(sys.argv[2]))
PY
}
make_main() { # <testing block as JSON>
  rm -rf "$work/repo" "$work/origin.git" "$work/suite-runs"
  mkdir -p "$work/repo"
  main="$work/repo/main"
  mkdir -p "$main/.nogging"
  git init -q --bare -b develop "$work/origin.git"
  git -C "$main" init -q -b develop
  git -C "$main" remote add origin "$work/origin.git"
  python3 - "$main/.nogging/config.json" "$1" <<'PY'
import json, sys
config = {"name": "fixture", "beads_command": "bd", "testing": json.loads(sys.argv[2])}
open(sys.argv[1], "w").write(json.dumps(config))
PY
  cat >"$main/suite.sh" <<'SH'
#!/usr/bin/env bash
pwd >>"$SUITE_RUNS"
if [[ -f failing ]]; then
  echo "=== tests/a"
  echo "FAIL - tests/a"
  exit 1
fi
echo "PASS - tests/a"
SH
  chmod +x "$main/suite.sh"
  printf '.nogging/state/\n.nogging/locks/\nnode_modules/\n' >"$main/.gitignore"
  commit_and_push "chore: start"
}
commit_and_push() { # <subject>
  git -C "$main" add -A
  git -C "$main" commit -qm "$1"
  git -C "$main" push -q origin develop
}
new_commit() { date +%N >"$main/changed"; commit_and_push "chore: change $1"; }
head_of() { git -C "$main" rev-parse HEAD; }

block='{"stages": {"full": "./suite.sh"}}'

# --- a first run --------------------------------------------------------------
make_main "$block"
fire 0.1 2
check "a run exits 0 when the suite passes" test "$rc" -eq 0
check "the suite ran once" test "$(suite_runs)" -eq 1
check "it ran in the sibling worktree" test "$(cat "$work/suite-runs")" = "$main-nightly"
check "the record says passed" test "$(record 'r["status"]')" = passed
check "the record holds the commit" test "$(record 'r["head"]')" = "$(head_of)"
check "the record names the log" test "$(record 'r["log"]')" = .nogging/state/testing/nightly-last.log
check "the record has a run ID, a time and seconds" test "$(record 'bool(r["run_id"] and r["at"] and r["seconds"] >= 0)')" = True
check "the record is not offline" test "$(record 'r["offline"]')" = False
check "the inner stage left a nightly run record" test "$(last_run 'r["stage"], r["trigger"], r["head"]')" = "('full', 'nightly', '$(head_of)')"
check "the worktree is detached" test -z "$(git -C "$main-nightly" branch --show-current)"
check "the worktree is at the commit" test "$(git -C "$main-nightly" rev-parse HEAD)" = "$(head_of)"

# --- the commit is already tested ---------------------------------------------
fire 0.1 2
check "an already tested commit exits 0" test "$rc" -eq 0
check "no test runs for it" test "$(suite_runs)" -eq 1
check "the skip is recorded" test "$(last_run 'r["stage"], r["status"]')" = "('nightly', 'skipped')"
check "the skip says why" has "$(last_run 'r["reason"]')" "already tested"

# --- a busy host --------------------------------------------------------------
new_commit busy
head=$(head_of)
fire 9.0 2
check "a busy host defers" test "$(suite_runs)" -eq 1
check "the deferral exits 0" test "$rc" -eq 0
check "the deferral is recorded" has "$(last_run 'r["reason"]')" "deferred: load 9.00"
check "the deferral leaves the record alone" test "$(record 'r["head"]')" != "$head"
fire 9.0 5
check "the 05:17 firing runs regardless of load" test "$(suite_runs)" -eq 2
check "that run tested the new commit" test "$(record 'r["head"]')" = "$head"

# --- a held heavy slot --------------------------------------------------------
new_commit slot
mkdir -m 700 -p "$NOGG_TEST_SLOT_ROOT"
slot="$NOGG_TEST_SLOT_ROOT/slot.1"
( exec 9>"$slot"; flock 9; printf bead >&9; exec sleep 60 ) &
holder=$!
until ! flock -n "$slot" true; do sleep 0.05; done
fire 0.1 3
check "a held heavy slot defers" test "$(suite_runs)" -eq 2
check "the deferral names the holder" has "$(last_run 'r["reason"]')" "held by bead"
kill "$holder"; wait "$holder" 2>/dev/null || true
fire 0.1 4
check "a free slot runs" test "$(suite_runs)" -eq 3

# --- offline ------------------------------------------------------------------
new_commit offline
head=$(head_of)
mv "$work/origin.git" "$work/origin.away"
fire 0.1 2
mv "$work/origin.away" "$work/origin.git"
check "offline: the run uses the last known commit" test "$(record 'r["head"]')" = "$head"
check "offline: the record says so" test "$(record 'r["offline"]')" = True
check "offline: the suite ran" test "$(suite_runs)" -eq 4

# --- the worktree is retained and cleaned; the shared checkout is untouched -------
new_commit retained
mkdir "$main-nightly/node_modules"; : >"$main-nightly/node_modules/kept"
: >"$main-nightly/untracked"; echo edited >"$main-nightly/suite.sh.edit"; echo edited >>"$main-nightly/changed"
echo work >"$main/dirty"; echo staged >"$main/staged"; git -C "$main" add staged
before=$(git -C "$main" status --porcelain=v2 --branch; git -C "$main" ls-files -s; git -C "$main" diff; cat "$main/dirty")
head=$(head_of)
fire 0.1 2
after=$(git -C "$main" status --porcelain=v2 --branch; git -C "$main" ls-files -s; git -C "$main" diff; cat "$main/dirty")
check "the shared checkout's branch, index and tree are unchanged" test "$before" = "$after"
check "the worktree moved to the new commit" test "$(git -C "$main-nightly" rev-parse HEAD)" = "$head"
check "an edit in the worktree is gone" test -z "$(git -C "$main-nightly" status --porcelain)"
check "untracked files are gone" test ! -e "$main-nightly/untracked"
check "ignored files survive" test -f "$main-nightly/node_modules/kept"
git -C "$main" reset -q --hard HEAD; rm -f "$main/dirty"

# --- a failure, then a later pass ------------------------------------------------
: >"$main/failing"; commit_and_push "test: fail"
fire 0.1 2
check "a failed run exits with the suite's code" test "$rc" -eq 1
check "the record says failed" test "$(record 'r["status"]')" = failed
check "the record names the failed test" test "$(record 'r["failed"]')" = "['tests/a']"
log="$main/$(record 'r["log"]')"
check "the log holds the whole run, not a tail" grep -qxF "=== tests/a" "$log"
check "the log survives the stage's pruning" test "$(stat -c %i "$log")" != "$(stat -c %i "$(state)"/logs/full-*.0.log | tail -1)"
git -C "$main" rm -q failing; commit_and_push "fix: pass"
fire 0.1 2
check "a later run passes" test "$(record 'r["status"], r["failed"]')" = "('passed', [])"

# --- JUnit names reach the record through the stage's own run record --------------
make_main '{"stages": {"full": "./junit.sh {junit}"}}'
cat >"$main/junit.sh" <<'SH'
#!/usr/bin/env bash
printf '<testsuite><testcase classname="pkg" name="broken"><failure/></testcase></testsuite>' >"$1"
exit 3
SH
chmod +x "$main/junit.sh"; commit_and_push "test: junit"
fire 0.1 2
check "a JUnit failure exits with the runner's code" test "$rc" -eq 3
check "the record names the JUnit test" test "$(record 'r["failed"]')" = "['pkg.broken']"

# --- the full lock counts the record for three days -----------------------------
rc=0; out=$(NOGGING_ROOT="$main" "$nogg" test full 2>&1) || rc=$?
check "a fresh record locks the full stage" test "$rc" -eq 77
has "$out" "nightly" && ok "the refusal names the nightly run" || bad "the refusal names the nightly run"

# --- the setup commands run first, in the worktree --------------------------------
make_main '{"stages": {"full": "./suite.sh"}, "nightly": {"setup": ["./setup.sh"]}}'
printf '#!/usr/bin/env bash\npwd >"$SUITE_RUNS.setup"\nexit "$(cat setup-exit)"\n' >"$main/setup.sh"
chmod +x "$main/setup.sh"; echo 0 >"$main/setup-exit"; commit_and_push "chore: setup"
fire 0.1 2
check "setup ran in the worktree" test "$(cat "$work/suite-runs.setup")" = "$main-nightly"
check "the suite ran after it" test "$(suite_runs)" -eq 1
echo 7 >"$main/setup-exit"; commit_and_push "chore: broken setup"
fire 0.1 2
check "a failed setup exits with its code" test "$rc" -eq 7
check "a failed setup runs no test" test "$(suite_runs)" -eq 1
check "the record says the setup failed" test "$(record 'r["status"], r["step"]')" = "('failed', 'setup')"

make_main '{"stages": {"full": "./suite.sh"}, "nightly": {"setup": ["sudo true"]}}'
fire 0.1 2
check "a denied setup command runs nothing" test "$(suite_runs)" -eq 0
check "it is a failed setup" test "$(record 'r["status"], r["step"]')" = "('failed', 'setup')"

# --- an occupied worktree path ---------------------------------------------------
make_main "$block"
mkdir "$main-nightly"; echo mine >"$main-nightly/precious"
fire 0.1 2
check "an occupied path fails the run" test "$rc" -eq 1
check "it says the worktree step failed" test "$(record 'r["step"]')" = worktree
check "what lies there is left alone" test "$(cat "$main-nightly/precious")" = mine
check "no test ran" test "$(suite_runs)" -eq 0
rm -rf "$main-nightly"; git -C "$main" worktree prune

# --- a run that never gets a slot tested nothing ----------------------------------
make_main '{"stages": {"full": "./suite.sh"}, "max_parallel_heavy": 1, "slot_wait_seconds": 1}'
( exec 9>"$slot"; flock 9; printf bead >&9; exec sleep 60 ) &
holder=$!
until ! flock -n "$slot" true; do sleep 0.05; done
fire 0.1 5
kill "$holder"; wait "$holder" 2>/dev/null || true
check "no slot: exit 0" test "$rc" -eq 0
check "no slot: no record, so the commit runs again" test ! -e "$(state)/nightly-last.json"
check "no slot: the skip is recorded" has "$(last_run 'r["reason"]')" "no heavy test slot"

# --- a worktree whose directory went away ---------------------------------------
make_main "$block"
fire 0.1 2
rm -rf "$main-nightly"
new_commit gone
fire 0.1 2
check "a removed worktree comes back" test "$(git -C "$main-nightly" rev-parse HEAD)" = "$(head_of)"

# --- quiet exits -----------------------------------------------------------------
make_main '{"stages": {"full": "./suite.sh"}, "nightly": {"enabled": false}}'
fire 0.1 2
check "disabled: exit 0" test "$rc" -eq 0
check "disabled: no test runs" test "$(suite_runs)" -eq 0
check "disabled: nothing is recorded" test ! -e "$(state)/runs.jsonl"
check "disabled: no worktree" test ! -e "$main-nightly"

make_main "$block"
rc=0; out=$(cd "$main" && NOGGING_ROOT="$main" NOGG_SESSION_NAME=some-lead "$nogg" test nightly 2>&1) || rc=$?
check "a session: exit 0" test "$rc" -eq 0
check "a session: no test runs" test "$(suite_runs)" -eq 0
check "a session: no worktree" test ! -e "$main-nightly"
rc=0; out=$(NOGGING_ROOT="$main" "$nogg" test nightly --bead SPEC-x 2>&1) || rc=$?
check "--bead is refused" test "$rc" -eq 2

# --- CI runs the tests ------------------------------------------------------------
make_main "$block"
mkdir -p "$main/.github/workflows"; printf 'name: ci\non: push\n' >"$main/.github/workflows/ci.yml"
commit_and_push "ci: add"
mkdir -p "$(state)"
python3 - "$(state)/ci-check.json" <<'PY'
import json, sys, time
json.dump({"result": "ran", "last_test_at": time.time(), "checked_at": time.time(),
           "branch": "develop", "job_pattern": "test"}, open(sys.argv[1], "w"))
PY
fire 0.1 2
check "CI runs the tests: exit 0" test "$rc" -eq 0
check "CI runs the tests: no test runs" test "$(suite_runs)" -eq 0
check "CI runs the tests: the skip is recorded" has "$(last_run 'r["status"], r["reason"]')" "CI runs the tests"
check "CI runs the tests: no nightly record" test ! -e "$(state)/nightly-last.json"

# An `unknown` result runs: no gh, no GitHub remote, so a workflow alone proves nothing.
rm "$(state)/ci-check.json"
fire 0.1 2
check "an unknown CI result runs" test "$(suite_runs)" -eq 1

[[ $fail -eq 0 ]] && echo "all nogg test nightly checks passed"
exit "$fail"
