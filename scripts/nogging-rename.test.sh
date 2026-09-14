#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  case "$tmp" in
    /tmp/tmp.*) rm -r -- "$tmp" ;;
  esac
}
trap cleanup EXIT

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }

mkdir -p "$tmp/target"
git -C "$tmp/target" init -q

mkdir -p \
  "$tmp/target/openspec/changes/user-change" \
  "$tmp/target/.beads" \
  "$tmp/target/.nogging/state" \
  "$tmp/target/.claude/agents" \
  "$tmp/target/.codex" \
  "$tmp/target/.pi"
printf 'owner intent\n' >"$tmp/target/openspec/changes/user-change/spec.md"
printf 'beads state\n' >"$tmp/target/.beads/issues.jsonl"
printf '{"name":"kept-name","nogging_version":"1.4.0","custom":true}\n' >"$tmp/target/.nogging/config.json"
printf 'runtime state\n' >"$tmp/target/.nogging/state/owner-state"
printf 'custom agent\n' >"$tmp/target/.claude/agents/custom.md"
printf '{"custom":true}\n' >"$tmp/target/.codex/config.json"
printf 'custom pi\n' >"$tmp/target/.pi/custom.txt"

(
  cd "$tmp/target"
  node "$root/bin/cli.js" init --no-beads --no-hooks >/dev/null
)
test -x "$tmp/target/scripts/nogg" || fail "Nogging installs"
pass "Nogging installs"

assert_owned_state() {
  test "$(cat "$tmp/target/openspec/changes/user-change/spec.md")" = 'owner intent' || fail "OpenSpec state changed"
  test "$(cat "$tmp/target/.beads/issues.jsonl")" = 'beads state' || fail "Beads state changed"
  node -e 'const c=require(process.argv[1]); if(c.name!=="kept-name") process.exit(1)' \
    "$tmp/target/.nogging/config.json" || fail "config name changed"
  node -e 'const c=require(process.argv[1]); if(c.custom!==true) process.exit(1)' \
    "$tmp/target/.nogging/config.json" || fail "custom config changed"
  test -f "$tmp/target/.nogging/state/owner-state" || fail "Nogging state removed"
  test -f "$tmp/target/.claude/agents/custom.md" || fail "custom Claude agent removed"
  grep -q '"custom":true' "$tmp/target/.codex/config.json" || fail "custom Codex setting changed"
  test -f "$tmp/target/.pi/custom.txt" || fail "custom Pi setting removed"
}

(
  cd "$tmp/target"
  node "$root/bin/cli.js" update --no-hooks >/dev/null
)
assert_owned_state
grep -q 'Nogging' "$tmp/target/scripts/../AGENTS.md" || fail "Nogging update missing"
test -f "$tmp/target/systemd/nogg-sync-target.service" || fail "stable service identity missing"
pass "Nogging update preserves owned state and service identity"

(
  cd "$tmp/target"
  node "$root/bin/cli.js" update --no-hooks >/dev/null
  node "$root/bin/cli.js" remove >/dev/null
)
assert_owned_state
test ! -e "$tmp/target/scripts/nogg" || fail "managed command remains after remove"
test ! -e "$tmp/target/systemd/nogg-sync-target.service" || fail "generated service remains after remove"
test ! -e "$tmp/target/.codex/prompts/plan.md" || fail "managed Codex prompt remains after remove"
test ! -e "$tmp/target/.pi/prompts/plan.md" || fail "managed Pi prompt remains after remove"
if grep -q '<!-- nogging:begin -->' "$tmp/target/AGENTS.md"; then
  fail "managed AGENTS block remains after remove"
fi
pass "remove deletes managed payload and preserves owned state"

printf 'rename compatibility checks passed\n'
