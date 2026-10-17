#!/usr/bin/env bash
# Regression checks for unknown-admitted visibility (TASK-UVF-004).
#
# Covered:
#   - an unknown-admitted launch prints a prominent `WARN:` on stderr that keeps
#     the `usage is unknown (<bucket>: <reason>` substring, names the agent, the
#     `usage_gate.on_unknown` setting and how to block, and appends any window
#     `hint` (read generically with `.get`);
#   - the default stays warn: the launch still proceeds and is recorded
#     `unknown-admitted`; `on_unknown=deny` still exits 75;
#   - `unknown_policy_notes()` is pure: it notes unknown agents under warn and is
#     silent when everything is known, the policy is deny or the gate is disabled;
#   - `doctor` prints the NOTE for an unknown agent and drops it when the
#     policy is deny or the gate is disabled.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
  printf '[{"id":"%s","title":"stub","labels":[]}]\n' "${2:-}"; exit 0
fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
echo "stub bd: refusing $*" >&2; exit 1
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"
case "$cmd" in
  has-session) [[ "${TMUX_STUB_LIVE:-0}" == 1 && -f "$d/live-${2:-}" ]] ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
export PATH="$work/bin:$PATH"
export HOME="$work/home" XDG_CACHE_HOME="$work/cache"
mkdir -p "$HOME"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

# --- Pure helper ---
python3 - "$here" <<'PY' && ok "unknown_policy_notes is pure and policy-aware" || { echo "FAIL - unknown_policy_notes unit checks"; fail=1; }
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import nogg_usage as u

known = {'status': 'known', 'windows': []}
unknown = {'status': 'unknown', 'windows': []}
note = lambda agent: (f'usage gate: {agent} usage is unknown — launches are admitted without known '
                      'headroom (usage_gate.on_unknown=warn); set "deny" to block')
assert u.unknown_policy_notes(None, {'claude': unknown, 'codex': known}) == [note('claude')]
assert u.unknown_policy_notes({}, {'codex': unknown, 'claude': unknown}) == [note('claude'), note('codex')]
assert u.unknown_policy_notes(None, {'claude': known, 'codex': known}) == []
assert u.unknown_policy_notes(None, {}) == [] and u.unknown_policy_notes(None, None) == []
assert u.unknown_policy_notes({'on_unknown': 'deny'}, {'claude': unknown}) == []
assert u.unknown_policy_notes({'enabled': False}, {'claude': unknown}) == []
# Never raises, even on a bad config or malformed observations.
assert u.unknown_policy_notes({'on_unknown': 'allow'}, {'claude': unknown}) == []
assert u.unknown_policy_notes(None, {'claude': None, 'codex': 'x'}) == []
PY

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/scripts/hooks" "$r/openspec" "$r/.pi/extensions" "$r/.agents"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$repo_root/scripts/nogg" \
     "$repo_root/scripts/nogg_usage.py" "$r/scripts/"
  git init -q "$r"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$r/.nogging/"
  cp "$repo_root/templates/model-selection.json" "$r/.nogging/model-selection.json"
  python3 - "$repo_root/.nogging/config.json" "$r/.nogging/config.json" "${GATE_CONFIG:-}" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None)
cfg.pop("usage_gate", None)
if sys.argv[3]:
    cfg["usage_gate"] = json.loads(sys.argv[3])
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
}

n=0
new_root() {
  n=$((n + 1)); root="$work/r$n"; make_root "$root"
  export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/t$n" CODEX_HOME="$work/codex$n"
  export XDG_CACHE_HOME="$work/cache$n"
  mkdir -p "$TMUX_STUB_DIR" "$CODEX_HOME"
}

rc=0
run_launch() {
  rc=0
  "$nogg" session launch --role lead --backend tmux --bead SPEC-gate --cwd "$root" "$@" >"$out" 2>&1 || rc=$?
}

record_gate() {
  python3 - "$root/.nogging/state/sessions" <<'PY'
import json, sys
from pathlib import Path
recs = [json.loads(p.read_text()) for p in Path(sys.argv[1]).glob('*.json')
        if not p.name.endswith('.settings.json')]
assert len(recs) == 1, recs
print(recs[0]['usage_gate']['decision'])
PY
}

# --- Launch WARN: claude without a capture cache is unknown (missing source) ---
new_root
run_launch --agent claude
[[ $rc -eq 0 && "$(record_gate)" == unknown-admitted ]] \
  && grep -qF "WARN: claude usage is unknown (short: missing usage source" "$out" \
  && grep -qF "weekly: missing usage source" "$out" \
  && grep -qF "launch admitted WITHOUT known headroom" "$out" \
  && grep -qF 'usage_gate.on_unknown is warn; set it to "deny" to block' "$out" \
  && ! grep -qF "warning: claude usage is unknown" "$out" \
  && ok "unknown-admitted launch prints a prominent WARN and still proceeds" || bad "launch WARN (rc=$rc)"

# --- A window hint is appended generically (injected, independent of UVF-003) ---
new_root
cp -r "$repo_root/scripts/lib" "$root/scripts/"
cat >>"$root/scripts/nogg_usage.py" <<'PY'

_evaluate_gate = evaluate_gate
def evaluate_gate(report, config, estimate, reserved_percent=0):
    result = _evaluate_gate(report, config, estimate, reserved_percent)
    for window in result['windows']:
        if window['status'] != 'known':
            window['hint'] = 'run nogg usage install-statusline'
    return result
PY
nogg="$root/scripts/nogg" run_launch --agent claude
[[ $rc -eq 0 ]] \
  && grep -qF "usage is unknown (short: missing usage source — run nogg usage install-statusline; weekly: missing usage source — run nogg usage install-statusline)" "$out" \
  && ok "WARN appends each window hint" || bad "WARN hint (rc=$rc)"

# --- on_unknown=deny is unchanged ---
GATE_CONFIG='{"on_unknown":"deny"}' new_root
run_launch --agent claude
[[ $rc -eq 75 ]] && grep -qF "on_unknown is deny" "$out" && ! grep -qF "WARN:" "$out" \
  && ok "on_unknown=deny still exits 75 without the WARN" || bad "deny (rc=$rc)"

# --- doctor NOTE ---
note_text='usage gate: claude usage is unknown — launches are admitted without known headroom'
run_doctor() { "$nogg" doctor >"$out" 2>&1 || true; }

new_root
run_doctor
grep -qF "NOTE  $note_text (usage_gate.on_unknown=warn); set \"deny\" to block" "$out" \
  && grep -qF "NOTE  usage gate: codex usage is unknown" "$out" \
  && ok "doctor notes admitted-unknown agents under warn" || bad "doctor note"

GATE_CONFIG='{"on_unknown":"deny"}' new_root
run_doctor
! grep -qF "usage gate:" "$out" && ok "doctor note absent under deny" || bad "doctor deny"

GATE_CONFIG='{"enabled":false}' new_root
run_doctor
! grep -qF "usage gate:" "$out" && ok "doctor note absent when the gate is disabled" || bad "doctor disabled"

# Known usage: a fresh claude capture and a fresh codex rollout silence the note.
new_root
python3 - "$XDG_CACHE_HOME" "$CODEX_HOME" <<'PY'
import datetime as dt, json, sys
from pathlib import Path
now = dt.datetime.now(dt.timezone.utc)
base = int(now.timestamp())
claude = Path(sys.argv[1]) / 'nogging/usage/claude.json'
claude.parent.mkdir(parents=True)
claude.write_text(json.dumps({'schema_version': 1, 'observed_at': now.isoformat(), 'rate_limits': {
    'five_hour': {'used_percentage': 10, 'resets_at': base + 3600},
    'seven_day': {'used_percentage': 10, 'resets_at': base + 86400}}}))
rollout = Path(sys.argv[2]) / 'sessions' / now.strftime('%Y/%m/%d') / 'rollout-v.jsonl'
rollout.parent.mkdir(parents=True)
rollout.write_text(json.dumps({'type': 'event_msg', 'timestamp': now.isoformat(),
    'payload': {'type': 'token_count', 'rate_limits': {
        'primary': {'used_percent': 5, 'window_minutes': 300, 'resets_at': base + 3600},
        'secondary': {'used_percent': 5, 'window_minutes': 10080, 'resets_at': base + 86400}}}}) + '\n')
PY
run_doctor
! grep -qF "usage gate:" "$out" && ok "doctor note absent when usage is known" || bad "doctor known"

exit $fail
