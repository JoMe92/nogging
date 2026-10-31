#!/usr/bin/env bash
# scripts/test runs a consumer repository's own tests, not Nogging's shipped
# self-tests: the *.test.sh files .nogging/installed-manifest.json records are
# skipped unless NOGG_SELFTEST=1. The Nogging repository itself (no installed
# manifest) runs everything. scripts/cli.test.sh covers the same behaviour in a
# real init and update.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The opt-in under test; a standalone run must not inherit it.
unset NOGG_SELFTEST

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A repository layout carrying the runner and marker tests that log their name.
make_repo() { # <dir>
  mkdir -p "$1/scripts/lib" "$1/scripts/hooks"
  cp "$root/scripts/test" "$1/scripts/test"
  cp "$root/scripts/lib/test-env.sh" "$1/scripts/lib/test-env.sh"
  local name
  for name in own.test.sh shipped.test.sh hooks/shipped-hook.test.sh; do
    printf '#!/usr/bin/env bash\necho %s >> "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/ran.log"\n' \
      "$name" > "$1/scripts/$name"
  done
  git -C "$1" init -q
}
manifest() { # <dir> <shipped path...>
  local dir="$1"; shift
  mkdir -p "$dir/.nogging"
  {
    printf '{\n  "manifest_version": 1,\n  "nogging_version": "0.0.0",\n  "files": {\n'
    printf '    "scripts/test": "00",\n'
    local rel
    for rel in "$@"; do printf '    "%s": "00",\n' "$rel"; done
    printf '    "scripts/nogg": "00"\n  }\n}\n'
  } > "$dir/.nogging/installed-manifest.json"
}
ran() { sort "$1/ran.log" 2>/dev/null | tr '\n' ' '; }

# --- the Nogging repository: no installed manifest, every test runs ---------
src="$work/source"
make_repo "$src"
out=$("$src/scripts/test")
check "without an installed manifest every test runs" \
  test "$(ran "$src")" = "hooks/shipped-hook.test.sh own.test.sh shipped.test.sh "
check "without an installed manifest nothing is reported skipped" \
  bash -c '! grep -q skipped <<<"$1"' _ "$out"

# --- a consumer: recorded *.test.sh are skipped by default --------------------
consumer="$work/consumer"
make_repo "$consumer"
manifest "$consumer" scripts/shipped.test.sh scripts/hooks/shipped-hook.test.sh
out=$("$consumer/scripts/test")
check "a consumer runs only its own tests" test "$(ran "$consumer")" = "own.test.sh "
check "a consumer reports the skipped self-tests and the opt-in" \
  grep -q "skipped 2 shipped Nogging self-test(s); NOGG_SELFTEST=1 scripts/test runs them" <<<"$out"
check "a skipped self-test prints no === header" bash -c '! grep -q "=== scripts/shipped" <<<"$1"' _ "$out"

rm -f "$consumer/ran.log"
NOGG_SELFTEST=1 "$consumer/scripts/test" >/dev/null
check "NOGG_SELFTEST=1 also runs the shipped self-tests" \
  test "$(ran "$consumer")" = "hooks/shipped-hook.test.sh own.test.sh shipped.test.sh "

# A failing project test still fails the run.
printf '#!/usr/bin/env bash\nexit 1\n' > "$consumer/scripts/broken.test.sh"
rc=0; "$consumer/scripts/test" >/dev/null 2>&1 || rc=$?
check "a failing project test still fails the consumer run" test "$rc" -eq 1
rm "$consumer/scripts/broken.test.sh"

# Only shipped tests present: nothing to run is not an error.
rm "$consumer/scripts/own.test.sh" "$consumer/ran.log"
rc=0; out=$("$consumer/scripts/test" 2>&1) || rc=$?
check "a consumer with no project tests exits 0" test "$rc" -eq 0
check "a consumer with no project tests says so" grep -q "no project \*.test.sh" <<<"$out"
check "a consumer with no project tests runs no self-test" test ! -e "$consumer/ran.log"

# --- scripts/test --only and --timings ------------------------------------------
only="$work/only"
make_repo "$only"
printf 'import sys\nopen("ran.log", "a").write("own_test.py\\n")\nsys.exit(0)\n' >"$only/scripts/own_test.py"
printf '#!/usr/bin/env bash\nexit 5\n' >"$only/scripts/broken.test.sh"
in_only() { (cd "$only" && "$@"); }

rc=0; out=$(in_only scripts/test --only ./scripts/own.test.sh 2>&1) || rc=$?
check "--only runs just that test" test "$(ran "$only")" = "own.test.sh "
check "--only exits 0 on a pass" test "$rc" -eq 0
rm -f "$only/ran.log"
rc=0; in_only scripts/test --only scripts/own_test.py >/dev/null 2>&1 || rc=$?
check "--only runs a *_test.py with python3" test "$(ran "$only")" = "own_test.py "
rm -f "$only/ran.log"
rc=0; out=$(in_only scripts/test --only scripts/broken.test.sh 2>&1) || rc=$?
check "--only keeps a failure" test "$rc" -eq 1
rc=0; out=$(in_only scripts/test --only README.md scripts/absent.test.sh ../outside.test.sh 2>&1) || rc=$?
check "--only exits 0 with nothing runnable" test "$rc" -eq 0
check "--only reports a path of another kind" grep -q "not runnable: README.md" <<<"$out"
check "--only reports a missing test" grep -q "not runnable: scripts/absent.test.sh" <<<"$out"
check "--only reports a path outside the repository" grep -q "not runnable: ../outside.test.sh" <<<"$out"
check "and says nothing ran" grep -q "nothing runnable among the 3" <<<"$out"
rc=0; out=$(in_only scripts/test --only README.md scripts/own.test.sh 2>&1) || rc=$?
check "--only runs what it can beside a reported path" test "$(ran "$only")" = "own.test.sh "
rm -f "$only/ran.log"
printf '#!/usr/bin/env bash\necho dash >>ran.log\n' >"$only/-rf.test.sh"
in_only scripts/test --only ./-rf.test.sh >/dev/null 2>&1
check "--only runs a file named like an option" test "$(ran "$only")" = "dash "
rm -f "$only/ran.log" "$only/-rf.test.sh"
(cd "$only/scripts" && ./test --only own.test.sh >/dev/null 2>&1)
check "--only resolves a path from the calling directory" test "$(ran "$only")" = "own.test.sh "
rm -f "$only/ran.log"
rc=0; out=$(in_only scripts/test --only 2>&1) || rc=$?
check "--only with no path is a usage error" test "$rc" -eq 2
rc=0; out=$(in_only scripts/test --nonsense 2>&1) || rc=$?
check "an unknown option is a usage error" test "$rc" -eq 2

# An option survives test-env.sh, which clears every NOGG_* variable.
rc=0; in_only scripts/test --only scripts/own.test.sh --timings "$work/t.tsv" >/dev/null 2>&1 || rc=$?
check "--timings writes one line per test" test "$(wc -l <"$work/t.tsv" | tr -d ' ')" -eq 1
check "--timings writes <seconds><TAB><name>" grep -Eq '^[0-9]+\.[0-9]{3}'$'\t''scripts/own\.test\.sh$' "$work/t.tsv"
rm -f "$only/ran.log" "$only/scripts/broken.test.sh" "$only/scripts/own_test.py"
in_only scripts/test --timings "$work/all.tsv" >/dev/null 2>&1
check "--timings covers a whole run" test "$(wc -l <"$work/all.tsv" | tr -d ' ')" -eq 3
rm -f "$only/ran.log"
rc=0; out=$(in_only scripts/test --only scripts/own.test.sh --timings "$work/no/such/dir/t.tsv" 2>&1) || rc=$?
check "an unwritable timings file does not fail the run" test "$rc" -eq 0
check "and says so" grep -q "running without timings" <<<"$out"

# Self-test exclusion still applies to what --only selects.
manifest "$only" scripts/shipped.test.sh
rm -f "$only/ran.log"
rc=0; out=$(in_only scripts/test --only scripts/shipped.test.sh 2>&1) || rc=$?
check "--only never runs a shipped self-test" test ! -e "$only/ran.log"
check "and that is no failure" test "$rc" -eq 0
in_only env NOGG_SELFTEST=1 scripts/test --only scripts/shipped.test.sh >/dev/null 2>&1
check "NOGG_SELFTEST=1 still opts in" test "$(ran "$only")" = "shipped.test.sh "

if [[ $fail -ne 0 ]]; then
  echo "selftest scope checks failed" >&2
  exit 1
fi
echo "all selftest scope checks passed"
