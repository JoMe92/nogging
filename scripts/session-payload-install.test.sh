#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Exercise the shipped archive, rather than borrowing helpers from this checkout.
(cd "$root" && npm pack --ignore-scripts --json --pack-destination "$scratch" >"$scratch/pack.json")
archive=$(node -e 'console.log(require(process.argv[1])[0].filename)' "$scratch/pack.json")
tar -xzf "$scratch/$archive" -C "$scratch"
package="$scratch/package"
consumer="$scratch/consumer with spaces"
mkdir -p "$consumer/openspec/changes/user" "$consumer/.beads" "$consumer/scripts"
git -C "$consumer" init -q
printf 'user planning\n' >"$consumer/openspec/changes/user/tasks.md"
printf 'user tracker\n' >"$consumer/.beads/user-data"
printf 'user helper\n' >"$consumer/scripts/user-helper"
check_preserved() {
  test "$(cat "$consumer/openspec/changes/user/tasks.md")" = 'user planning' || fail 'planning changed'
  test "$(cat "$consumer/.beads/user-data")" = 'user tracker' || fail 'tracker changed'
  test "$(cat "$consumer/scripts/user-helper")" = 'user helper' || fail 'unrelated helper changed'
}
check_helpers() {
  for helper in session-launch session-log-writer; do
    test -f "$package/scripts/$helper" || fail "package omitted $helper"
    test -x "$consumer/scripts/$helper" || fail "installed $helper is not executable"
    cmp "$package/scripts/$helper" "$consumer/scripts/$helper" || fail "installed $helper differs from distribution"
  done
  check_preserved
}
(cd "$consumer" && node "$package/bin/cli.js" init --no-beads --no-hooks --no-systemd >/dev/null)
check_helpers

# A partial older install: one absent wrapper and one stale, non-executable wrapper.
python3 - "$consumer" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
(root / 'scripts/session-launch').unlink()
writer = root / 'scripts/session-log-writer'
writer.write_text('obsolete wrapper\n')
writer.chmod(0o644)
PY
(cd "$consumer" && node "$package/bin/cli.js" update --no-beads --no-hooks --no-systemd >/dev/null)
check_helpers
(cd "$consumer" && node "$package/bin/cli.js" update --no-beads --no-hooks --no-systemd >/dev/null)
check_helpers
(cd "$consumer" && node "$package/bin/cli.js" remove --no-beads --no-hooks --no-systemd >/dev/null)
for helper in session-launch session-log-writer; do
  test ! -e "$consumer/scripts/$helper" || fail "remove retained $helper"
done
check_preserved
printf 'packed session helper install/update/remove: ok\n'
