#!/usr/bin/env bash
# The whole test-policy change, end to end, from a packed install (TASK-TPC-007).
# Offline: `gh`, `bd` and `systemctl` are stubs on PATH, HOME and CODEX_HOME are
# scratch directories, and no systemd unit is installed or enabled.
#
# Scenario 1: the previous release is installed in a repository with a plain
# scripts/*.test.sh, then updated from the packed tree. Nothing but the notice
# may change, and every row of design Decision 14 holds with no `testing` block.
# Scenario 2: the same repository gets a `testing` block with a stub runner that
# writes JUnit and exceeds a budget.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/lib/test-env.sh
source "$root/scripts/lib/test-env.sh"
# The newest stable release tag older than the version under test: the install an
# existing consumer has today. Once the release's own tag exists it must not be
# picked, or the "upgrade" would start from the tree under test.
current=$(node -e 'console.log(require(process.argv[1]).version)' "$root/package.json")
previous=$(git -C "$root" tag -l 'v[0-9]*' 2>/dev/null | grep -v -- - | grep -vxF "v$current" \
  | { cat; echo "v$current"; } | sort -V | grep -xF -B1 "v$current" | grep -vxF "v$current" || true)
if [[ -z $previous ]]; then
  printf 'SKIP: packed test control (no release tag to upgrade from)\n'; exit 0
fi
work=$(mktemp -d)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$work"' EXIT

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

mkdir -p "$work/bin" "$work/home" "$work/codex" "$work/old" "$work/consumer"
export HOME="$work/home" CODEX_HOME="$work/codex" TMPDIR="$work" NOGG_TEST_SLOT_ROOT="$work/slots"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
cat >"$work/bin/bd" <<'SH'
#!/usr/bin/env bash
# One mapped Bead: the legacy task below was approved before the full-suite rule.
if [[ ${1:-} == list ]]; then
  echo '[{"id":"SPEC-legacy","status":"open","labels":["openspec:change:legacy","openspec:task:TASK-LEG-001"]}]'
  exit 0
fi
exit 1
SH
printf '#!/usr/bin/env bash\nexit 1\n' >"$work/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/systemctl"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

(cd "$root" && npm pack --ignore-scripts --json --pack-destination "$work" >"$work/pack.json" 2>/dev/null)
archive=$(node -e 'console.log(require(process.argv[1])[0].filename)' "$work/pack.json")
mkdir "$work/new"
tar -xzf "$work/$archive" -C "$work/new" --strip-components=1
git -C "$root" archive "$previous" | tar -x -C "$work/old"

c="$work/consumer"
git -C "$c" init -q -b develop
flags=(--no-beads --no-hooks --no-systemd)
(cd "$c" && node "$work/old/bin/cli.js" init "${flags[@]}" >"$work/init.out" 2>&1) || { cat "$work/init.out"; exit 1; }
mkdir -p "$c/openspec/changes/legacy"
printf '#!/usr/bin/env bash\necho own-ran >>"$(dirname "$0")/../own.log"\n' >"$c/scripts/own.test.sh"
chmod +x "$c/scripts/own.test.sh"
printf '# Tasks\n\n- [ ] TASK-LEG-001 Approved before the rule\n  Check: scripts/test. Branch docs/.\n' \
  >"$c/openspec/changes/legacy/tasks.md"
printf '.nogging/state/\n.nogging/locks/\nown.log\n' >>"$c/.gitignore"
git -C "$c" add -A && git -C "$c" commit -qm "chore: install the previous release"
cp "$c/.nogging/config.json" "$work/config.before"

in_c() { (cd "$c" && NOGGING_ROOT="$c" "$@"); }
run() { rc=0; out=$(in_c "$@" 2>&1) || rc=$?; } # sets rc and out, streams merged
doctor_before=0; in_c ./scripts/nogg doctor >"$work/doctor.before" 2>&1 || doctor_before=$?

# --- scenario 1: update from the previous release, no testing block ---------------
run node "$work/new/bin/cli.js" update "${flags[@]}"
check "update succeeds" test "$rc" -eq 0
# A previous release that already writes a testing block gets no notice: assert absence.
if grep -q '"testing"' "$work/config.before"; then
  check "no notice when the previous release already has a testing block" lacks "$out" "runs on its defaults here"
else
  check "the notice appears once" test "$(grep -c 'runs on its defaults here' <<<"$out")" -eq 1
  check "and points at the stages and the page" has "$out" "testing.stages"
fi
# update records the installed version (nogging_version); every other byte must stay.
without_version() { grep -v '"nogging_version"' "$1"; }
check "the config is byte-identical" cmp -s <(without_version "$c/.nogging/config.json") <(without_version "$work/config.before")
doctor_after=0; in_c ./scripts/nogg doctor >"$work/doctor.out" 2>&1 || doctor_after=$?
check "doctor keeps its exit code" test "$doctor_after" -eq "$doctor_before"
check "and gains no FAIL line" test "$(grep -c '^FAIL' "$work/doctor.out")" -le "$(grep -c '^FAIL' "$work/doctor.before")"
git -C "$c" add -A && git -C "$c" commit -qm "chore: update to the packed tree"

run ./scripts/nogg validate
check "validate passes with a mapped legacy Check: scripts/test" test "$rc" -eq "$doctor_before"
check "and names it in a NOTE" bash -c 'grep -q "^NOTE.*TASK-LEG-001" <<<"$1"' _ "$out"
check "and prints no task-format FAIL" lacks "$out" "FAIL  task format"

: >"$c/own.log"
run ./scripts/nogg test changed
check "changed with nothing changed is skipped" has "$out" "skipped"
printf '#!/usr/bin/env bash\necho changed-ran >>"$(dirname "$0")/../own.log"\n' >"$c/scripts/new.test.sh"
chmod +x "$c/scripts/new.test.sh"
run ./scripts/nogg test changed
check "changed runs the changed *.test.sh and passes" test "$rc" -eq 0
check "and only that one" test "$(cat "$c/own.log")" = changed-ran
run ./scripts/nogg test commit
check "commit behaves as changed" test "$rc" -eq 0
git -C "$c" add -A && git -C "$c" commit -qm "test: add a project test"

: >"$c/own.log"
run ./scripts/nogg test bead --bead SPEC-legacy
check "with no CI, bead runs scripts/test" test "$rc" -eq 0
check "and the project tests ran" has "$(cat "$c/own.log")" own-ran
run ./scripts/nogg test full
check "with no CI, full runs" test "$rc" -eq 0
run ./scripts/test
check "scripts/test skips the shipped self-tests" has "$out" "skipped"
check "and says how to run them" has "$out" "NOGG_SELFTEST=1"
check "and ran no shipped test" lacks "$out" "=== scripts/nogg"

mkdir -p "$c/.github/workflows"
printf 'name: ci\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps: [{run: scripts/test}]\n' \
  >"$c/.github/workflows/ci.yml"
rc=0; out=$(NOGG_SESSION_ROLE=lead in_c ./scripts/nogg test full 2>&1) || rc=$?
check "with CI configured, a Lead's full is refused" test "$rc" -eq 77
check "and pointed at nogg test bead" has "$out" "nogg test bead"

# --- scenario 2: a configured testing block with a stub runner ---------------------
cat >"$c/stub-runner" <<'SH'
#!/usr/bin/env bash
printf '<testsuite><testcase name="fast" time="0.5"/><testcase name="slow" time="2.5"/></testsuite>' >"$1"
sleep 0.2
SH
chmod +x "$c/stub-runner"
python3 - "$c/.nogging/config.json" <<'PY'
import json, sys
path = sys.argv[1]
config = json.load(open(path))
config["testing"] = {"stages": {"changed": "./stub-runner {junit}"}, "budgets": {"changed": 0.01}}
json.dump(config, open(path, "w"))
PY
printf 'touched\n' >"$c/touched.txt"
run ./scripts/nogg test changed
check "a green run over its budget still exits 0" test "$rc" -eq 0
check "and prints the budget line" has "$out" "over budget: changed took"
check "naming the budget key" has "$out" "(testing.budgets.changed)"
check "and the slowest tests, slowest first" has "$out" "slowest: 2.5 s slow"
state="$c/.nogging/state/testing/runs.jsonl"
check "a record was written" test -s "$state"
check "and it holds the budget overrun and the timings" python3 -c '
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert r["over_budget"] is True and r["tests"] == 2 and r["slowest"][0]["name"] == "slow", r
' "$state"
rc=0; out=$(NOGG_SESSION_ROLE=lead in_c ./scripts/nogg test full 2>&1) || rc=$?
check "full is still refused for a Lead where CI is configured" test "$rc" -eq 77
run ./scripts/nogg test report
check "nogg test report lists the run" test "$rc" -eq 0
check "with the changed stage over its budget once" bash -c 'grep -Eq "changed +2 +0 +[0-9.]+ +1" <<<"$1"' _ "$out"
check "and its slowest test" has "$out" "2.5 s  slow  (changed)"

if [[ $fail -ne 0 ]]; then echo "packed test control checks failed" >&2; exit 1; fi
echo "all packed test control checks passed"
