#!/usr/bin/env bash
# scripts/test runs a consumer repository's own tests, not Nogging's shipped
# self-tests: the *.test.sh files .nogging/installed-manifest.json records are
# skipped unless NOGG_SELFTEST=1. The Nogging repository itself (no installed
# manifest) runs everything. scripts/cli.test.sh covers the same behaviour in a
# real init and update.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

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

if [[ $fail -ne 0 ]]; then
  echo "selftest scope checks failed" >&2
  exit 1
fi
echo "all selftest scope checks passed"
