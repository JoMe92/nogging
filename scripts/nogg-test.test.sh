#!/usr/bin/env bash
# `nogg test changed|commit|bead|full`: the pure tables are small cases in
# scripts/lib/testing_*_test.py; this file runs the command on temporary
# repositories, and takes real flock slots across real processes. Offline; every
# runner is a stub script, and a private slot root keeps this suite off the
# host's real slots.
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
count() { if [[ -z "$1" ]]; then echo 0; else wc -l <<<"$1" | tr -d ' '; fi; }

for unit in testing_stages_test.py testing_runs_test.py; do
  if [[ -f "$here/lib/$unit" ]]; then
    python3 "$here/lib/$unit" >"$work/unit.out" 2>&1 && ok "$unit" || { bad "$unit"; cat "$work/unit.out"; }
  fi
done

# A repository whose `record` stub logs its argv, one argument per line, to args.log.
make_repo() { # <dir> [testing block as JSON]
  local dir="$1" block="${2:-null}"
  mkdir -p "$dir/.nogging" "$dir/scripts"
  git -C "$dir" init -q -b develop
  python3 - "$dir/.nogging/config.json" "$block" <<'PY'
import json, sys
config = {"name": "fixture", "beads_command": "bd"}
block = json.loads(sys.argv[2])
if block is not None:
    config["testing"] = block
open(sys.argv[1], "w").write(json.dumps(config))
PY
  cat >"$dir/record" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>args.log
exit "${RECORD_EXIT:-0}"
SH
  chmod +x "$dir/record"
  printf '.nogging/state/\n.nogging/locks/\nargs.log\nrecord\n' >"$dir/.gitignore"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: start"
}
stages() { python3 -c 'import json,sys; print(json.dumps({"stages": {sys.argv[1]: sys.argv[2]}}))' "$1" "$2"; }
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

# --- a configured stage runs quietly -------------------------------------------
repo="$work/quiet"
make_repo "$repo" "$(stages changed './record {test_files}')"
: >"$repo/a.test.sh"; : >"$repo/plain.py"
run "$repo" changed
check "a configured stage passes" test "$rc" -eq 0
check "the runner receives exactly the changed test" test "$(cat "$repo/args.log")" = "./a.test.sh"
check "a passing run prints one summary line" test "$(count "$out")" -eq 1
check "the line is run-quiet's" has "$out" "ok: ./record ./a.test.sh"
check "the log is kept in the state directory" has "$out" ".nogging/state/testing/logs/changed-"
check "the record says passed" test "$(last "$repo" 'r["status"]')" = passed
check "the record holds no command line" bash -c '! grep -q "record" "$1"' _ "$repo/.nogging/state/testing/runs.jsonl"

# --- a file name cannot become an option ---------------------------------------
rm "$repo/args.log" "$repo/a.test.sh"
: >"$repo/-rf.test.sh"
run "$repo" changed
check "a dash file arrives with ./" test "$(cat "$repo/args.log")" = "./-rf.test.sh"
rm -- "$repo/-rf.test.sh" "$repo/args.log"

# --- a command that needs files has none ----------------------------------------
: >"$repo/plain.py"
run "$repo" changed
check "nothing to test exits 0" test "$rc" -eq 0
check "the runner did not run" test ! -e "$repo/args.log"
check "the skip line names the reason" test "$out" = "skipped: changed ran no tests (no changed test files)"
check "the record says skipped" test "$(last "$repo" 'r["status"], r["exit"]')" = "('skipped', 0)"

# --- a failing stage keeps its code, a list stops at the first failure -------------
repo="$work/list"
make_repo "$repo" '{"stages": {"changed": ["./record first", "./record second"], "commit": ["./record one", "./record two"]}}'
run "$repo" changed
check "a list runs in order" test "$(tr '\n' ' ' <"$repo/args.log")" = "first second "
check "a list prints one line per command" test "$(count "$out")" -eq 2
rm "$repo/args.log"
rc=0; out=$(RECORD_EXIT=9 NOGGING_ROOT="$repo" "$nogg" test commit 2>&1) || rc=$?
check "the exit code is the command's own" test "$rc" -eq 9
check "the list stops at the first failure" test "$(cat "$repo/args.log")" = one
check "the record says failed" test "$(last "$repo" 'r["status"], r["exit"]')" = "('failed', 9)"

# --- a denied command stays denied ----------------------------------------------
direct_out=$(NOGGING_ROOT="$work/quiet" "$nogg" run-quiet -- sudo true 2>&1 || true)
repo="$work/floor"
make_repo "$repo" '{"stages": {"changed": ["./record first", "sudo true"]}}'
run "$repo" changed
check "a denied command exits 77" test "$rc" -eq 77
check "and is reported as run-quiet reports it" \
  has "$out" "$(grep -o 'refusing: the wrapped command could run .* a wrapper never lifts them' <<<"$direct_out")"
check "and nothing in the stage ran" test ! -e "$repo/args.log"
check "the refusal is recorded" test "$(last "$repo" 'r["status"]')" = refused

# A session's own deny list applies too, and the session names the record.
repo="$work/session"
make_repo "$repo" '{"stages": {"changed": "git push origin develop", "commit": "true"}}'
mkdir -p "$repo/.nogging/state/sessions"
printf '{"permissions": {"deny": ["Bash(git push:*)"]}}' >"$work/settings.json"
printf '{"name": "lead-x", "role": "lead", "bead_id": "SPEC-session", "state": "running", "effective_settings_path": "%s"}' \
  "$work/settings.json" >"$repo/.nogging/state/sessions/lead-x.json"
rc=0; out=$(NOGG_SESSION_NAME=lead-x NOGGING_ROOT="$repo" "$nogg" test changed 2>&1) || rc=$?
check "a session's deny rule refuses a stage command" test "$rc" -eq 77
check "and names the rule" has "$out" "Bash(git push:*)"
rc=0; out=$(NOGG_SESSION_NAME=lead-x NOGGING_ROOT="$repo" "$nogg" test commit 2>&1) || rc=$?
check "the record names the session, its role and its Bead" \
  test "$(last "$repo" 'r["session"], r["role"], r["bead"]')" = "('lead-x', 'lead', 'SPEC-session')"

# --- budgets report and never kill --------------------------------------------------
repo="$work/budget"
make_repo "$repo" '{"stages": {"changed": "true"}, "budgets": {"changed": 0.0001}}'
run "$repo" changed
check "a green run over budget exits 0" test "$rc" -eq 0
check "and prints the budget line" has "$out" "(testing.budgets.changed)"
check "and records it" test "$(last "$repo" 'r["over_budget"]')" = True

# --- a repository with no testing block ------------------------------------------
repo="$work/plain"
make_repo "$repo"
cat >"$repo/scripts/test" <<'SH'
#!/usr/bin/env bash
printf 'scripts/test %s\n' "$*" >>args.log
for arg in "$@"; do
  if [[ ${prev:-} == --timings ]]; then printf '1.5\tsuite.test.sh\n' >"$arg"; fi
  prev=$arg
done
SH
chmod +x "$repo/scripts/test"
: >"$repo/own.test.sh"
run "$repo" bead
check "no block, no CI: bead runs the whole scripts/test" test "$(cat "$repo/args.log")" = "scripts/test "
rm "$repo/args.log"
run "$repo" changed
check "no block: changed runs the changed test" test "$(cat "$repo/args.log")" = "scripts/test --only ./own.test.sh"
rm "$repo/args.log" "$repo/own.test.sh"
: >"$repo/web.spec.ts"
run "$repo" changed
check "no block: a test scripts/test cannot run is skipped" test "$out" = "skipped: changed ran no tests (no runnable test file changed)"
rm "$repo/web.spec.ts"

# --- a repository with a test-changed script --------------------------------------
cp "$repo/record" "$repo/scripts/test-changed"
git -C "$repo" add -f scripts && git -C "$repo" commit -qm "chore: runners"
: >"$repo/lib.py"
run "$repo" changed
check "test-changed receives the changed paths" test "$(cat "$repo/args.log")" = "./lib.py"
rm "$repo/args.log" "$repo/lib.py"
: >"$repo/untracked.txt"; printf 'x\n' >>"$repo/.gitignore"
run "$repo" commit
check "commit sees tracked changes and untracked files" test "$(tr '\n' ' ' <"$repo/args.log")" = "./.gitignore ./untracked.txt "
git -C "$repo" checkout -q .gitignore; rm "$repo/args.log" "$repo/untracked.txt"
git -C "$repo" rm -q --cached scripts/test-changed; rm "$repo/scripts/test-changed"
run "$repo" changed
check "a deleted path is left out of the change set" lacks "$out" "test-changed"

# --- bead: the branch's diff from the merge-base ---------------------------------
origin="$work/origin.git"; repo="$work/branch"
git init -q --bare "$origin"
make_repo "$repo" "$(python3 -c 'import json; print(json.dumps({"stages": {"bead": "./record {files}"}, "ci": {"branch": "develop"}}))')"
git -C "$repo" remote add origin "$origin"; git -C "$repo" push -q origin develop
mkdir -p "$repo/.github/workflows"; : >"$repo/.github/workflows/ci.yml"
git -C "$repo" checkout -q -b feat/x
: >"$repo/committed.py"; git -C "$repo" add committed.py; git -C "$repo" commit -qm "feat: x [SPEC-abc]"
: >"$repo/dirty.py"
run "$repo" bead
check "bead covers the branch and the uncommitted work" has "$(cat "$repo/args.log")" "./committed.py"
check "and the uncommitted file" has "$(cat "$repo/args.log")" "./dirty.py"
check "the Bead comes from the newest commit token" test "$(last "$repo" 'r["bead"]')" = SPEC-abc
rm "$repo/args.log"
run "$repo" bead --base HEAD --bead SPEC-explicit
check "--base overrides the merge-base" lacks "$(cat "$repo/args.log")" "./committed.py"
check "--bead wins over the commit token" test "$(last "$repo" 'r["bead"]')" = SPEC-explicit
run "$repo" bead --base no-such-ref
check "an unknown --base is an error, not a smaller set" test "$rc" -eq 1
run "$repo" changed --base HEAD
check "--base belongs to the bead stage" test "$rc" -eq 2
run "$repo" changed --release
check "a full flag belongs to the full stage" test "$rc" -eq 2
rm "$repo/dirty.py"

# With no merge-base the stage covers the uncommitted work and says so.
loose="$work/loose"
make_repo "$loose" '{"stages": {"bead": "./record {files}"}}'
: >"$loose/dirty.py"
run "$loose" bead
check "no merge-base still runs the uncommitted work" test "$(cat "$loose/args.log")" = "./dirty.py"
check "and says so after the summary" has "$out" "no merge-base with origin/develop"

# --- the record lands in the main checkout from a linked worktree -------------------
linked="$work/linked"
git -C "$repo" worktree add -q "$linked" -b feat/y
: >"$linked/.gitkeep-testing"
mkdir -p "$linked/.nogging"
before=$(wc -l <"$repo/.nogging/state/testing/runs.jsonl")
run "$linked" changed
check "a linked worktree's record lands in the main checkout" \
  test "$(wc -l <"$repo/.nogging/state/testing/runs.jsonl")" -eq $((before + 1))
check "and no state directory appears in the worktree" test ! -e "$linked/.nogging/state/testing"
check "and it names the worktree's branch" test "$(last "$repo" 'r["branch"]')" = feat/y

# --- the full lock ---------------------------------------------------------------------
repo="$work/full"
make_repo "$repo"
cp "$work/plain/scripts/test" "$repo/scripts/test"
run "$repo" full
check "no CI, no nightly: full runs" test "$rc" -eq 0
check "with the timings path" has "$(cat "$repo/args.log")" "scripts/test --timings "
check "the trigger is recorded" test "$(last "$repo" 'r["trigger"]')" = unlocked
check "a full run prints its slowest tests" has "$out" "slowest: 1.5 s suite.test.sh"
check "the record holds the timings" test "$(last "$repo" 'r["tests"], r["slowest"][0]["name"]')" = "(1, 'suite.test.sh')"
rm "$repo/args.log"
mkdir -p "$repo/.github/workflows"; : >"$repo/.github/workflows/ci.yml"
rc=0; out=$(NOGG_SESSION_ROLE=lead NOGGING_ROOT="$repo" "$nogg" test full 2>&1) || rc=$?
check "a Lead where CI is configured is refused" test "$rc" -eq 77
check "and pointed at nogg test bead" has "$out" "nogg test bead"
check "and nothing ran" test ! -e "$repo/args.log"
check "the refusal is recorded" test "$(last "$repo" 'r["status"], r["trigger"], r["role"]')" = "('refused', 'none', 'lead')"
rc=0; out=$(NOGG_SESSION_ROLE=lead NOGGING_ROOT="$repo" "$nogg" test full --allow-full "migration touches every test" 2>&1) || rc=$?
check "an explicit exception runs" test "$rc" -eq 0
check "and the record holds its reason" test "$(last "$repo" 'r["trigger"], r["reason"]')" = "('allow-full', 'migration touches every test')"
rc=0; out=$(NOGG_SESSION_ROLE=lead NOGGING_ROOT="$repo" "$nogg" test full --release 2>&1) || rc=$?
check "a Lead claiming a release is refused" test "$rc" -eq 77
rc=0; out=$(NOGG_SESSION_ROLE=orchestrator NOGGING_ROOT="$repo" "$nogg" test full --release 2>&1) || rc=$?
check "the Orchestration Agent may release" test "$rc" -eq 0
check "the trigger says release" test "$(last "$repo" 'r["trigger"]')" = release
rc=0; out=$(NOGG_SESSION_ROLE=orchestrator NOGGING_ROOT="$repo" "$nogg" test full --nightly 2>&1) || rc=$?
check "--nightly is refused in any session" test "$rc" -eq 77
run "$repo" full --nightly
check "--nightly runs outside a session" test "$rc" -eq 0
rc=0; out=$(NOGG_SESSION_NAME=ghost NOGGING_ROOT="$repo" "$nogg" test full --release 2>&1) || rc=$?
check "a named session with no record fails closed" test "$rc" -eq 77
rm "$repo/.github/workflows/ci.yml"
mkdir -p "$repo/.nogging/state/testing"
printf '{"at": "%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" >"$repo/.nogging/state/testing/nightly-last.json"
run "$repo" full
check "a recent nightly record locks the full stage" test "$rc" -eq 77
printf '{"at": "2020-01-01T00:00:00Z"}\n' >"$repo/.nogging/state/testing/nightly-last.json"
run "$repo" full
check "an old nightly record does not" test "$rc" -eq 0
printf 'broken' >"$repo/.nogging/state/testing/nightly-last.json"
run "$repo" full
check "a broken nightly record reads as none" test "$rc" -eq 0

# --- result files ---------------------------------------------------------------------
repo="$work/detail"
make_repo "$repo" '{"stages": {"changed": "./junit {junit}", "commit": "./junit {junit} {timings}"}}'
cat >"$repo/junit" <<'SH'
#!/usr/bin/env bash
printf '<testsuite><testcase name="a" time="2"/><testcase name="b" time="1"><failure/></testcase></testsuite>' >"$1"
SH
chmod +x "$repo/junit"
run "$repo" changed
check "JUnit detail reaches the record" test "$(last "$repo" 'r["tests"], r["failed_tests"], r["slowest"][0]')" = "(2, 1, {'name': 'a', 'seconds': 2.0})"
printf '#!/usr/bin/env bash\nprintf "<testsuite><testc" >"$1"; exit 4\n' >"$repo/junit"
run "$repo" changed
check "a broken result file keeps the exit code" test "$rc" -eq 4
check "and the record has no detail" test "$(last "$repo" 'r["tests"], r["slowest"]')" = "(None, [])"

# --- a failed record write never changes the result ------------------------------------
repo="$work/unwritable"
make_repo "$repo" '{"stages": {"changed": "true"}}'
mkdir -p "$repo/.nogging/state"; printf 'in the way' >"$repo/.nogging/state/testing"
run "$repo" changed
check "a failed record write keeps the result" test "$rc" -eq 0
check "and says so once" test "$(grep -c 'run record not written' <<<"$out")" -eq 1

# --- the newest 20 logs are kept -------------------------------------------------------
repo="$work/logs"
make_repo "$repo" '{"stages": {"changed": "true"}}'
mkdir -p "$repo/.nogging/state/testing/logs"
for n in $(seq 1 25); do : >"$repo/.nogging/state/testing/logs/old-$n.log"; done
touch -d '2020-01-01' "$repo"/.nogging/state/testing/logs/old-*.log
run "$repo" changed
check "the newest 20 logs are kept" test "$(ls "$repo/.nogging/state/testing/logs" | wc -l | tr -d ' ')" -eq 20
check "and the newest is this run's" bash -c 'ls "$1" | grep -q "^changed-"' _ "$repo/.nogging/state/testing/logs"

# --- heavy slots: real flock across real processes --------------------------------------
repo="$work/slots-repo"
make_repo "$repo" '{"stages": {"bead": "./hold", "changed": "true"}, "max_parallel_heavy": 2, "slot_wait_seconds": 30}'
cat >"$repo/hold" <<'SH'
#!/usr/bin/env bash
: >"started.$$"
while [[ ! -e release ]]; do sleep 0.02; done
SH
chmod +x "$repo/hold"
printf 'started.*\nrelease\nhold\n' >>"$repo/.gitignore"
git -C "$repo" add .gitignore && git -C "$repo" commit -qm "chore: ignore"
await() { # <description> <test-expr...>: wait up to 20 s, without a fixed sleep
  local desc="$1" tries=0; shift
  until "$@"; do
    tries=$((tries + 1))
    if [[ $tries -gt 2000 ]]; then bad "$desc (timed out)"; return 1; fi
    sleep 0.01
  done
  ok "$desc"
}
started() { test "$(find "$repo" -maxdepth 1 -name 'started.*' | wc -l)" -eq "$1"; }
slot() { # <name>: one background heavy run
  ( rc=0; NOGGING_ROOT="$repo" "$nogg" test bead >"$work/$1.out" 2>&1 || rc=$?; echo "$rc" >"$work/$1.rc" ) &
  eval "pid_$1=$!"
}
slot first; slot second
await "two heavy runs start at once" started 2
slot third
await "a third prints one waiting line" grep -qs "waiting for a heavy test slot" "$work/third.out"
check "and names the holders" grep -q "held by bead, bead" "$work/third.out"
check "and does not start" started 2
: >"$repo/release"
# shellcheck disable=SC2154  # set by eval in slot()
wait "$pid_first" "$pid_second" "$pid_third"
check "the third starts when a slot frees" test "$(cat "$work/third.rc")" -eq 0
check "with one waiting line" test "$(grep -c 'waiting for a heavy' "$work/third.out")" -eq 1
check "its wait is not its run time" test "$(last "$repo" 'r["wait_seconds"] >= 0')" = True
rm -f "$repo"/started.* "$repo/release"

# A crashed holder: the kernel frees the slot with no cleanup step.
python3 - "$repo/.nogging/config.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1])); config["testing"]["max_parallel_heavy"] = 1
config["testing"]["slot_wait_seconds"] = 0
json.dump(config, open(sys.argv[1], "w"))
PY
NOGGING_ROOT="$repo" "$nogg" test bead >"$work/crash.out" 2>&1 &
crash=$!
await "a heavy run holds the only slot" started 1
rc=0; out=$(NOGGING_ROOT="$repo" "$nogg" test bead 2>&1) || rc=$?
check "no slot within the wait exits 75" test "$rc" -eq 75
check "and names the holder's stage" has "$out" "held by bead"
check "the timeout is recorded as refused" test "$(last "$repo" 'r["status"], r["exit"]')" = "('refused', 75)"
kill -9 "$crash"; wait "$crash" 2>/dev/null || true
: >"$repo/release"
rc=0; out=$(NOGGING_ROOT="$repo" "$nogg" test bead 2>&1) || rc=$?
check "after SIGKILL the next run takes the slot" test "$rc" -eq 0
check "with no cleanup and no wait" lacks "$out" "waiting"

# A stage outside heavy_stages takes no slot.
repo2="$work/light"
make_repo "$repo2" '{"stages": {"changed": "true"}, "heavy_stages": []}'
printf 'x' >"$work/not-a-directory"
rc=0; out=$(NOGG_TEST_SLOT_ROOT="$work/not-a-directory/slots" NOGGING_ROOT="$repo2" "$nogg" test changed 2>&1) || rc=$?
check "a light stage never looks at the slots" lacks "$out" "slot"

# The slot directory is unusable: the stage still runs, and says so.
rc=0; out=$(NOGG_TEST_SLOT_ROOT="$work/not-a-directory/slots" NOGGING_ROOT="$repo" "$nogg" test bead 2>&1) || rc=$?
check "an unusable slot directory still runs the stage" test "$rc" -eq 0
check "and says it ran without a slot" has "$out" "running without a heavy test slot"
mkdir -m 0755 "$work/open-slots"
rc=0; out=$(NOGG_TEST_SLOT_ROOT="$work/open-slots" NOGGING_ROOT="$repo" "$nogg" test bead 2>&1) || rc=$?
check "a directory others can enter is not trusted" has "$out" "not a private directory"

# --- doctor names a malformed block and exits as before --------------------------------
repo="$work/doctor"
make_repo "$repo" '{"budgets": {"bead": 1800}}'
rc=0; NOGGING_ROOT="$repo" "$nogg" doctor >"$work/doctor-good.out" 2>&1 || rc=$?; good=$rc
check "a valid block prints no WARN" bash -c '! grep -q "WARN  testing" "$1"' _ "$work/doctor-good.out"
python3 - "$repo/.nogging/config.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config["testing"] = {"budgets": {"bead": "soon"}, "stagez": {}}
json.dump(config, open(sys.argv[1], "w"))
PY
rc=0; NOGGING_ROOT="$repo" "$nogg" doctor >"$work/doctor-bad.out" 2>&1 || rc=$?
check "a bad budget is a WARN naming the key" grep -q "^WARN  testing.budgets.bead" "$work/doctor-bad.out"
check "an unknown key is a WARN" grep -q "^WARN  testing.stagez" "$work/doctor-bad.out"
check "and doctor exits as before" test "$rc" -eq "$good"

if [[ $fail -ne 0 ]]; then
  echo "nogg test checks failed" >&2
  exit 1
fi
echo "all nogg test checks passed"
