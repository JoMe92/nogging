#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { case "$tmp" in /tmp/tmp.*) rm -rf -- "$tmp" ;; esac; }
trap cleanup EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
fail_() { printf 'FAIL - %s\n' "$1" >&2; fail=1; }

# A real GitHub install spec needs network; this exercises the same
# mechanism (npx installing an exact package and running init) offline
# against a local path, which is the documented dry-run mode. A real
# `npx github:...` install always makes the package's `bin` target
# executable during install regardless of the source tree's tracked file
# mode (npm's bin-linking does this); `npx <local-path>` does not reliably
# do the same, so the copy used here is chmod'd to match what a real
# install would produce, rather than relying on $root's own file mode.
src="$tmp/src"
cp -R "$root" "$src"
rm -rf "$src/.git" "$src/dist" "$src/node_modules"
chmod +x "$src/bin/cli.js"

# --- a good install reports ready, using an explicit target -------------
target="$tmp/good"
if bash "$root/scripts/release-smoke-test" "$src" "$target" >"$tmp/good.log" 2>&1; then
  pass "a working install reports ready"
else
  fail_ "expected the smoke test to pass"; cat "$tmp/good.log"
fi
[[ -d "$target" ]] \
  && pass "an explicitly-named target is left in place" \
  || fail_ "explicitly-named target $target was unexpectedly removed"

# --- a good install with no target given is self-cleaning ----------------
auto_log="$tmp/good-auto.log"
if bash "$root/scripts/release-smoke-test" "$src" >"$auto_log" 2>&1; then
  pass "a working install with no target given also reports ready"
else
  fail_ "expected the auto-target smoke test to pass"; cat "$auto_log"
fi
auto_target=$(grep -oE 'installs into [^ ]+' "$auto_log" | awk '{print $3}')
[[ -n "$auto_target" && ! -d "$auto_target" ]] \
  && pass "a self-allocated scratch target is cleaned up on success" \
  || fail_ "self-allocated target $auto_target was not cleaned up"

# --- a bad install spec fails loudly, keeps the target for inspection ---
target2="$tmp/bad"
if bash "$root/scripts/release-smoke-test" "$tmp/does-not-exist" "$target2" \
    >"$tmp/bad.log" 2>&1; then
  fail_ "expected a nonexistent install spec to fail"
else
  grep -qi "fail" "$tmp/bad.log" \
    && pass "a bad install spec is reported as a failure" \
    || fail_ "failure was not clearly reported"
fi
[[ -d "$target2" ]] \
  && pass "a failed run keeps its target for inspection" \
  || fail_ "failed run's target directory was removed"

if [[ "$fail" -eq 0 ]]; then
  echo "all release-smoke-test checks passed"
else
  echo "release-smoke-test checks FAILED" >&2
fi
exit "$fail"
