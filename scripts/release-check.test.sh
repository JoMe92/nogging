#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { case "$tmp" in /tmp/tmp.*) rm -rf -- "$tmp" ;; esac; }
trap cleanup EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
fail_() { printf 'FAIL - %s\n' "$1" >&2; fail=1; }

fixture="$tmp/fixture"
mkdir -p "$fixture"
git -C "$fixture" init -q -b main
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name test

write_state() {
  local version="$1" changelog_version="$2"
  cat >"$fixture/package.json" <<JSON
{"name": "fixture", "version": "$version"}
JSON
  cat >"$fixture/package-lock.json" <<JSON
{"name": "fixture", "version": "$version"}
JSON
  {
    printf '# Changelog\n\n'
    if [[ -n "$changelog_version" ]]; then
      printf '## [%s]\n\n- placeholder\n' "$changelog_version"
    else
      printf '## [Unreleased]\n\n- placeholder\n'
    fi
  } >"$fixture/CHANGELOG.md"
  mkdir -p "$fixture/scripts"
  cp "$root/scripts/release-check" "$fixture/scripts/release-check"
  chmod +x "$fixture/scripts/release-check"
}

run() { ( cd "$fixture" && bash scripts/release-check "$@" ); }

# --- fully consistent, tagged, clean tree -> passes --------------------
write_state 1.0.0 1.0.0
git -C "$fixture" add -A
git -C "$fixture" commit -q -m 'release 1.0.0'
git -C "$fixture" tag v1.0.0
run 1.0.0 >/tmp/rc_out 2>&1 && pass "consistent tagged release passes" \
  || { fail_ "consistent tagged release should pass"; cat /tmp/rc_out; }

# --- bad semver ----------------------------------------------------------
run "not-a-version" >/tmp/rc_out 2>&1 && { fail_ "bad semver should fail"; } \
  || { grep -q "not valid semver" /tmp/rc_out && pass "bad semver is rejected" \
       || fail_ "bad semver message missing"; }

# --- package.json/lock mismatch ------------------------------------------
write_state 1.1.0 1.1.0
printf '{"name": "fixture", "version": "1.0.9"}' >"$fixture/package-lock.json"
git -C "$fixture" add -A
git -C "$fixture" commit -q -m 'release 1.1.0'
run 1.1.0 >/tmp/rc_out 2>&1 && { fail_ "lock mismatch should fail"; } \
  || { grep -q "package-lock.json version is '1.0.9'" /tmp/rc_out \
       && pass "package-lock.json version mismatch is caught" \
       || fail_ "lock mismatch message missing"; }

# --- missing changelog section -------------------------------------------
write_state 1.2.0 ""
git -C "$fixture" add -A
git -C "$fixture" commit -q -m 'release 1.2.0, unreleased changelog'
run 1.2.0 >/tmp/rc_out 2>&1 && { fail_ "missing changelog section should fail"; } \
  || { grep -q "no '## \[1.2.0\]' section" /tmp/rc_out \
       && pass "missing CHANGELOG section is caught" \
       || fail_ "missing changelog message missing"; }

# --- tag points at the wrong commit --------------------------------------
write_state 1.3.0 1.3.0
git -C "$fixture" add -A
git -C "$fixture" commit -q -m 'release 1.3.0'
git -C "$fixture" tag v1.3.0
printf '\nextra\n' >>"$fixture/CHANGELOG.md"
git -C "$fixture" add -A
git -C "$fixture" commit -q -m 'unrelated follow-up commit after tagging'
run 1.3.0 >/tmp/rc_out 2>&1 && { fail_ "stale tag should fail"; } \
  || { grep -q "points at" /tmp/rc_out && grep -q "HEAD is" /tmp/rc_out \
       && pass "tag pointing at a non-HEAD commit is caught" \
       || fail_ "stale tag message missing"; }

# --- dirty working tree ----------------------------------------------------
write_state 1.4.0 1.4.0
git -C "$fixture" add -A
git -C "$fixture" commit -q -m 'release 1.4.0'
printf 'dirty\n' >>"$fixture/README.md"
run 1.4.0 >/tmp/rc_out 2>&1 && { fail_ "dirty tree should fail"; } \
  || { grep -q "uncommitted changes" /tmp/rc_out \
       && pass "dirty working tree is caught" \
       || fail_ "dirty tree message missing"; }
git -C "$fixture" checkout -q -- . 2>/dev/null || rm -f "$fixture/README.md"

if [[ "$fail" -eq 0 ]]; then
  echo "all release-check checks passed"
else
  echo "release-check checks FAILED" >&2
fi
exit "$fail"
