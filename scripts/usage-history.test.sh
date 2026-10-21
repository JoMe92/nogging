#!/usr/bin/env bash
# Bounded usage history and conservative learned medians regression tests (TASK-GSU-004).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

# --- Python unit checks: UsageHistory, learned medians, rejections, privacy ---
python3 - "$here" <<'PY'
import datetime as dt
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import nogg_usage as u

cfg = u.gate_config(None)

def make_report(used=40, resets_at='2030-01-01T05:00:00Z', observed_at='2030-01-01T00:00:00Z',
                account='SECRET_ACCOUNT_IDENTIFIER', token='SECRET_CREDENTIAL_VALUE'):
    return {
        'provider': 'codex',
        'status': 'known',
        'account': account,
        'token': token,
        'windows': [
            {'bucket': 'short', 'status': 'known', 'reason': None,
             'used_percent': used, 'resets_at': resets_at, 'observed_at': observed_at},
            {'bucket': 'weekly', 'status': 'known', 'reason': None,
             'used_percent': used + 10, 'resets_at': '2030-01-07T00:00:00Z', 'observed_at': observed_at}
        ]
    }

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'history'
    hist = u.UsageHistory(root, min_samples=3, max_samples=5)

    # 1. Directory and file permissions: owner-only (0700 dir, 0600 file)
    assert not hist.has_sufficient_data('codex', 'o3-mini')
    assert hist.get_median('codex', 'o3-mini') is None
    assert hist.get_estimate('codex', 'o3-mini', fallback=5.0) == 5.0

    # 2. Insufficient data uses fallback in launch_estimate
    est = u.launch_estimate('codex', [], cfg, model='o3-mini', history=hist)
    assert est['base_percent'] == 5 and est['estimate_percent'] == 5

    # 3. Add 1 sample -> still insufficient (< min_samples=3)
    res = hist.record_sample('codex', 'o3-mini', 6.0)
    assert res and res.accepted and res['accepted'] is True and res['reason'] is None
    assert not hist.has_sufficient_data('codex', 'o3-mini')
    assert hist.get_median('codex', 'o3-mini') is None
    assert u.launch_estimate('codex', [], cfg, model='o3-mini', history=hist)['estimate_percent'] == 5

    # 4. Add 2nd sample -> still insufficient
    res = hist.record_sample('codex', 'o3-mini', 8.0)
    assert res and res.accepted
    assert not hist.has_sufficient_data('codex', 'o3-mini')

    # 5. Add 3rd sample -> now sufficient (3 samples: 6, 8, 10 -> median = 8)
    res = hist.record_sample('codex', 'o3-mini', 10.0)
    assert res and res.accepted
    assert hist.has_sufficient_data('codex', 'o3-mini')
    assert hist.get_median('codex', 'o3-mini') == 8.0
    est = u.launch_estimate('codex', [], cfg, model='o3-mini', history=hist)
    assert est['base_percent'] == 8.0 and est['estimate_percent'] == 8.0

    # Size label scales the learned estimate
    est_large = u.launch_estimate('codex', ['size:large'], cfg, model='o3-mini', history=hist)
    assert est_large['base_percent'] == 8.0 and est_large['estimate_percent'] == 16.0
    est_small = u.launch_estimate('codex', ['size:small'], cfg, model='o3-mini', history=hist)
    assert est_small['base_percent'] == 8.0 and est_small['estimate_percent'] == 4.0

    # 6. Conservative learned median with even count: picks upper median
    # Add 4th sample: 12.0 -> samples are [6, 8, 10, 12] -> median_high = 10.0
    hist.record_sample('codex', 'o3-mini', 12.0)
    assert hist.get_median('codex', 'o3-mini') == 10.0

    # 7. Bounded history: max_samples=5
    # Add 5th sample: 14.0 -> samples are [6, 8, 10, 12, 14]
    hist.record_sample('codex', 'o3-mini', 14.0)
    assert len(hist.get_samples('codex', 'o3-mini')) == 5
    # Add 6th sample: 16.0 -> oldest sample (6.0) is dropped, keeping newest 5 [8, 10, 12, 14, 16]
    hist.record_sample('codex', 'o3-mini', 16.0)
    samples = hist.get_samples('codex', 'o3-mini')
    assert len(samples) == 5
    assert [s['delta_percent'] for s in samples] == [8.0, 10.0, 12.0, 14.0, 16.0]

    # 8. Rejection of Overlapping intervals
    res_ov = hist.record_sample('codex', 'o3-mini', 10.0, overlapping=True)
    assert not res_ov and res_ov.accepted is False
    assert 'overlap' in res_ov.reason
    assert len(hist.get_samples('codex', 'o3-mini')) == 5  # not added

    # 9. Rejection of Reset intervals
    res_rst = hist.record_sample('codex', 'o3-mini', 10.0, reset=True)
    assert not res_rst and res_rst.accepted is False
    assert 'reset' in res_rst.reason
    res_neg = hist.record_sample('codex', 'o3-mini', -2.0)
    assert not res_neg and res_neg.accepted is False
    assert 'reset' in res_neg.reason
    assert len(hist.get_samples('codex', 'o3-mini')) == 5

    # 10. Rejection of Outlier samples
    res_out1 = hist.record_sample('codex', 'o3-mini', 10.0, outlier=True)
    assert not res_out1 and res_out1.accepted is False
    assert 'outlier' in res_out1.reason

    # Statistical outlier (samples are around 8-16; delta 60.0 is an extreme outlier)
    res_out2 = hist.record_sample('codex', 'o3-mini', 60.0)
    assert not res_out2 and res_out2.accepted is False
    assert 'outlier' in res_out2.reason
    assert len(hist.get_samples('codex', 'o3-mini')) == 5

    # Outlier exceeding 100%
    res_out3 = hist.record_sample('codex', 'o3-mini', 150.0)
    assert not res_out3 and res_out3.accepted is False
    assert 'outlier' in res_out3.reason

    # 11. Rejection of Incomplete intervals
    res_inc = hist.record_sample('codex', 'o3-mini', 10.0, complete=False)
    assert not res_inc and res_inc.accepted is False
    assert 'incomplete' in res_inc.reason

    # 12. record_interval checks
    start_obs = make_report(used=40, resets_at='2030-01-01T05:00:00Z', observed_at='2030-01-01T01:00:00Z')
    end_obs = make_report(used=47, resets_at='2030-01-01T05:00:00Z', observed_at='2030-01-01T02:00:00Z')

    # Valid interval: delta = 7.0 -> accepted
    res_int = hist.record_interval('codex', 'o3-mini', start_obs, end_obs)
    assert res_int and res_int.accepted
    assert res_int['sample']['delta_percent'] == 7.0

    # Overlapping interval via concurrent_sessions
    res_int_ov = hist.record_interval('codex', 'o3-mini', start_obs, end_obs, concurrent_sessions=2)
    assert not res_int_ov and 'overlap' in res_int_ov.reason

    # Reset boundary crossed
    reset_obs = make_report(used=5, resets_at='2030-01-01T10:00:00Z', observed_at='2030-01-01T06:00:00Z')
    res_int_rst = hist.record_interval('codex', 'o3-mini', start_obs, reset_obs)
    assert not res_int_rst and 'reset' in res_int_rst.reason

    # Counter decreased without reset time change
    lower_obs = make_report(used=30, resets_at='2030-01-01T05:00:00Z', observed_at='2030-01-01T02:00:00Z')
    res_int_dec = hist.record_interval('codex', 'o3-mini', start_obs, lower_obs)
    assert not res_int_dec and 'reset' in res_int_dec.reason

    # Incomplete interval
    res_int_inc = hist.record_interval('codex', 'o3-mini', start_obs, end_obs, complete=False)
    assert not res_int_inc and 'incomplete' in res_int_inc.reason

    # 13. Model independence
    assert not hist.has_sufficient_data('codex', 'gpt-4o')
    assert hist.get_median('codex', 'gpt-4o') is None
    assert not hist.has_sufficient_data('claude', 'sonnet')
    assert hist.get_median('claude', 'sonnet') is None

    # 14. Security and privacy: owner permissions and NO credentials in history file
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    store_file = root / 'history.json'
    assert stat.S_IMODE(store_file.stat().st_mode) == 0o600
    content = store_file.read_text()
    assert 'SECRET_ACCOUNT_IDENTIFIER' not in content
    assert 'SECRET_CREDENTIAL_VALUE' not in content
    assert 'account' not in content
    assert 'token' not in content
    assert 'password' not in content

print('ok - bounded history, conservative medians, overlap/reset/outlier rejection, and privacy')
PY

# --- CLI checks: nogg usage --model and session launch with learned estimates ---
work=$(mktemp -d)
out=$(mktemp)
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -f "$out"; rm -rf "$work"' EXIT

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
if [[ "$cmd" == new-session ]]; then a=("$@"); for i in "${!a[@]}"; do [[ "${a[i]}" == -s ]] && : >"$d/live-${a[i+1]}"; done; fi
case "$cmd" in
  has-session) [[ -e "$d/live-${2:-}" ]] || exit 1 ;;
  new-session) exit 0 ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; stub_agent_binaries "$work/bin"
export PATH="$work/bin:$PATH"
export HOME="$work/home" XDG_CACHE_HOME="$work/cache"
mkdir -p "$HOME" "$XDG_CACHE_HOME"

root="$work/repo"
mkdir -p "$root/.nogging/state" "$root/scripts/hooks" "$root/openspec"
cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
   "$repo_root/scripts/openspec-sandbox" "$repo_root/scripts/nogg" \
   "$repo_root/scripts/nogg_usage.py" "$root/scripts/"
cp -r "$repo_root/scripts/lib" "$root/scripts/lib"
git init -q -b develop "$root"
git -C "$root" -c user.name=Test -c user.email=test@example.org commit -q --allow-empty -m init
cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$root/.nogging/"
cp "$repo_root/templates/model-selection.json" "$root/.nogging/model-selection.json"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
python3 - "$root/.nogging/config.json" "$root/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None)
cfg.pop("usage_gate", None)
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY

export TMUX_STUB_DIR="$work/tmux"
export CODEX_HOME="$work/codex"

codex_usage() {  # codex_usage <dir> <short used> <weekly used> [age seconds]
  python3 - "$@" <<'PY'
import datetime as dt, json, sys
from pathlib import Path
root, short, weekly = Path(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
age = int(sys.argv[4]) if len(sys.argv) > 4 else 0
now = dt.datetime.now(dt.timezone.utc)
stamp = now - dt.timedelta(seconds=age)
base = int(now.timestamp())
path = root / 'sessions' / stamp.strftime('%Y/%m/%d') / 'rollout-hist.jsonl'
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({'type': 'event_msg', 'timestamp': stamp.isoformat(),
    'payload': {'type': 'token_count', 'rate_limits': {
        'primary': {'used_percent': short, 'window_minutes': 300, 'resets_at': base + 3600},
        'secondary': {'used_percent': weekly, 'window_minutes': 10080, 'resets_at': base + 86400}}}}) + '\n')
PY
}

codex_usage "$CODEX_HOME" 40 20

# Populate learned history for codex model o3-mini in XDG_CACHE_HOME
python3 - "$root/scripts" "$XDG_CACHE_HOME/nogging/usage/history" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import nogg_usage as u
hist = u.UsageHistory(sys.argv[2])
hist.record_sample('codex', 'o3-mini', 8.0)
hist.record_sample('codex', 'o3-mini', 10.0)
hist.record_sample('codex', 'o3-mini', 12.0)
PY

# Check nogg usage --agent codex --model o3-mini --json
"$root/scripts/nogg" usage --agent codex --model o3-mini --json >"$out"
python3 - "$out" <<'PY' && ok "nogg usage reports learned estimate for model" || bad "nogg usage model"
import json, sys
data = json.load(open(sys.argv[1]))
assert data['gate']['estimate_percent'] == 10.0, data
assert data['model'] == 'o3-mini'
PY

# Check nogg usage without model still reports fallback estimate (5)
"$root/scripts/nogg" usage --agent codex --json >"$out"
python3 - "$out" <<'PY' && ok "nogg usage without model uses fallback" || bad "nogg usage fallback"
import json, sys
data = json.load(open(sys.argv[1]))
assert data['gate']['estimate_percent'] == 5.0, data
PY

# Session launch with --model o3-mini uses learned estimate (10%)
# With used 84 + reserved 0 + estimate 10 = 94 > cap 92 -> denied!
codex_usage "$CODEX_HOME" 84 20
set +e
"$root/scripts/nogg" session launch --agent codex --role lead --bead SPEC-model-test --model o3-mini --cwd "$root" >"$out" 2>&1
rc=$?
set -e
[[ $rc -eq 75 ]] && grep -qF "84% used + 0% reserved + 10% estimate = 94% > cap 92%" "$out" \
  && ok "session launch uses learned estimate and exits 75 on cap exceed" || bad "session launch gate (rc=$rc)"

# Same launch without model uses fallback 5%: 84 + 5 = 89 <= 92 -> admitted!
set +e
"$root/scripts/nogg" session launch --agent codex --role lead --bead SPEC-model-test --cwd "$root" >"$out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] && ok "session launch without model uses fallback and admits" || bad "session launch fallback (rc=$rc)"

if [[ $fail -ne 0 ]]; then
  echo "FAIL - usage history tests failed" >&2
  exit 1
fi
echo "Nogging: usage history tests passed"
