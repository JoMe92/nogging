#!/usr/bin/env bash
# Packed install, update and remove of the Antigravity quota payload (TASK-AGR-005).
#
# Verifies, from the shipped archive rather than this checkout, that:
#   - the packed scripts/nogg_usage.py carries the Antigravity adapter and the
#     pane adapter ships inside scripts/nogg, without tests or bytecode;
#   - an installed consumer reads a stubbed `/usage` result per model group;
#   - the installed launch gate exits 75 before trust and tmux for an
#     exhausted selected group and admits the other group;
#   - a probe the runtime reports as failed is unknown usage;
#   - update repairs the tampered helper and remove deletes it.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v npm >/dev/null 2>&1; then
  printf 'SKIP: packed antigravity usage regression (npm unavailable)\n'
  exit 0
fi

scratch=$(mktemp -d)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

(cd "$root" && npm pack --ignore-scripts --json --pack-destination "$scratch" >"$scratch/pack.json")
archive=$(node -e 'console.log(require(process.argv[1])[0].filename)' "$scratch/pack.json")
tar -xzf "$scratch/$archive" -C "$scratch"
package="$scratch/package"

grep -q "def antigravity_usage" "$package/scripts/nogg_usage.py" || fail "package omitted the Antigravity quota adapter"
grep -q "ANTIGRAVITY_ADAPTER" "$package/scripts/nogg" || fail "package omitted the Antigravity pane adapter"
if find "$package/scripts" \( -name '*_test.py' -o -name '__pycache__' -o -name '*.pyc' \) | grep -q .; then
  fail "package shipped tests or bytecode under scripts/"
fi

consumer="$scratch/consumer with spaces"
mkdir -p "$consumer"
git -C "$consumer" init -q
bin_dir="$scratch/bin"; mkdir -p "$bin_dir"
home="$scratch/home"; mkdir -p "$home/.gemini/antigravity-cli"
settings="$home/.gemini/antigravity-cli/settings.json"
printf '{"toolPermission":"request-review","trustedWorkspaces":["/keep"]}\n' >"$settings"
cache="$scratch/cache"; mkdir -p "$cache"
agy_log="$scratch/agy.log"; : >"$agy_log"
tmux_log="$scratch/tmux.log"; : >"$tmux_log"

cat >"$bin_dir/bd" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  show) printf '[{"id":"%s","title":"stub","labels":[]}]\n' "${2:-}"; exit 0 ;;
  dep) echo '[]'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat >"$bin_dir/tmux" <<STUB
#!/usr/bin/env bash
[[ "\${1:-}" == "-L" ]] && shift 2
cmd="\${1:-}"; shift || true
printf '%s %s\n' "\$cmd" "\$*" >>"$tmux_log"
case "\$cmd" in has-session) exit 1 ;; *) exit 0 ;; esac
STUB
cat >"$bin_dir/agy" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "--print" && "\${2:-}" == "/usage" ]]; then
  echo probe >>"$agy_log"
  cat "\${AGY_STUB_USAGE:?}"; exit 0
fi
exit 1
STUB
chmod +x "$bin_dir/bd" "$bin_dir/tmux" "$bin_dir/agy"

nogg() {
  (
    cd "$consumer"
    export PATH="$bin_dir:$PATH" HOME="$home" XDG_CACHE_HOME="$cache" CODEX_HOME="$scratch/codex"
    export AGY_NOGG_USAGE_PROBE=1
    unset NOGGING_ROOT PYTHONDONTWRITEBYTECODE
    for v in $(compgen -e | grep '^NOGG_' || true); do unset "$v"; done
    ./scripts/nogg "$@"
  )
}
cli() {
  (
    cd "$consumer"
    unset NOGGING_ROOT PYTHONDONTWRITEBYTECODE
    for v in $(compgen -e | grep '^NOGG_' || true); do unset "$v"; done
    node "$package/bin/cli.js" "$@" --no-beads --no-hooks --no-systemd >/dev/null
  )
}

make_usage() {  # make_usage <out> <gemini weekly> <gemini 5h>
  python3 - "$root/scripts/fixtures/antigravity/1.3.3/usage.json" "$@" <<'PY'
import datetime as dt, json, sys
d = json.load(open(sys.argv[1]))
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
for bucket in d['command']['data']['groups'][0]['buckets']:
    weekly = bucket['window'] == 'weekly'
    bucket['remaining_fraction'] = float(sys.argv[3] if weekly else sys.argv[4])
    bucket['reset_time'] = (now + (dt.timedelta(days=3) if weekly else dt.timedelta(hours=2))).isoformat().replace('+00:00', 'Z')
for bucket in d['command']['data']['groups'][1]['buckets']:
    bucket['remaining_fraction'] = 1.0
    bucket['reset_time'] = (now + dt.timedelta(hours=2)).isoformat().replace('+00:00', 'Z')
json.dump(d, open(sys.argv[2], 'w'))
PY
}

cli init
cmp "$package/scripts/nogg_usage.py" "$consumer/scripts/nogg_usage.py" \
  || fail "installed scripts/nogg_usage.py differs from the packaged helper"
test -f "$consumer/scripts/hooks/agy-guard" -a -f "$consumer/.agents/hooks.json" \
  || fail "init did not install the Antigravity guard payload"

launch() {
  local rc=0
  nogg session launch --role lead --bead SPEC-agr --cwd "$consumer" --agent antigravity --full-access "$@" \
    >"$scratch/launch.out" 2>&1 || rc=$?
  return $rc
}
untouched() {
  test "$(cat "$settings")" = '{"toolPermission":"request-review","trustedWorkspaces":["/keep"]}' \
    || fail "$1: trust settings were modified"
  ! grep -q "^new-session" "$tmux_log" || fail "$1: a tmux session was created"
  test -z "$(ls -A "$consumer/.nogging/state/sessions" 2>/dev/null || true)" || fail "$1: a session record exists"
}

# Installed usage inspection: group chosen from the selected model.
make_usage "$scratch/u1.json" 0.6 0.0
export AGY_STUB_USAGE="$scratch/u1.json"
json_out=$(nogg usage --agent agy --model gemini-3.8-flash-medium --json)
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["provider"] == "antigravity" and d["model_group"] == "Gemini Models", d
assert d["gate"]["decision"] == "denied", d
assert {w["bucket"]: w["used_percent"] for w in d["windows"]} == {"short": 100.0, "weekly": 40.0}, d
' "$json_out" || fail "installed usage --json unexpected payload: $json_out"
other=$(nogg usage --agent agy --model claude-sonnet-4-6 --json)
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["model_group"] == "Claude and GPT models" and d["gate"]["decision"] == "admitted", d
' "$other" || fail "other model group not independent: $other"
test "$(wc -l <"$agy_log")" -eq 1 || fail "fresh cache was not reused (probe count $(wc -l <"$agy_log"))"

# Exit 75 before trust/tmux for the exhausted group.
rc=0; launch --model gemini-3.8-flash-medium || rc=$?
test "$rc" -eq 75 || fail "exhausted group did not exit 75 (rc=$rc): $(cat "$scratch/launch.out")"
grep -q "short 100% used" "$scratch/launch.out" || fail "denial did not name the short bucket: $(cat "$scratch/launch.out")"
untouched "exhausted group"

# The other group launches, and only the launched worktree is trusted.
launch --model claude-sonnet-4-6 || fail "other group launch failed: $(cat "$scratch/launch.out")"
grep -qF "$consumer" "$settings" || fail "trust was not prepared for the launched worktree"
grep -q '"/keep"' "$settings" || fail "unrelated trusted workspace was dropped"
sess_json=$(find "$consumer/.nogging/state/sessions" -name '*.json' ! -name '*.settings.json' | head -n 1)
python3 -c '
import json, sys
g = json.load(open(sys.argv[1]))["usage_gate"]
assert g["decision"] == "admitted" and g["start_observation"]["model_group"] == "Claude and GPT models", g
' "$sess_json" || fail "session record lacks the model-group admission"
nogg session stop "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$sess_json")" >/dev/null 2>&1 || true
nogg session cleanup "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$sess_json")" >/dev/null 2>&1 || true
python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$consumer/.nogging/state/sessions"
printf '{"toolPermission":"request-review","trustedWorkspaces":["/keep"]}\n' >"$settings"
: >"$tmux_log"

# A runtime-reported failure with exit zero is unknown usage (warn, not admit-as-zero).
python3 - "$root/scripts/fixtures/antigravity/1.3.3/usage.json" "$scratch/u2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['status'] = 'ERROR'
json.dump(d, open(sys.argv[2], 'w'))
PY
export AGY_STUB_USAGE="$scratch/u2.json"
python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$cache"
launch --model gemini-3.8-flash-medium || fail "unknown usage should warn and launch: $(cat "$scratch/launch.out")"
grep -q "usage is unknown (short: usage probe status was 'ERROR'" "$scratch/launch.out" \
  || fail "non-SUCCESS probe was not reported as unknown: $(cat "$scratch/launch.out")"

# Update preserves the local helper and stages upstream; remove keeps user config.
echo '# corrupted' >"$consumer/scripts/nogg_usage.py"
cli update
grep -qx '# corrupted' "$consumer/scripts/nogg_usage.py" || fail "update overwrote the local helper"
cmp "$package/scripts/nogg_usage.py" "$consumer/scripts/nogg_usage.py.nogging-new" || fail "update did not stage the upstream helper"
cli remove
test ! -e "$consumer/scripts/nogg_usage.py" || fail "remove retained scripts/nogg_usage.py"
test -f "$consumer/.nogging/config.json" || fail "remove dropped the user's config"

printf 'ok - packed antigravity usage: payload, group selection, exit-75 gate and lifecycle verified\n'
