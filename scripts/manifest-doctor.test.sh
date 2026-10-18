#!/usr/bin/env bash
# Doctor diagnostics for pending .nogging-new files and manifest cleanup on
# remove (TASK-PVE-004). Offline: no Dolt/bd, no tmux server, no network.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() { echo "FAIL - $1" >&2; exit 1; }
pass() { echo "ok   - $1"; }

if ! command -v node >/dev/null 2>&1; then
  pass "skipped (node not installed)"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
target="$tmp/target"
stubs="$tmp/stubs"
mkdir -p "$target" "$stubs"

# bd/dolt stubs keep doctor independent of a Beads server; the tmux socket is
# private to this test so no real server is ever contacted.
printf '#!/usr/bin/env bash\nif [[ "$*" == *--json* ]]; then echo "[]"; fi\nexit 0\n' >"$stubs/bd"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/dolt"
chmod +x "$stubs/bd" "$stubs/dolt"

git -C "$target" init -q
git -C "$target" config user.name Test
git -C "$target" config user.email test@test.local
git -C "$target" commit --allow-empty -qm init

(cd "$target" && node "$root/bin/cli.js" init --no-beads --no-hooks >/dev/null)
test -f "$target/.nogging/installed-manifest.json" || fail "init writes the manifest"

run_doctor() {
  doctor_rc=0
  out=$(cd "$target" && env -u TMUX PATH="$stubs:$PATH" NOGGING_ROOT="$target" \
    TMUX_TMPDIR="$tmp/tmux" scripts/nogg doctor 2>&1) || doctor_rc=$?
}
mkdir -p "$tmp/tmux"

run_doctor
if grep -q 'pending upstream update' <<<"$out"; then fail "clean install has no pending warning"; fi
if grep -q 'locally modified installed file' <<<"$out"; then fail "clean install has no modification note"; fi
clean_rc=$doctor_rc
pass "doctor is quiet on a clean install"

# Local edit without a .nogging-new: informational NOTE only.
printf '\n# local tweak\n' >>"$target/.codex/rules/nogging.rules"
run_doctor
grep -q '^NOTE  locally modified installed file: .codex/rules/nogging.rules' <<<"$out" \
  || fail "modified file surfaces as NOTE: $out"
if grep -q '^WARN  locally modified file has pending' <<<"$out"; then fail "no WARN without .nogging-new"; fi
pass "doctor notes a locally modified installed file"

# Pending upstream copy: WARN naming the file, no extra NOTE, exit code unaffected.
printf 'upstream\n' >"$target/.codex/rules/nogging.rules.nogging-new"
mkdir -p "$target/.nogging/launch-prompts"
printf 'upstream\n' >"$target/.nogging/launch-prompts/orchestrator.md.nogging-new"
printf 'backup\n' >"$target/scripts/nogg.orig"
run_doctor
grep -qF 'WARN  locally modified file has pending upstream update: .codex/rules/nogging.rules (review .codex/rules/nogging.rules.nogging-new and reconcile)' <<<"$out" \
  || fail "WARN for nogging.rules: $out"
grep -qF 'WARN  locally modified file has pending upstream update: .nogging/launch-prompts/orchestrator.md (review .nogging/launch-prompts/orchestrator.md.nogging-new and reconcile)' <<<"$out" \
  || fail "WARN for orchestrator.md: $out"
if grep -q '^NOTE  locally modified installed file: .codex/rules/nogging.rules' <<<"$out"; then
  fail "no duplicate NOTE when a .nogging-new exists"
fi
grep -qF 'NOTE  --force backup of a locally modified file: scripts/nogg.orig' <<<"$out" \
  || fail "NOTE for .orig backup: $out"

test "$doctor_rc" = "$clean_rc" || fail "warnings change the exit code ($doctor_rc vs $clean_rc)"
rm -f "$target/.codex/rules/nogging.rules.nogging-new" "$target/.nogging/launch-prompts/orchestrator.md.nogging-new" "$target/scripts/nogg.orig"
pass "doctor warns of pending .nogging-new and .orig without changing its exit code"

# Remove deletes the manifest and leftover artifacts, keeps project state.
printf 'upstream\n' >"$target/.codex/rules/nogging.rules.nogging-new"
printf 'backup\n' >"$target/scripts/nogg.orig"
printf 'user\n' >"$target/notes.orig"
(cd "$target" && node "$root/bin/cli.js" remove >/dev/null)
test ! -e "$target/.nogging/installed-manifest.json" || fail "manifest remains after remove"
test ! -e "$target/.codex/rules/nogging.rules.nogging-new" || fail ".nogging-new remains after remove"
test ! -e "$target/scripts/nogg.orig" || fail ".orig remains after remove"
test ! -e "$target/scripts/nogg" || fail "managed command remains after remove"
test -f "$target/notes.orig" || fail "unrelated .orig file was removed"
test -f "$target/.nogging/config.json" || fail "target-owned config removed"
pass "remove cleans the manifest and installer artifacts only"

# --dry-run removes nothing.
(cd "$target" && node "$root/bin/cli.js" init --no-beads --no-hooks >/dev/null)
printf 'upstream\n' >"$target/.codex/rules/nogging.rules.nogging-new"
(cd "$target" && node "$root/bin/cli.js" remove --dry-run >/dev/null)
test -f "$target/.nogging/installed-manifest.json" || fail "dry-run removed the manifest"
test -f "$target/.codex/rules/nogging.rules.nogging-new" || fail "dry-run removed .nogging-new"
pass "remove --dry-run leaves manifest and artifacts in place"
