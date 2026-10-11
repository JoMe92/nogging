#!/usr/bin/env bash
# Packed install/update/remove of the token-usage helpers and docs (TASK-TUC-007):
# the shipped archive carries every runtime helper (and no tests or bytecode),
# the installed CLI works with a lazily created owner-only store, and update and
# remove preserve the user-owned database, spool and unrelated hooks while the
# export remains usable for recovery.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v dolt >/dev/null 2>&1; then
  printf 'packed token usage: skipped (dolt not installed)\n'; exit 0
fi
scratch=$(mktemp -d)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
helpers="adapters antigravity collect report store sync"

(cd "$root" && npm pack --ignore-scripts --json --pack-destination "$scratch" >"$scratch/pack.json")
archive=$(node -e 'console.log(require(process.argv[1])[0].filename)' "$scratch/pack.json")
tar -xzf "$scratch/$archive" -C "$scratch"
package="$scratch/package"
consumer="$scratch/consumer with spaces"
mkdir -p "$consumer"
git -C "$consumer" init -q
mkdir -p "$consumer/.claude" "$consumer/scripts/hooks"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"echo user-hook"}]}]}}' \
  >"$consumer/.claude/settings.json"
printf '# user hook\n' >"$consumer/scripts/hooks/user-hook"
cli() { (cd "$consumer" && node "$package/bin/cli.js" "$1" --no-beads --no-hooks --no-systemd >/dev/null); }
# Run without any inherited supervised-session identity (NOGG_* / NOGGING_ROOT).
clean_env() { env -u NOGGING_ROOT -u PYTHONDONTWRITEBYTECODE $(compgen -e | grep '^NOGG_' | sed 's/^/-u /') "$@"; }
nogg() { (cd "$consumer" && clean_env ./scripts/nogg "$@"); }

# The shipped archive has the runtime helpers, the doc, no tests, no bytecode.
for h in $helpers; do test -f "$package/scripts/lib/token_usage_$h.py" || fail "package omitted token_usage_$h.py"; done
test -f "$package/docs/token-usage.md" || fail "package omitted docs/token-usage.md"
if find "$package/scripts/lib" \( -name '*_test.py' -o -name '__pycache__' -o -name '*.pyc' \) | grep -q .; then
  fail "package shipped tests or bytecode under scripts/lib"
fi

check_payload() {
  for h in $helpers; do
    cmp "$package/scripts/lib/token_usage_$h.py" "$consumer/scripts/lib/token_usage_$h.py" \
      || fail "installed token_usage_$h.py differs or is missing"
  done
  cmp "$package/docs/token-usage.md" "$consumer/docs/nogging/token-usage.md" || fail "installed doc differs"
  grep -q 'user-hook' "$consumer/.claude/settings.json" || fail "user Claude hook lost"
  test "$(cat "$consumer/scripts/hooks/user-hook")" = '# user hook' || fail "user hook file changed"
}

cli init
check_payload
test ! -e "$consumer/.nogging/state/token-usage" || fail "init created the usage store eagerly"
status=$(nogg token-usage status --json)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["store"]=="absent" and d["schema"]=="nogg.token-usage.status/v1", d' "$status" \
  || fail "installed CLI status before first use"
test ! -e "$consumer/.nogging/state/token-usage" || fail "read-only status created the store"
find "$consumer/scripts" -name __pycache__ | grep -q . && fail "installed run left bytecode"

# Lazy, owner-only creation on explicit initialisation through the shipped helper.
python3 -I - "$consumer" <<'PY'
import importlib, sys
from pathlib import Path
root = Path(sys.argv[1]); sys.path.insert(0, str(root / "scripts/lib"))
sys.dont_write_bytecode = True
store = importlib.import_module("token_usage_store")
s = store.Store(root, lambda _: {"state_dir": str(root / ".nogging/state")})
s.initialize()
PY
python3 - "$consumer" <<'PY'
import os, stat, sys
from pathlib import Path
base = Path(sys.argv[1]) / ".nogging/state/token-usage"
# Dolt writes some of its own files 0777; owner-only holds because every
# directory on the way to them is closed to group and world.
for p in [base, *base.rglob("*")]:
    mode = stat.S_IMODE(p.lstat().st_mode)
    if p.is_dir() or p.name == "collector.lock":
        assert mode & 0o077 == 0, f"{p} is group/world accessible: {oct(mode)}"
PY
nogg token-usage status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["store"]=="present", d' \
  || fail "status after initialisation"

nogg token-usage export --all --format jsonl >"$scratch/export.jsonl"
test -s "$scratch/export.jsonl" || fail "recovery export is empty"
db_before=$(cd "$consumer/.nogging/state/token-usage" && find . -type f -not -name '*.lock' | sort | xargs sha256sum | sha256sum)

# Update twice (stale helper repaired, idempotent) then remove: user data stays.
rm -f "$consumer/scripts/lib/token_usage_report.py"
cli update; check_payload
cli update; check_payload
cli remove
for h in $helpers; do test ! -e "$consumer/scripts/lib/token_usage_$h.py" || fail "remove retained token_usage_$h.py"; done
test ! -e "$consumer/docs/nogging/token-usage.md" || fail "remove retained the doc"
db_after=$(cd "$consumer/.nogging/state/token-usage" && find . -type f -not -name '*.lock' | sort | xargs sha256sum | sha256sum)
test "$db_before" = "$db_after" || fail "update/remove changed the user-owned usage store"
grep -q 'user-hook' "$consumer/.claude/settings.json" || fail "remove dropped the user hook"
test "$(cat "$consumer/scripts/hooks/user-hook")" = '# user hook' || fail "remove touched the user hook file"

# Reinstall reads the preserved store and the export still imports idempotently.
cli init
nogg token-usage import --file "$scratch/export.jsonl" --json >"$scratch/import.json" 2>"$scratch/import.err" \
  || { cat "$scratch/import.err" >&2; fail "recovery import of the export failed"; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["added"]==0, d' "$scratch/import.json" \
  || fail "re-importing the same export was not a no-op"
printf 'packed token usage install/update/remove: ok\n'
