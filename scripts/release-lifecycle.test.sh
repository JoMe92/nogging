#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { case "$tmp" in /tmp/tmp.*) rm -r -- "$tmp" ;; esac; }
trap cleanup EXIT

fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok   - %s\n' "$1"; }

cp -R "$root" "$tmp/release-1"
cp -R "$root" "$tmp/release-2"
node - "$tmp/release-1/package.json" '1.6.0' <<'NODE'
const fs = require('fs');
const [file, version] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
pkg.version = version;
fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + '\n');
NODE
node - "$tmp/release-2/package.json" '1.7.0' <<'NODE'
const fs = require('fs');
const [file, version] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
pkg.version = version;
fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + '\n');
NODE
printf '\n# release-fixture: 1.6.0\n' >>"$tmp/release-1/scripts/nogg"
printf '\n# release-fixture: 1.7.0\n' >>"$tmp/release-2/scripts/nogg"

test "$(node "$tmp/release-1/bin/cli.js" version)" = 1.6.0 \
  || fail "version subcommand identifies release 1"
test "$(node "$tmp/release-2/bin/cli.js" --version)" = 1.7.0 \
  || fail "version option identifies release 2"
pass "version command identifies the selected release"

target="$tmp/target"
git -C "$tmp" init -q target
mkdir -p "$target/openspec/changes/owner" "$target/.beads" \
  "$target/.nogging/state" "$target/.claude" "$target/.codex" "$target/.pi"
printf 'owner spec\n' >"$target/openspec/changes/owner/spec.md"
printf 'owner bead\n' >"$target/.beads/owner"
printf 'owner runtime\n' >"$target/.nogging/state/owner"
printf 'owner claude\n' >"$target/.claude/owner"
printf 'owner codex\n' >"$target/.codex/owner"
printf 'owner pi\n' >"$target/.pi/owner"

(cd "$target" && node "$tmp/release-1/bin/cli.js" init --no-beads --no-hooks --no-systemd >/dev/null)
grep -q 'release-fixture: 1.6.0' "$target/scripts/nogg" \
  || fail "initial release payload was not installed"

(cd "$target" && node "$tmp/release-2/bin/cli.js" update --no-hooks --no-systemd >/dev/null)
grep -q 'release-fixture: 1.7.0' "$target/scripts/nogg" \
  || fail "pinned successor payload was not installed"
grep -q '"nogging_version": "1.7.0"' "$target/.nogging/config.json" \
  || fail "update did not record successor version"
pass "pinned update replaces the managed payload"

(cd "$target" && node "$tmp/release-1/bin/cli.js" update --no-hooks --no-systemd >/dev/null)
grep -q 'release-fixture: 1.6.0' "$target/scripts/nogg" \
  || fail "rollback did not restore the prior payload"
grep -q '"nogging_version": "1.6.0"' "$target/.nogging/config.json" \
  || fail "rollback did not record prior version"
pass "pinned rollback restores the prior managed payload"

(cd "$target" && node "$tmp/release-1/bin/cli.js" remove >/dev/null)
test ! -e "$target/scripts/nogg" || fail "remove left the managed executable"
for owned in openspec/changes/owner/spec.md .beads/owner .nogging/state/owner \
  .claude/owner .codex/owner .pi/owner; do
  test -f "$target/$owned" || fail "lifecycle changed target-owned $owned"
done
test -f "$target/.nogging/config.json" || fail "remove deleted target configuration"
pass "remove preserves target-owned planning, Beads, config, state, and agent settings"

# --- update migrates a legacy v1.x .specforge/ state root (TASK-PUB-014) ---
legacy="$tmp/legacy-target"
git -C "$tmp" init -q legacy-target
mkdir -p "$legacy/.specforge/launch-profiles" "$legacy/.specforge/state"
printf 'legacy launch profile\n' >"$legacy/.specforge/launch-profiles/trusted.json"
printf 'legacy state\n' >"$legacy/.specforge/state/owner"
cat >"$legacy/.specforge/config.json" <<'JSON'
{
  "name": "legacy-target",
  "sync_interval_seconds": 30,
  "specforge_version": "1.6.0"
}
JSON
(cd "$legacy" && node "$tmp/release-2/bin/cli.js" update --no-hooks --no-systemd >/dev/null)
test ! -e "$legacy/.specforge" || fail "migration left the legacy .specforge/ directory behind"
test -f "$legacy/.nogging/config.json" || fail "migration did not produce .nogging/config.json"
grep -q '"nogging_version": "1.7.0"' "$legacy/.nogging/config.json" \
  || fail "migrated config was not bumped to the running version"
grep -q 'specforge_version' "$legacy/.nogging/config.json" \
  && fail "migrated config still carries the legacy version key"
test -f "$legacy/.nogging/launch-profiles/trusted.json" \
  || fail "migration lost the legacy launch-profiles directory"
test -f "$legacy/.nogging/state/owner" \
  || fail "migration lost the legacy state directory"
pass "update migrates a legacy .specforge/ state root to .nogging/ in place"

printf 'release lifecycle checks passed\n'
