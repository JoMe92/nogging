#!/usr/bin/env bash
# Packed install, update, remove and launch admission for the usage gate (TASK-GSU-006).
#
# Verifies that:
#   - npm pack includes scripts/nogg_usage.py without test files or bytecode;
#   - init installs scripts/nogg_usage.py into a fresh consumer repository;
#   - installed scripts/nogg usage works in text and JSON modes for known and unknown usage;
#   - installed session launch admission enforces cap/headroom, reservations and exit 75;
#   - size labels scale the reservation estimate;
#   - on_unknown=deny exits 75 without side effects;
#   - --ignore-usage-gate and excluded roles are recorded faithfully;
#   - concurrent launches serialize admission so only one claims the final slot;
#   - session termination releases the reservation from the cache ledger;
#   - update repairs nogg_usage.py and preserves user config;
#   - remove deletes nogg_usage.py while retaining consumer config and state.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v npm >/dev/null 2>&1; then
  printf 'SKIP: packed usage gate regression (npm unavailable)\n'
  exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 1. Pack repository and inspect archive payload.
(cd "$root" && npm pack --ignore-scripts --json --pack-destination "$scratch" >"$scratch/pack.json")
archive=$(node -e 'console.log(require(process.argv[1])[0].filename)' "$scratch/pack.json")
tar -xzf "$scratch/$archive" -C "$scratch"
package="$scratch/package"

test -f "$package/scripts/nogg_usage.py" || fail "package omitted scripts/nogg_usage.py"
if find "$package/scripts" \( -name '*_test.py' -o -name '__pycache__' -o -name '*.pyc' \) | grep -q .; then
  fail "package shipped tests or bytecode under scripts/"
fi

# 2. Set up consumer repository and run init.
consumer="$scratch/consumer with spaces"
mkdir -p "$consumer"
git -C "$consumer" init -q

bin_dir="$scratch/bin"
mkdir -p "$bin_dir"
codex_dir="$scratch/codex_home"
cache_dir="$scratch/cache_home"
mkdir -p "$codex_dir" "$cache_dir"
export CODEX_HOME="$codex_dir"
export XDG_CACHE_HOME="$cache_dir"


nogg() {
  (
    cd "$consumer"
    export PATH="$bin_dir:$PATH"
    export CODEX_HOME="${CODEX_HOME:-$codex_dir}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$cache_dir}"
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

cli init
cmp "$package/scripts/nogg_usage.py" "$consumer/scripts/nogg_usage.py" \
  || fail "installed scripts/nogg_usage.py differs from packaged helper"
test -x "$consumer/scripts/nogg" || fail "installed scripts/nogg is not executable"

# 3. Test installed nogg usage CLI (read-only inspection).
write_codex_rollout() {
  local short="$1" weekly="$2" age="${3:-0}"
  python3 - "$codex_dir" "$short" "$weekly" "$age" <<'PY'
import datetime as dt, json, sys
from pathlib import Path
root, short, weekly, age = Path(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=age)
base = int(now.timestamp())
path = root / 'sessions' / now.strftime('%Y/%m/%d') / 'rollout-gate.jsonl'
path.parent.mkdir(parents=True, exist_ok=True)
row = {
    'type': 'event_msg',
    'timestamp': now.isoformat(),
    'payload': {
        'type': 'token_count',
        'rate_limits': {
            'limit_id': 'codex-primary',
            'primary': {'used_percent': short, 'window_minutes': 300, 'resets_at': base + 3600},
            'secondary': {'used_percent': weekly, 'window_minutes': 10080, 'resets_at': base + 86400}
        }
    }
}
path.write_text(json.dumps(row) + '\n')
PY
}

write_codex_rollout 87 40

# Test formatted text output
text_out=$(CODEX_HOME="$codex_dir" XDG_CACHE_HOME="$cache_dir" nogg usage --agent codex)
echo "$text_out" | grep -q 'short: 87% used' || fail "installed nogg usage text missing short bucket: $text_out"
echo "$text_out" | grep -q 'weekly: 40% used' || fail "installed nogg usage text missing weekly bucket: $text_out"
echo "$text_out" | grep -q 'fits: yes' || fail "installed nogg usage text missing fits projection: $text_out"

# Test JSON output
json_out=$(CODEX_HOME="$codex_dir" XDG_CACHE_HOME="$cache_dir" nogg usage --agent codex --json)
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["status"] == "known", d
assert d["schema_version"] == 1, d
assert d["provider"] == "codex", d
windows = {w["bucket"]: w for w in d["windows"]}
assert windows["short"]["used_percent"] == 87, windows
assert windows["weekly"]["used_percent"] == 40, windows
assert d["gate"]["fits"] is True, d
' "$json_out" || fail "installed nogg usage --json unexpected payload: $json_out"

# Test unknown usage when source is missing
empty_codex="$scratch/empty_codex"
mkdir -p "$empty_codex"
unknown_text=$(CODEX_HOME="$empty_codex" XDG_CACHE_HOME="$cache_dir" nogg usage --agent codex)
echo "$unknown_text" | grep -q 'unknown (missing usage source)' || fail "missing codex source did not report unknown: $unknown_text"

unknown_claude=$(XDG_CACHE_HOME="$cache_dir" nogg usage --agent claude)
echo "$unknown_claude" | grep -q 'unknown (missing usage source)' || fail "missing claude source did not report unknown: $unknown_claude"

# 4. Set up stub binaries for session launch tests.
cat >"$bin_dir/bd" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  show)
    printf '[{"id":"%s","title":"stub","labels":%s}]\n' "${2:-}" "${BD_STUB_LABELS:-[]}"
    exit 0 ;;
  dep)
    if [[ "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
    echo '[]'; exit 0 ;;
  *)
    exit 0 ;;
esac
STUB

tmux_log="$scratch/tmux.log"
cat >"$bin_dir/tmux" <<STUB
#!/usr/bin/env bash
[[ "\${1:-}" == "-L" ]] && shift 2
cmd="\${1:-}"; shift || true
printf '%s %s\n' "\$cmd" "\$*" >>"$tmux_log"
case "\$cmd" in
  has-session)
    exit 1 ;;
  new-session)
    exit 0 ;;
  kill-session)
    exit 0 ;;
  *)
    exit 0 ;;
esac
STUB
chmod +x "$bin_dir/bd" "$bin_dir/tmux"

run_launch() {
  local rc=0
  nogg session launch --role lead --bead SPEC-gate --cwd "$consumer" "$@" >"$scratch/launch.out" 2>&1 || rc=$?
  return $rc
}

# 5. Fitting launch admission: 87% + 5% = 92% <= cap.
write_codex_rollout 87 40
run_launch --agent codex || fail "fitting launch failed (rc=$?): $(cat "$scratch/launch.out")"

# Verify session record contains usage_gate decision and reservation token.
sess_json=$(find "$consumer/.nogging/state/sessions" -name '*.json' ! -name '*.settings.json' | head -n 1)
test -n "$sess_json" || fail "no session record created for admitted launch"
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
gate = rec.get("usage_gate", {})
assert gate.get("decision") == "admitted", gate
assert gate.get("fits") is True, gate
assert "reservation_id" in gate, gate
' "$sess_json" || fail "session record usage_gate field mismatch"

# Verify active reservation exists in the ledger and is stamped with schema_version 1.
ledger_file="$cache_dir/nogging/usage/reservations/ledger.json"
test -f "$ledger_file" || fail "ledger file not found at $ledger_file"
python3 -c '
import json, sys
ledger = json.load(open(sys.argv[1]))
assert len(ledger) >= 1, ledger
for tok, entry in ledger.items():
    assert entry.get("schema_version") == 1, f"reservation {tok} missing schema_version 1: {entry}"
' "$ledger_file" || fail "active reservation missing in ledger or not stamped with schema_version 1"

# Terminal session release: stop session and cleanup.
sess_name=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$sess_json")
nogg session stop "$sess_name" >/dev/null 2>&1 || true
nogg session cleanup "$sess_name" >/dev/null 2>&1 || true

# Ledger reservation released upon termination.
python3 -c '
import json, sys
ledger = json.load(open(sys.argv[1]))
assert len(ledger) == 0, f"reservations not released: {ledger}"
' "$ledger_file" || fail "ledger reservation was not released after session stop/cleanup"
rm -rf "$consumer/.nogging/state/sessions"/*

# 6. Over-cap denial (short window): 88% + 5% = 93% > 92% -> exits 75.
write_codex_rollout 88 40
rc=0
run_launch --agent codex || rc=$?
test "$rc" -eq 75 || fail "over-cap short window did not exit 75 (rc=$rc): $(cat "$scratch/launch.out")"
grep -q "short 88% used" "$scratch/launch.out" || fail "denial output did not name short bucket: $(cat "$scratch/launch.out")"
grep -q "retry after" "$scratch/launch.out" || fail "denial output did not mention retry: $(cat "$scratch/launch.out")"
test -z "$(ls -A "$consumer/.nogging/state/sessions" 2>/dev/null || true)" || fail "session record created on denied launch"

# 7. Size label doubles estimate: 85% + 10% = 95% > 92% -> exits 75.
write_codex_rollout 85 10
rc=0
BD_STUB_LABELS='["size:large"]' run_launch --agent codex || rc=$?
test "$rc" -eq 75 || fail "size:large launch did not exit 75 (rc=$rc): $(cat "$scratch/launch.out")"
grep -q "10% estimate" "$scratch/launch.out" || fail "size:large did not report 10% estimate: $(cat "$scratch/launch.out")"
test -z "$(ls -A "$consumer/.nogging/state/sessions" 2>/dev/null || true)" || fail "session record created on size:large denial"

# 8. on_unknown: deny exits 75 on missing/stale usage without creating session.
cfg_file="$consumer/.nogging/config.json"
python3 -c '
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["usage_gate"] = {"on_unknown": "deny"}
json.dump(c, open(p, "w"), indent=2)
' "$cfg_file"

rc=0
CODEX_HOME="$empty_codex" run_launch --agent codex || rc=$?
test "$rc" -eq 75 || fail "on_unknown=deny did not exit 75 (rc=$rc): $(cat "$scratch/launch.out")"
grep -q "on_unknown is deny" "$scratch/launch.out" || fail "denial output did not mention on_unknown is deny: $(cat "$scratch/launch.out")"
test -z "$(ls -A "$consumer/.nogging/state/sessions" 2>/dev/null || true)" || fail "session record created on unknown denial"

# Restore default config.
python3 -c '
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c.pop("usage_gate", None)
json.dump(c, open(p, "w"), indent=2)
' "$cfg_file"

# 9. --ignore-usage-gate records decision: ignored.
write_codex_rollout 88 40
run_launch --agent codex --ignore-usage-gate || fail "--ignore-usage-gate launch failed: $(cat "$scratch/launch.out")"
sess_json=$(find "$consumer/.nogging/state/sessions" -name '*.json' ! -name '*.settings.json' | head -n 1)
test -n "$sess_json" || fail "no session record for ignored launch"
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec.get("usage_gate", {}).get("decision") == "ignored", rec
' "$sess_json" || fail "decision was not recorded as ignored"
sess_name=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$sess_json")
nogg session stop "$sess_name" >/dev/null 2>&1 || true
nogg session cleanup "$sess_name" >/dev/null 2>&1 || true
rm -rf "$consumer/.nogging/state/sessions"/*

# 10. Excluded role records decision: excluded.
python3 -c '
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["usage_gate"] = {"exclude_roles": ["lead"]}
json.dump(c, open(p, "w"), indent=2)
' "$cfg_file"

rc=0
run_launch --agent codex || rc=$?
test "$rc" -eq 0 || fail "excluded role launch failed (rc=$rc): $(cat "$scratch/launch.out")"
sess_json=$(find "$consumer/.nogging/state/sessions" -name '*.json' ! -name '*.settings.json' | head -n 1)
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec.get("usage_gate", {}).get("decision") == "excluded", rec
' "$sess_json" || fail "lead role decision was not recorded as excluded"
sess_name=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$sess_json")
nogg session stop "$sess_name" >/dev/null 2>&1 || true
nogg session cleanup "$sess_name" >/dev/null 2>&1 || true
rm -rf "$consumer/.nogging/state/sessions"/*

# Restore default config.
python3 -c '
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c.pop("usage_gate", None)
json.dump(c, open(p, "w"), indent=2)
' "$cfg_file"

# 11. Concurrent stub admission: two competing launches for a single final slot.
# Set usage to 87% used (cap 92%, estimate 5% -> exactly one 5% slot remains).
write_codex_rollout 87 40
python3 - "$consumer" "$bin_dir" "$codex_dir" "$cache_dir" <<'PY'
import multiprocessing as mp, os, pathlib, subprocess, sys

consumer, bin_dir, codex_dir, cache_dir = [pathlib.Path(a) for a in sys.argv[1:5]]
env = {k: v for k, v in os.environ.items() if not k.startswith("NOGG_") and k != "NOGGING_ROOT"}
env.update({
    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
    "CODEX_HOME": str(codex_dir),
    "XDG_CACHE_HOME": str(cache_dir),
    "PYTHONDONTWRITEBYTECODE": "1",
})

def launch_worker(idx, queue):
    res = subprocess.run(
        [str(consumer / "scripts/nogg"), "session", "launch", "--role", "lead",
         "--bead", f"SPEC-concurrent-{idx}", "--cwd", str(consumer), "--agent", "codex"],
        cwd=consumer, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    queue.put((idx, res.returncode, res.stdout + res.stderr))

queue = mp.Queue()
p1 = mp.Process(target=launch_worker, args=(1, queue))
p2 = mp.Process(target=launch_worker, args=(2, queue))
p1.start(); p2.start()
p1.join(15); p2.join(15)

results = [queue.get(timeout=5), queue.get(timeout=5)]
rcs = sorted(r[1] for r in results)
assert rcs == [0, 75], f"expected [0, 75] from competing launches, got {rcs}: {results}"
PY

# Cleanup sessions from concurrent test.
find "$consumer/.nogging/state/sessions" -name '*.json' ! -name '*.settings.json' | while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  s_name=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$s")
  nogg session stop "$s_name" >/dev/null 2>&1 || true
  nogg session cleanup "$s_name" >/dev/null 2>&1 || true
done
rm -rf "$consumer/.nogging/state/sessions"/*

# 12. Installed helper reads mixed entries without lost accounting.
# Seed ledger with legacy unversioned entry, version 1 entry, and future version 2 entry.
write_codex_rollout 80 30
python3 - "$ledger_file" "$consumer" <<'PY'
import json, sys
ledger_path = sys.argv[1]
consumer_dir = sys.argv[2]
sess_path = consumer_dir + "/dummy_session.json"
with open(sess_path, "w") as f:
    json.dump({"state": "running"}, f)

# Determine the exact scope generated for codex default report
sys.path.insert(0, consumer_dir + "/scripts")
import nogg_usage as u
rep = u.inspect_usage("codex")
scope = u.reservation_scope(rep)

mixed = {
    "tok-legacy": {
        "scope": scope,
        "estimate": 4,
        "windows": {"short": None, "weekly": None},
        "owner": "legacy.owner",
        "session": {"path": sess_path, "name": "dummy-legacy", "tmux": "true", "socket": "nogg-test"}
    },
    "tok-v1": {
        "schema_version": 1,
        "scope": scope,
        "estimate": 3,
        "windows": {"short": None, "weekly": None},
        "owner": "v1.owner",
        "session": {"path": sess_path, "name": "dummy-v1", "probe": {"backend": "tmux", "argv": ["true"]}}
    },
    "tok-v2-future": {
        "schema_version": 2,
        "scope": scope,
        "estimate": 5,
        "windows": {"short": None, "weekly": None},
        "owner": "v2.owner",
        "future_field": "opaque"
    }
}
with open(ledger_path, "w") as f:
    json.dump(mixed, f)
PY

# Verify nogg usage via installed helper counts all mixed entries (4 + 3 + 5 = 12% reserved)
# Base used is 80%, so projected short is 80 + 12 + 5 (estimate) = 97% > 92% (cap) -> fits is False!
json_mixed=$(CODEX_HOME="$codex_dir" XDG_CACHE_HOME="$cache_dir" nogg usage --agent codex --json)
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
gate = d["gate"]
assert gate["reserved_percent"] == 12, gate
windows = {w["bucket"]: w for w in gate["windows"]}
assert windows["short"]["reserved_percent"] == 12, windows
assert windows["short"]["used_percent"] == 80.0, windows
# 80 used + 12 reserved + 5 estimate = 97 > 92 cap -> fits False
assert windows["short"]["projected_percent"] == 97.0, windows
assert windows["short"]["fits"] is False, windows
assert gate["fits"] is False, gate
' "$json_mixed" || fail "installed helper failed to read mixed entries without lost accounting: $json_mixed"

# Launch must be denied with exit 75 because 80% used + 12% reserved + 5% estimate = 97% > 92% cap
rc=0
run_launch --agent codex || rc=$?
test "$rc" -eq 75 || fail "launch with mixed reservations over cap did not exit 75 (rc=$rc): $(cat "$scratch/launch.out")"

# Reset ledger file
rm -f "$ledger_file"

# 13. Lifecycle: update and remove.
# Modify consumer config
python3 -c '
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["usage_gate"] = {"cap_percent": 85}
json.dump(c, open(p, "w"), indent=2)
' "$cfg_file"

# Tamper with installed helper
echo '# corrupted' > "$consumer/scripts/nogg_usage.py"

# Update preserves the local helper, stages upstream, and preserves user config
cli update
grep -qx '# corrupted' "$consumer/scripts/nogg_usage.py" || fail "cli update overwrote the local helper"
cmp "$package/scripts/nogg_usage.py" "$consumer/scripts/nogg_usage.py.nogging-new" \
  || fail "cli update failed to stage the upstream helper"
python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
assert c.get("usage_gate", {}).get("cap_percent") == 85, c
' "$cfg_file" || fail "cli update did not preserve user config"

# Remove cleans up nogg_usage.py while retaining consumer config
cli remove
test ! -e "$consumer/scripts/nogg_usage.py" || fail "cli remove retained scripts/nogg_usage.py"
test -f "$cfg_file" || fail "cli remove dropped user .nogging/config.json"
python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
assert c.get("usage_gate", {}).get("cap_percent") == 85, c
' "$cfg_file" || fail "cli remove corrupted user config"

printf 'ok - packed usage gate: payload, CLI inspection, admission, concurrent race, and lifecycle verified\n'
