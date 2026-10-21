#!/usr/bin/env bash
# Regression checks for the launch usage gate (TASK-GSU-002).
#
# Covered:
#   - usage_gate defaults (enabled, cap 92, estimate 5, stale 600s, unknown
#     warns, small/medium/large = 0.5/1/2, planning + orchestrator excluded);
#   - bad configuration is rejected (unknown keys, wrong types, out-of-range
#     values, unsupported agents/roles/policies) and refuses a launch;
#   - per-agent estimates and `size:<name>` Bead labels scale the estimate;
#     conflicting or unsupported size labels refuse;
#   - a known window over the cap denies with exit 75 naming its reset time,
#     the weekly bucket limiting even when the short window fits;
#   - unknown usage warns and launches by default, exits 75 with
#     on_unknown=deny, and is never treated as zero;
#   - every refusal happens before any worktree, trust, tmux or record side
#     effect; --ignore-usage-gate, disabled and excluded launches are recorded.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

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
  printf '[{"id":"%s","title":"stub","labels":%s}]\n' "${2:-}" "${BD_STUB_LABELS:-[]}"; exit 0
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
  has-session)
    [[ "${1:-}" == -t ]] && shift
    [[ -f "$d/live-${1:-}" ]] ;;
  new-session)
    [[ "${TMUX_STUB_FAIL:-0}" == 1 ]] && exit 1
    while [[ $# -gt 0 && "$1" != -s ]]; do shift; done
    [[ "${1:-}" == -s ]] && touch "$d/live-${2:?}"
    exit 0 ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; stub_agent_binaries "$work/bin"
export PATH="$work/bin:$PATH"
export HOME="$work/home" XDG_CACHE_HOME="$work/cache"
mkdir -p "$HOME"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

# --- Python unit checks: config validation, estimates and projection ---
python3 - "$here" <<'PY' && ok "config defaults, validation, size labels and projection" || { echo "FAIL - python unit checks"; fail=1; }
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import nogg_usage as u

cfg = u.gate_config(None)
assert cfg == u.gate_config({}) == {
    'enabled': True, 'cap_percent': 92, 'estimate_percent': {'default': 5},
    'stale_seconds': 600, 'on_unknown': 'warn',
    'size_multipliers': {'small': 0.5, 'medium': 1, 'large': 2},
    'exclude_roles': ['planning', 'orchestrator']}, cfg
assert u.gate_config({'//': 'comment'})['cap_percent'] == 92
for bad in [[], 'on', {'enabled': 'yes'}, {'cap_percent': 0}, {'cap_percent': 101},
            {'cap_percent': True}, {'cap_percent': float('nan')}, {'cap_percent': '92'},
            {'estimate_percent': -1}, {'estimate_percent': 101}, {'estimate_percent': None},
            {'estimate_percent': {'gpt': 5}}, {'estimate_percent': {'codex': 'x'}},
            {'stale_seconds': 0}, {'stale_seconds': -5}, {'on_unknown': 'allow'},
            {'on_unknown': None}, {'size_multipliers': {}}, {'size_multipliers': []},
            {'size_multipliers': {'huge': 0}}, {'size_multipliers': {'a:b': 1}},
            {'exclude_roles': 'planning'}, {'exclude_roles': ['root']}, {'cap': 92}]:
    try:
        u.gate_config(bad)
    except ValueError:
        continue
    raise AssertionError(f'accepted bad config {bad!r}')

per_agent = u.gate_config({'estimate_percent': {'codex': 8}})
assert u.launch_estimate('codex', [], per_agent)['estimate_percent'] == 8
assert u.launch_estimate('claude', [], per_agent)['estimate_percent'] == 5
assert u.launch_estimate('codex', ['size:large', 'x'], cfg) == {
    'base_percent': 5, 'size': 'large', 'multiplier': 2, 'estimate_percent': 10}
assert u.launch_estimate('codex', ['size:small'], cfg)['estimate_percent'] == 2.5
assert u.launch_estimate('codex', ['size:small', 'size:small'], cfg)['size'] == 'small'
for labels in (['size:small', 'size:large'], ['size:huge']):
    try:
        u.launch_estimate('codex', labels, cfg)
    except ValueError:
        continue
    raise AssertionError(labels)

def report(*windows):
    return {'windows': [dict(bucket=b, status='known' if used is not None else 'unknown',
                             reason=None if used is not None else 'stale observation',
                             used_percent=used, resets_at=reset)
                        for b, used, reset in windows]}
ok_ = u.evaluate_gate(report(('short', 87, 'S'), ('weekly', 10, 'W')), cfg, 5)
assert ok_['decision'] == 'admitted' and ok_['fits'] is True, ok_
weekly = u.evaluate_gate(report(('short', 10, 'S'), ('weekly', 88, 'W')), cfg, 5)
assert weekly['decision'] == 'denied' and weekly['retry_after'] == 'W', weekly
assert [w['fits'] for w in weekly['windows']] == [True, False]
assert 'weekly 88% used' in u.describe_denial(weekly) and 'resets W' in u.describe_denial(weekly)
both = u.evaluate_gate(report(('short', 90, '2026-10-11T15:00:00Z'), ('weekly', 95, '2026-10-17T00:00:00Z')), cfg, 5)
assert both['retry_after'] == '2026-10-17T00:00:00Z'
unknown = u.evaluate_gate(report(('short', None, None), ('weekly', 10, 'W')), cfg, 5)
assert unknown['decision'] == 'unknown-admitted' and unknown['fits'] is None
assert unknown['windows'][0]['projected_percent'] is None
deny = u.gate_config({'on_unknown': 'deny'})
assert u.evaluate_gate(report(('short', None, None), ('weekly', 10, 'W')), deny, 5)['decision'] == 'unknown-denied'
# A known over-cap window denies even when another window is unknown.
assert u.evaluate_gate(report(('short', None, None), ('weekly', 99, 'W')), cfg, 5)['decision'] == 'denied'
assert u.evaluate_gate(report(('short', 80, 'S'), ('weekly', 1, 'W')), cfg, 5, reserved_percent=10)['decision'] == 'denied'
assert u.observe('pi', cfg)['windows'][0]['reason'] == 'unsupported usage provider'
PY

codex_usage() {  # codex_usage <dir> <short used> <weekly used> [age seconds]
  python3 - "$@" <<'PY'
import datetime as dt, json, sys
from pathlib import Path
root, short, weekly = Path(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
age = int(sys.argv[4]) if len(sys.argv) > 4 else 0
now = dt.datetime.now(dt.timezone.utc)
stamp = now - dt.timedelta(seconds=age)
base = int(now.timestamp())
path = root / 'sessions' / stamp.strftime('%Y/%m/%d') / 'rollout-gate.jsonl'
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({'type': 'event_msg', 'timestamp': stamp.isoformat(),
    'payload': {'type': 'token_count', 'rate_limits': {
        'primary': {'used_percent': short, 'window_minutes': 300, 'resets_at': base + 3600},
        'secondary': {'used_percent': weekly, 'window_minutes': 10080, 'resets_at': base + 86400}}}}) + '\n')
PY
}

claude_usage() {  # claude_usage [age seconds]: statusline capture cache in $XDG_CACHE_HOME
  python3 - "${1:-0}" <<'PY'
import datetime as dt, json, os, sys
from pathlib import Path
now = dt.datetime.now(dt.timezone.utc)
base = int(now.timestamp())
path = Path(os.environ['XDG_CACHE_HOME']) / 'nogging/usage/claude.json'
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({'schema_version': 1,
    'observed_at': (now - dt.timedelta(seconds=int(sys.argv[1]))).isoformat().replace('+00:00', 'Z'),
    'rate_limits': {'five_hour': {'used_percentage': 1, 'resets_at': base + 3600},
                    'seven_day': {'used_percentage': 1, 'resets_at': base + 86400}}}))
PY
}

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/scripts/hooks" "$r/openspec" "$r/.pi/extensions" "$r/.agents"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$repo_root/scripts/nogg" \
     "$repo_root/scripts/nogg_usage.py" "$r/scripts/"
  git init -q "$r"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$r/.nogging/"
  cp "$repo_root/templates/model-selection.json" "$r/.nogging/model-selection.json"
  copy_host_config "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  python3 - "$r/.nogging/config.json" "$r/.nogging/config.json" "${GATE_CONFIG:-}" <<'PY'
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
  mkdir -p "$TMUX_STUB_DIR"
}

rc=0
run_launch() {
  rc=0
  "$nogg" session launch --role "${ROLE:-lead}" --bead SPEC-gate --cwd "$root" "$@" >"$out" 2>&1 || rc=$?
}

no_side_effects() {
  local label="$1"
  [[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null || true)" ]] \
    && ok "$label: no session record or settings file" || bad "$label: session state left behind"
  ! grep -qF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null \
    && ok "$label: no tmux session" || bad "$label: tmux new-session reached"
  [[ -z "$(ls "$work" | grep -E -- "-plan-" || true)" ]] || bad "$label: worktree allocated"
}

record_gate() {  # prints the launched record's usage_gate.decision
  python3 - "$root/.nogging/state/sessions" <<'PY'
import json, sys
from pathlib import Path
recs = [json.loads(p.read_text()) for p in Path(sys.argv[1]).glob('*.json')
        if not p.name.endswith('.settings.json')]
assert len(recs) == 1, recs
print(recs[0]['usage_gate']['decision'])
PY
}

# Fits: 87 + 5 = 92 <= cap, both windows known.
new_root; codex_usage "$CODEX_HOME" 87 40
run_launch --agent codex
[[ $rc -eq 0 && "$(record_gate)" == admitted ]] && ok "fitting launch is admitted and recorded" || bad "fitting launch"

# Short window over the cap: exit 75 naming the reset, nothing created.
new_root; codex_usage "$CODEX_HOME" 88 40
run_launch --agent codex
[[ $rc -eq 75 ]] && grep -qF "short 88% used" "$out" && grep -qF "resets " "$out" && grep -qF "retry after" "$out" \
  && ok "over-cap short window exits 75 naming the reset" || bad "short window denial (rc=$rc)"
no_side_effects "short window denial"

# Weekly exhausted while the short window fits.
new_root; codex_usage "$CODEX_HOME" 10 90
run_launch --agent codex
[[ $rc -eq 75 ]] && grep -qF "weekly 90% used" "$out" && ! grep -qF "short 10%" "$out" \
  && ok "weekly bucket limits while short window fits" || bad "weekly denial (rc=$rc)"
no_side_effects "weekly denial"

# Size label scales the estimate: 85 + 5*2 = 95 > 92 denies; small 85 + 2.5 fits.
new_root; codex_usage "$CODEX_HOME" 85 10
BD_STUB_LABELS='["size:large"]' run_launch --agent codex
[[ $rc -eq 75 ]] && grep -qF "10% estimate" "$out" && ok "size:large doubles the estimate" || bad "size:large (rc=$rc)"
no_side_effects "size:large denial"
new_root; codex_usage "$CODEX_HOME" 85 10
BD_STUB_LABELS='["size:small"]' run_launch --agent codex
[[ $rc -eq 0 ]] && ok "size:small halves the estimate" || bad "size:small (rc=$rc)"
new_root; codex_usage "$CODEX_HOME" 1 1
BD_STUB_LABELS='["size:small","size:large"]' run_launch --agent codex
[[ $rc -eq 1 ]] && grep -qF "conflicting size labels" "$out" && ok "conflicting size labels refuse" || bad "conflicting sizes (rc=$rc)"
no_side_effects "conflicting size labels"

# Codex keeps its newest observation until each window resets: aged but unreset
# is known (marked stale), so weekly 98% denies instead of admitting unknown.
new_root; codex_usage "$CODEX_HOME" 10 98 900
run_launch --agent codex
[[ $rc -eq 75 ]] && grep -qF "weekly 98% used" "$out" && ! grep -qF "usage is unknown" "$out" \
  && ok "aged Codex observation with weekly 98% denies" || bad "aged codex denial (rc=$rc)"
no_side_effects "aged codex denial"
new_root; codex_usage "$CODEX_HOME" 10 40 900
run_launch --agent codex
[[ $rc -eq 0 && "$(record_gate)" == admitted ]] && ! grep -qF "usage is unknown" "$out" \
  && ok "aged fitting Codex observation is admitted" || bad "aged codex admit (rc=$rc)"
"$nogg" usage --agent codex >"$out" 2>&1
grep -qF "; stale (observed 15m ago)" "$out" && ok "nogg usage shows the stale age" || bad "stale age text"

# Unknown usage: a stale Claude source warns and launches by default, never as zero.
new_root; claude_usage 601
run_launch --agent claude
[[ $rc -eq 0 ]] && grep -qF "usage is unknown (short: stale observation" "$out" \
  && [[ "$(record_gate)" == unknown-admitted ]] \
  && ok "stale usage warns and launches (unknown-admitted)" || bad "unknown warn (rc=$rc)"
rm -f "$XDG_CACHE_HOME/nogging/usage/claude.json"
GATE_CONFIG='{"on_unknown":"deny","stale_seconds":30}' new_root; claude_usage 60
run_launch --agent claude
[[ $rc -eq 75 ]] && grep -qF "on_unknown is deny" "$out" && ok "on_unknown=deny exits 75" || bad "unknown deny (rc=$rc)"
no_side_effects "unknown deny"
rm -f "$XDG_CACHE_HOME/nogging/usage/claude.json"
# Missing source for the default claude agent warns too.
new_root
run_launch
[[ $rc -eq 0 ]] && grep -qF "claude usage is unknown" "$out" && ok "claude without capture warns and launches" || bad "claude unknown (rc=$rc)"

# Bad configuration refuses before any side effect, even with the override.
for bad_cfg in '{"cap_percent":150}' '{"on_unknown":"allow"}' '{"enabeld":true}' '[]'; do
  GATE_CONFIG="$bad_cfg" new_root; codex_usage "$CODEX_HOME" 1 1
  run_launch --agent codex --ignore-usage-gate
  [[ $rc -eq 1 ]] && grep -qF "invalid usage_gate" "$out" && ok "bad config $bad_cfg refused" || bad "bad config $bad_cfg (rc=$rc)"
  no_side_effects "bad config $bad_cfg"
done
GATE_CONFIG='{"cap_percent":0}' new_root
"$nogg" usage --agent codex >"$out" 2>&1 && bad "usage accepted bad config" || ok "usage refuses bad config"

# --ignore-usage-gate launches past a denial and is recorded.
new_root; codex_usage "$CODEX_HOME" 99 99
run_launch --agent codex --ignore-usage-gate
[[ $rc -eq 0 && "$(record_gate)" == ignored ]] && grep -qF -- "--ignore-usage-gate" "$out" \
  && ok "--ignore-usage-gate is explicit and recorded" || bad "ignore (rc=$rc)"

# Disabled gate and excluded planning role do not observe usage.
GATE_CONFIG='{"enabled":false}' new_root; codex_usage "$CODEX_HOME" 99 99
run_launch --agent codex
[[ $rc -eq 0 && "$(record_gate)" == disabled ]] && ok "disabled gate admits and records" || bad "disabled (rc=$rc)"
GATE_CONFIG='{"exclude_roles":[]}' new_root; codex_usage "$CODEX_HOME" 99 99
ROLE=specialist:backend-engineer run_launch --agent codex
[[ $rc -eq 75 ]] && ok "specialist launches are gated" || bad "specialist gate (rc=$rc)"

# Configured cap and per-agent estimate apply.
GATE_CONFIG='{"cap_percent":50,"estimate_percent":{"codex":20}}' new_root; codex_usage "$CODEX_HOME" 31 1
run_launch --agent codex
[[ $rc -eq 75 ]] && grep -qF "31% used + 0% reserved + 20% estimate = 51% > cap 50%" "$out" \
  && ok "configured cap and per-agent estimate" || bad "configured values (rc=$rc)"

# usage --json exposes estimate, projection and fit.
new_root; codex_usage "$CODEX_HOME" 87 10
"$nogg" usage --agent codex --json >"$out"
python3 - "$out" <<'PY' && ok "usage --json reports estimate, projection and fit" || bad "usage json"
import json, sys
gate = json.load(open(sys.argv[1]))['gate']
assert gate['estimate_percent'] == 5 and gate['cap_percent'] == 92 and gate['fits'] is True
assert [w['projected_percent'] for w in gate['windows']] == [92, 15]
PY

# TASK-GSU-003: race real launch commands, retaining a live tmux fixture.
new_root; codex_usage "$CODEX_HOME" 87 40
export TMUX_STUB_LIVE=1
set +e
"$nogg" session launch --agent codex --role lead --bead SPEC-race-a --cwd "$root" >"$work/race-a.log" 2>&1 &
launch_a=$!
"$nogg" session launch --agent codex --role lead --bead SPEC-race-b --cwd "$root" >"$work/race-b.log" 2>&1 &
launch_b=$!
wait "$launch_a"; rc_a=$?
wait "$launch_b"; rc_b=$?
set -e
[[ "$rc_a:$rc_b" == 0:75 || "$rc_a:$rc_b" == 75:0 ]] \
  && ok "concurrent launch commands admit exactly one final slot" || bad "concurrent launches ($rc_a:$rc_b)"
"$nogg" usage --agent codex --json >"$out"
python3 - "$out" <<'PYTEST' && ok "live reservation appears in usage projections" || bad "usage reservation projection"
import json, sys
report = json.load(open(sys.argv[1]))
assert report['gate']['reserved_percent'] == 5
assert report['gate']['decision'] == 'denied'
assert [w['reserved_percent'] for w in report['gate']['windows']] == [5, 5]
PYTEST
# Terminal state releases headroom even if the tmux server still has a pane.
python3 - "$root/.nogging/state/sessions" <<'PYTEST'
import json, sys
from pathlib import Path
for path in Path(sys.argv[1]).glob('*.json'):
    rec = json.loads(path.read_text())
    if 'state' in rec:
        rec['state'] = 'failed'
        path.write_text(json.dumps(rec))
PYTEST
run_launch --agent codex
[[ $rc -eq 0 ]] && ok "terminal owner releases the previous reservation" || bad "terminal reservation release"
unset TMUX_STUB_LIVE

# A tmux startup failure must release before this launcher exits; retry fits.
new_root; codex_usage "$CODEX_HOME" 87 40
TMUX_STUB_FAIL=1 run_launch --agent codex
[[ $rc -eq 1 ]] && ok "failed launch reports failure" || bad "expected startup failure"
run_launch --agent codex
[[ $rc -eq 0 ]] && ok "failed launch returns its headroom for retry" || bad "failed launch leaked reservation"

# Failure before session metadata exists returns the pending reservation too.
new_root; codex_usage "$CODEX_HOME" 87 40
mv "$root/scripts/session-log-writer" "$root/scripts/session-log-writer.saved"
run_launch --agent codex
[[ $rc -eq 1 ]] && ok "helper negotiation fails before launch" || bad "expected helper failure"
mv "$root/scripts/session-log-writer.saved" "$root/scripts/session-log-writer"
run_launch --agent codex
[[ $rc -eq 0 ]] && ok "pre-record failure returns pending headroom" || bad "helper failure leaked reservation"

exit $fail
