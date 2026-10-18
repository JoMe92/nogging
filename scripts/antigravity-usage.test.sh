#!/usr/bin/env bash
# Regression checks for Antigravity quota and pane support (TASK-AGR-005).
#
# Covered:
#   - pane adapter fixtures: live agy 1.3.3 idle/working/needs_input panes and
#     the trust and exhausted-credit wording classify as expected, and agent
#     transcript text never flips an idle pane;
#   - `/usage` normalization: allowlisted fields only, headless exit zero with
#     a non-SUCCESS status, denied actions, an error, a timeout or an
#     unexpected command result is unknown usage, never accepted;
#   - model -> group mapping from the runtime's own group descriptions:
#     unknown/ambiguous mapping is unknown usage, groups are independent
#     reservation pools, weekly and 5h buckets are evaluated separately;
#   - resume timing honors every exhausted applicable bucket;
#   - a real `session launch` is refused with exit 75 before any trust,
#     worktree, tmux or record side effect, and is admitted per model group.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
fixtures="$repo_root/scripts/fixtures/antigravity/1.3.3"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out" 2>/dev/null || true; fail=1; }

# --- pane adapter ------------------------------------------------------------
python3 - "$nogg" "$fixtures/panes" <<'PY' && ok "pane adapter fixtures and false-positive guards" || { echo "FAIL - pane adapter"; fail=1; }
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
m = SourceFileLoader('agr005_panes', sys.argv[1]).load_module()
panes = Path(sys.argv[2])
adapter = m.ADAPTERS['antigravity']
def got(text): return m.classify(text, adapter)
for name, expected in (('idle', 'idle'), ('working', 'working'), ('needs_input', 'needs_input')):
    actual = got((panes / f'{name}.txt').read_text())
    assert actual == expected, (name, actual)
# Imported wording, not observed live: labelled as such in the adapter.
assert got('Do you trust the contents of this project?\n> 1. Yes, I trust this folder\n') == 'needs_input'
assert got('Your AI credits balance is too low to continue.\n? for shortcuts\n') == 'limit'
assert got('Weekly usage limit reached for this model group\n? for shortcuts\n') == 'limit'
# limit outranks needs_input and working outranks idle, as for the other adapters.
assert got('Run this command?\n> 1. Yes\nYour AI credits balance is too low to continue.\n') == 'limit'
# Transcript text mentioning a spinner or prompt phrase must not flip an idle pane.
idle = (panes / 'idle.txt').read_text()
assert got('the doc says Generating... and Run this command? inline\n' + idle) == 'idle'
assert got('nothing recognizable here\n') == 'unknown'
assert got('') == 'unknown'
# `esc to cancel` appears on working and prompting panes alike: never a signal.
assert got('esc to cancel   accept-edits\n') == 'unknown'
PY

# --- quota normalization, mapping, buckets, probe validation, resume ---------
python3 - "$repo_root" "$fixtures/usage.json" <<'PY' && ok "quota adapter: normalization, mapping, buckets, probe validation, resume" || { echo "FAIL - quota adapter"; fail=1; }
import copy, datetime as dt, json, os, stat, subprocess, sys, tempfile
from pathlib import Path
from types import SimpleNamespace
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts'))
import nogg_usage as u
fixture = json.loads(Path(sys.argv[2]).read_text())
os.environ.pop('AGY_NOGG_USAGE_PROBE', None)
tmp = Path(tempfile.mkdtemp())
os.environ['XDG_CACHE_HOME'] = str(tmp / 'cache')
UTC = dt.timezone.utc
now = dt.datetime(2026, 10, 11, 12, tzinfo=UTC)

def doc(gemini=(0.6, 0.5), claude=(1.0, 1.0), extra=None):
    d = copy.deepcopy(fixture)
    for group, (weekly, short) in zip(d['command']['data']['groups'], (gemini, claude)):
        for bucket in group['buckets']:
            bucket['remaining_fraction'] = weekly if bucket['window'] == 'weekly' else short
            bucket['reset_time'] = u.iso(now + (dt.timedelta(days=3) if bucket['window'] == 'weekly'
                                                else dt.timedelta(hours=3)))
    if extra: extra(d)
    return d
def groups_of(d): return u.agy_parse_probe(json.dumps(d))

# 1. The recorded live fixture parses; only allowlisted fields survive.
g = groups_of(fixture)
assert [x['name'] for x in g] == ['Gemini Models', 'Claude and GPT models']
assert set(g[0]['buckets'][0]) == {'id', 'window', 'remaining_fraction', 'reset_time'}
assert 'response' not in json.dumps(g) and 'usage' not in g[0]

# 2. Model -> group mapping comes from the group descriptions.
for model, name in (('gemini-3.8-flash-medium', 'Gemini Models'), ('gemini-3.1-pro-high', 'Gemini Models'),
                    ('claude-sonnet-4-6', 'Claude and GPT models'),
                    ('claude-opus-4-6-thinking', 'Claude and GPT models'),
                    ('gpt-oss-120b-medium', 'Claude and GPT models')):
    assert u.agy_select_group(g, model)[0]['name'] == name, model
for model in ('mystery-9', 'gemini-ultra', 'claude-haiku-9'):
    assert u.agy_select_group(g, model) == (None, 'unknown model mapping'), model
for model in (None, '', '   '):
    assert u.agy_select_group(g, model) == (None, 'unknown model mapping (no model selected; pass --model <id>)'), model
ambiguous = copy.deepcopy(g)
ambiguous[1]['description'] += ', Gemini Flash'
assert u.agy_select_group(ambiguous, 'gemini-3.8-flash-low') == (None, 'ambiguous model mapping')
nodesc = copy.deepcopy(g)
nodesc[0]['description'] = ''
assert u.agy_select_group(nodesc, 'gemini-3.8-flash-low')[1] == 'unknown model mapping'

# Drift guard: every Antigravity model in the model-selection table maps to
# exactly one group with both short and weekly buckets known.
probe_groups = [
    {
        'name': 'Gemini Models',
        'description': 'Models within this group: Gemini Flash, Gemini Pro',
        'buckets': [{'window': '5h'}, {'window': 'weekly'}],
    },
    {
        'name': 'Claude and GPT models',
        'description': 'Models within this group: Claude Opus, Claude Sonnet, GPT-OSS',
        'buckets': [{'window': '5h'}, {'window': 'weekly'}],
    },
]
table_paths = [Path(sys.argv[1]) / '.nogging/model-selection.json',
               Path(sys.argv[1]) / 'templates/model-selection.json']
checked_models = set()
for tpath in table_paths:
    if not tpath.is_file():
        continue
    tbl = json.loads(tpath.read_text())
    for tier_info in tbl.get('agents', {}).get('antigravity', {}).values():
        m_id = tier_info.get('model')
        if m_id:
            checked_models.add(m_id)
assert checked_models, 'drift guard found no antigravity models in table'
for m_id in checked_models:
    grp, err = u.agy_select_group(probe_groups, m_id)
    assert err is None, (m_id, err)
    assert grp is not None, m_id
    windows = {b['window'] for b in grp['buckets']}
    assert {'5h', 'weekly'}.issubset(windows), (m_id, windows)

def report(d, model, at=now, stale=600):
    cache = tmp / 'c.json'
    u.agy_write_cache(cache, groups_of(d), at)
    return u.inspect_usage('antigravity', source=cache, now=at, stale_after=stale, model=model)

# 3. Weekly and 5h buckets are separate windows; used = 1 - remaining.
r = report(doc(), 'gemini-3.8-flash-medium')
assert r['status'] == 'known' and r['model_group'] == 'Gemini Models' and r['account'] is None
assert [(w['bucket'], w['used_percent']) for w in r['windows']] == [('short', 50.0), ('weekly', 40.0)]
assert r['windows'][0]['resets_at'] == '2026-10-11T15:00:00Z'
assert r['windows'][1]['resets_at'] == '2026-10-14T12:00:00Z'
assert 'Weekly Limit' not in json.dumps(r)

# 4. Independent pools: one group exhausted does not affect the other.
exhausted = doc(gemini=(0.4, 0.0), claude=(1.0, 1.0))
cfg = u.gate_config(None)
g_gem = u.evaluate_gate(report(exhausted, 'gemini-3.8-flash-medium'), cfg, 5)
g_cl = u.evaluate_gate(report(exhausted, 'claude-sonnet-4-6'), cfg, 5)
assert g_gem['decision'] == 'denied' and g_cl['decision'] == 'admitted'
assert [w['fits'] for w in g_gem['windows']] == [False, True] and g_gem['retry_after'] == '2026-10-11T15:00:00Z'
assert u.reservation_scope(report(exhausted, 'gemini-3.8-flash-medium')) != \
       u.reservation_scope(report(exhausted, 'claude-sonnet-4-6'))
# Same group, different model: shared pool.
assert u.reservation_scope(report(doc(), 'gemini-3.8-flash-low')) == \
       u.reservation_scope(report(doc(), 'gemini-3.1-pro-high'))

# 5. Weekly limits while 5h fits, and the reverse; both exhausted -> latest reset.
weekly_only = u.evaluate_gate(report(doc(gemini=(0.04, 0.9)), 'gemini-3.8-flash-medium'), cfg, 5)
assert weekly_only['decision'] == 'denied' and [w['fits'] for w in weekly_only['windows']] == [True, False]
assert weekly_only['retry_after'] == '2026-10-14T12:00:00Z'
short_only = u.evaluate_gate(report(doc(gemini=(0.9, 0.04)), 'gemini-3.8-flash-medium'), cfg, 5)
assert [w['fits'] for w in short_only['windows']] == [False, True]
assert short_only['retry_after'] == '2026-10-11T15:00:00Z'
both = u.evaluate_gate(report(doc(gemini=(0.0, 0.0)), 'gemini-3.8-flash-medium'), cfg, 5)
assert both['retry_after'] == '2026-10-14T12:00:00Z'
assert both['retry_guidance']['limiting_windows'] == ['short', 'weekly']
assert both['retry_guidance']['model_switching_allowed'] is False

# 6. Unknown mapping and malformed buckets are unknown usage, never zero.
unmapped = report(doc(), 'mystery-model')
assert unmapped['status'] == 'unknown' and unmapped['model_group'] is None
assert {w['reason'] for w in unmapped['windows']} == {'unknown model mapping'}
assert all(w['used_percent'] is None for w in unmapped['windows'])
assert u.evaluate_gate(unmapped, cfg, 5)['decision'] == 'unknown-admitted'
assert u.evaluate_gate(unmapped, u.gate_config({'on_unknown': 'deny'}), 5)['decision'] == 'unknown-denied'
for bad in (-0.1, 1.5, True, 'x', None, float('nan')):
    def corrupt(d, bad=bad):
        d['command']['data']['groups'][0]['buckets'][0]['remaining_fraction'] = bad
    r = report(doc(extra=corrupt), 'gemini-3.8-flash-medium')
    assert r['windows'][1]['status'] == 'unknown' and r['windows'][0]['status'] == 'known', bad
def drop_weekly(d):
    d['command']['data']['groups'][0]['buckets'] = [b for b in d['command']['data']['groups'][0]['buckets']
                                                    if b['window'] != 'weekly']
r = report(doc(extra=drop_weekly), 'gemini-3.8-flash-medium')
assert r['windows'][1]['reason'] == 'missing bucket' and r['status'] == 'unknown'
def extra_window(d):
    d['command']['data']['groups'][0]['buckets'].append(
        {'id': 'g-daily', 'window': 'daily', 'remaining_fraction': 0.02,
         'reset_time': u.iso(now + dt.timedelta(hours=5))})
r = report(doc(extra=extra_window), 'gemini-3.8-flash-medium')
assert [w['bucket'] for w in r['windows']] == ['short', 'weekly', 'daily'], 'unrecognized window kept'
assert u.evaluate_gate(r, cfg, 5)['decision'] == 'denied'
def dup_weekly(d):
    d['command']['data']['groups'][0]['buckets'].append(copy.deepcopy(d['command']['data']['groups'][0]['buckets'][0]))
r = report(doc(extra=dup_weekly), 'gemini-3.8-flash-medium')
assert r['windows'][1]['reason'] == 'ambiguous bucket'
# stale and elapsed observations
assert report(doc(), 'gemini-3.8-flash-medium', stale=0)['windows'][0]['reason'] in (None, 'stale observation')
cache = tmp / 'stale.json'
u.agy_write_cache(cache, groups_of(doc()), now)
late = now + dt.timedelta(seconds=601)
r = u.inspect_usage('antigravity', source=cache, now=late, model='gemini-3.8-flash-medium')
assert r['status'] == 'unknown' and {w['reason'] for w in r['windows']} == {'stale observation'}
r = u.inspect_usage('antigravity', source=cache, now=now + dt.timedelta(hours=4), stale_after=86400,
                    model='gemini-3.8-flash-medium')
assert 'reset elapsed' in r['windows'][0]['reason']
assert u.inspect_usage('antigravity', source=tmp / 'absent.json', now=now,
                       model='gemini-3.8-flash-medium')['windows'][0]['reason'] == 'missing usage source'

# 7. Headless success is judged by content, not exit status.
def expect_reject(d, text):
    try:
        u.agy_parse_probe(json.dumps(d))
    except ValueError as exc:
        assert text in str(exc), (text, str(exc))
        return
    raise AssertionError(f'accepted {text}')
for mutate, text in (
        (lambda d: d.update(status='ERROR'), 'not SUCCESS'),
        (lambda d: d.update(status=None), 'not SUCCESS'),
        (lambda d: d.update(denied_actions=[{'tool': 'x'}]), 'denied actions'),
        (lambda d: d.update(error='boom'), 'error'),
        (lambda d: d.update(errors=['boom']), 'error'),
        (lambda d: d['command'].update(name='models'), 'unexpected command'),
        (lambda d: d.update(command='usage'), 'unexpected command'),
        (lambda d: d['command']['data'].update(groups=[]), 'no model groups'),
        (lambda d: d['command']['data'].update(groups=[{'buckets': []}]), 'malformed model group')):
    d = copy.deepcopy(fixture); mutate(d); expect_reject(d, text)
for raw in ('', 'not json', '[]', '"SUCCESS"'):
    try:
        u.agy_parse_probe(raw)
    except ValueError as exc:
        assert 'unparseable' in str(exc)
    else:
        raise AssertionError(raw)
# Credit-exhaustion text without the usage command object is not a quota result.
credit = {'status': 'SUCCESS', 'response': 'Your AI credits balance is too low to continue.'}
expect_reject(credit, 'unexpected command')

# 8. The probe: arguments, neutral cwd, no auto-update, validated result.
calls = []
def runner(result=None, exc=None):
    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        if exc: raise exc
        return result
    return run
good = SimpleNamespace(returncode=0, stdout=json.dumps(fixture), stderr='')
found, why = u.agy_probe(run=runner(good), which=lambda name: '/usr/bin/agy')
assert why is None and [x['name'] for x in found] == ['Gemini Models', 'Claude and GPT models']
argv, kw = calls[-1]
assert argv == ['/usr/bin/agy', '--print', '/usage', '--output-format', 'json', '--print-timeout', '30s']
assert kw['env']['AGY_CLI_DISABLE_AUTO_UPDATE'] == 'true' and kw['stdin'] == subprocess.DEVNULL
assert str(kw['cwd']).startswith(str(tmp / 'cache')) and kw['timeout'] == u.AGY_PROBE_TIMEOUT
assert stat.S_IMODE(os.stat(kw['cwd']).st_mode) == 0o700
for result, exc, text in (
        (SimpleNamespace(returncode=0, stdout=json.dumps({**fixture, 'status': 'ERROR'}), stderr=''), None, 'not SUCCESS'),
        (SimpleNamespace(returncode=0, stdout=json.dumps({**fixture, 'denied_actions': ['x']}), stderr=''), None, 'denied actions'),
        (SimpleNamespace(returncode=1, stdout=json.dumps(fixture), stderr='x'), None, 'exited 1'),
        (SimpleNamespace(returncode=0, stdout='', stderr='print timeout'), None, 'unparseable'),
        (None, subprocess.TimeoutExpired('agy', 45), 'timed out'),
        (None, OSError('nope'), 'could not run')):
    found, why = u.agy_probe(run=runner(result, exc), which=lambda name: '/usr/bin/agy')
    assert found is None and text in why, (text, why)
assert u.agy_probe(which=lambda name: None) == (None, 'agy is not installed')
os.environ['AGY_NOGG_USAGE_PROBE'] = '0'
assert u.agy_probe(run=runner(good), which=lambda name: '/usr/bin/agy')[0] is None
os.environ.pop('AGY_NOGG_USAGE_PROBE')

# 9. Cache reuse: fresh -> no probe; stale -> one probe + 0600 rewrite; failed probe -> unknown.
cache = tmp / 'probe-cache' / 'antigravity.json'
n = len(calls)
obs = u.agy_observation(cache=cache, now=now, run=runner(good), which=lambda name: '/usr/bin/agy')
assert obs[2] is None and len(calls) == n + 1 and stat.S_IMODE(cache.stat().st_mode) == 0o600
assert cache.parent.is_dir()
obs = u.agy_observation(cache=cache, now=now + dt.timedelta(seconds=30), run=runner(good),
                        which=lambda name: '/usr/bin/agy')
assert obs[2] is None and len(calls) == n + 1, 'fresh cache must not re-probe'
failing = runner(SimpleNamespace(returncode=0, stdout=json.dumps({**fixture, 'status': 'ERROR'}), stderr=''))
obs = u.agy_observation(cache=cache, now=now + dt.timedelta(seconds=700), run=failing, which=lambda name: '/usr/bin/agy')
assert obs[1] is not None and obs[2] is not None, 'a failed probe must not look fresh'
r = u.antigravity_usage('gemini-3.8-flash-medium', source=None, now=now + dt.timedelta(seconds=700),
                        run=failing, which=lambda name: '/usr/bin/agy')
assert r['status'] == 'unknown' and not any(w['status'] == 'known' for w in r['windows'])

# 10. Resume guidance honors every exhausted applicable bucket.
def resume(d, model='gemini-3.8-flash-medium'):
    cache = tmp / 'r.json'
    u.agy_write_cache(cache, groups_of(d), now)
    return u.antigravity_resume(model, source=cache, now=now)
r = resume(doc(gemini=(0.5, 0.0)))
assert r['status'] == 'wait' and r['resume_at'] == '2026-10-11T15:00:00Z' and r['exhausted'] == ['short']
r = resume(doc(gemini=(0.0, 0.5)))
assert r['status'] == 'wait' and r['resume_at'] == '2026-10-14T12:00:00Z' and r['exhausted'] == ['weekly']
# 5h window already refreshed while the weekly bucket is still exhausted.
r = resume(doc(gemini=(0.0, 1.0)))
assert r['status'] == 'wait' and r['resume_at'] == '2026-10-14T12:00:00Z'
r = resume(doc(gemini=(0.0, 0.0)))
assert r['resume_at'] == '2026-10-14T12:00:00Z' and r['exhausted'] == ['short', 'weekly']
r = resume(doc(gemini=(0.5, 0.5)))
assert r['status'] == 'ready' and r['resume_at'] is None
r = resume(doc(gemini=(0.0, 0.0)), model='claude-sonnet-4-6')
assert r['status'] == 'ready' and r['model_group'] == 'Claude and GPT models', 'other group unaffected'
r = resume(doc(gemini=(0.0, 0.0)), model='mystery-model')
assert r['status'] == 'unknown' and r['resume_at'] is None
PY

# --- resume-when-ready loop uses quota buckets, not a pane clock -------------
python3 - "$nogg" "$repo_root" "$fixtures/usage.json" <<'PY' && ok "resume waits for the limiting weekly bucket" || { echo "FAIL - resume loop"; fail=1; }
import copy, datetime as dt, json, os, sys, tempfile
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[2]) / 'scripts'))
import nogg_usage as u
fixture = json.loads(Path(sys.argv[3]).read_text())
tmp = Path(tempfile.mkdtemp())
os.environ.update(XDG_CACHE_HOME=str(tmp), AGY_NOGG_USAGE_PROBE='0')
m = SourceFileLoader('agr005_resume', sys.argv[1]).load_module()
UTC = dt.timezone.utc
def write(gemini):  # gemini = (weekly remaining, 5h remaining)
    d = copy.deepcopy(fixture)
    for bucket in d['command']['data']['groups'][0]['buckets']:
        weekly = bucket['window'] == 'weekly'
        bucket['remaining_fraction'] = gemini[0] if weekly else gemini[1]
        bucket['reset_time'] = u.iso(dt.datetime.now(UTC) + (dt.timedelta(days=3) if weekly else dt.timedelta(hours=1)))
    u.agy_write_cache(tmp / 'nogging/usage/antigravity.json', u.agy_parse_probe(json.dumps(d)), dt.datetime.now(UTC))
rec = {'name': 'agy-s', 'agent': 'antigravity', 'state': 'running',
       'usage_gate': {'model': 'gemini-3.8-flash-medium'}}
sleeps, sent = [], []
def fake_sleep(seconds):
    sleeps.append(seconds)
    if len(sleeps) == 2:       # weekly quota recovers after two bounded waits
        write((0.5, 1.0))
with patch.object(m, 'load_session', return_value=(Path('x'), rec)), \
     patch.object(m, 'classify_session', return_value=('limit', 'Your AI credits balance is too low')), \
     patch.object(m, 'session_pane_text', return_value=''), \
     patch.object(m, 'session_send', side_effect=lambda *a, **k: sent.append(a)), \
     patch.object(m.time, 'sleep', side_effect=fake_sleep):
    write((0.0, 1.0))          # 5h window already reset; weekly still exhausted
    m.session_resume_when_ready('agy-s', poll_interval=60)
assert sleeps == [60, 60], sleeps
assert len(sent) == 1 and sent[0][0] == 'agy-s'
# `until` for the watch event is the limiting bucket's reset, not a clock token.
write((0.0, 0.0))
status, until = m._antigravity_resume_status(rec, 60)
assert status == 'wait' and until is not None
write((0.5, 0.5))
assert m._antigravity_resume_status(rec, 60) == ('ready', None)
rec['usage_gate'] = {'model': None}
assert m._antigravity_resume_status(rec, 60) == ('unknown', None)
PY

# --- real launches: exit 75 before trust/tmux, per model group ----------------
mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then printf '[{"id":"%s","title":"stub"}]\n' "${2:-}"; exit 0; fi
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
case "$cmd" in has-session) [[ -e "$d/live-${2:-}" ]] || exit 1 ;; *) : ;; esac
STUB
cat >"$work/bin/agy" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--print" && "${2:-}" == "/usage" ]]; then
  printf 'probe cwd=%s auto_update=%s\n' "$PWD" "${AGY_CLI_DISABLE_AUTO_UPDATE:-}" >>"${AGY_STUB_LOG:?}"
  [[ -n "${AGY_STUB_EXIT:-}" ]] && exit "$AGY_STUB_EXIT"
  cat "${AGY_STUB_USAGE:?}"; exit 0
fi
echo "stub agy: unexpected $*" >&2; exit 1
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux" "$work/bin/agy"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; stub_agent_binaries "$work/bin"
export PATH="$work/bin:$PATH"
export HOME="$work/home" XDG_CACHE_HOME="$work/cache" CODEX_HOME="$work/codex"
export AGY_NOGG_USAGE_PROBE=1 AGY_STUB_LOG="$work/agy.log"
mkdir -p "$HOME/.gemini/antigravity-cli" "$CODEX_HOME"
settings="$HOME/.gemini/antigravity-cli/settings.json"
printf '{"toolPermission":"request-review","trustedWorkspaces":["/keep"]}\n' >"$settings"
: >"$AGY_STUB_LOG"

make_usage() {  # make_usage <file> <gemini weekly remaining> <gemini 5h remaining> [claude weekly] [claude 5h]
  python3 - "$fixtures/usage.json" "$@" <<'PY'
import copy, datetime as dt, json, sys
fixture = json.load(open(sys.argv[1]))
out, gw, gs = sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
cw, cs = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0, float(sys.argv[6]) if len(sys.argv) > 6 else 1.0
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
for group, (weekly, short) in zip(fixture['command']['data']['groups'], ((gw, gs), (cw, cs))):
    for bucket in group['buckets']:
        weekly_bucket = bucket['window'] == 'weekly'
        bucket['remaining_fraction'] = weekly if weekly_bucket else short
        delta = dt.timedelta(days=3) if weekly_bucket else dt.timedelta(hours=2)
        bucket['reset_time'] = (now + delta).isoformat().replace('+00:00', 'Z')
json.dump(fixture, open(out, 'w'))
PY
}

n=0
new_root() {
  n=$((n + 1)); root="$work/r$n"
  mkdir -p "$root/.nogging/state" "$root/scripts/hooks" "$root/openspec" "$root/.pi/extensions" "$root/.agents"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$repo_root/scripts/nogg" "$repo_root/scripts/nogg_usage.py" "$root/scripts/"
  cp "$repo_root/scripts/hooks/agy-guard" "$root/scripts/hooks/"
  cp "$repo_root/templates/antigravity/hooks.json" "$root/.agents/hooks.json"
  cp "$repo_root/.pi/extensions/nogging-guard.ts" "$root/.pi/extensions/"
  git init -q "$root"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$root/.nogging/"
  cp "$repo_root/templates/model-selection.json" "$root/.nogging/model-selection.json"
  python3 - "$repo_root/.nogging/config.json" "$root/.nogging/config.json" "${GATE_CONFIG:-}" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None); cfg.pop("usage_gate", None)
if sys.argv[3]:
    cfg["usage_gate"] = json.loads(sys.argv[3])
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
  export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/t$n"; mkdir -p "$TMUX_STUB_DIR"
  printf '{"toolPermission":"request-review","trustedWorkspaces":["/keep"]}\n' >"$settings"
  rm -rf "$XDG_CACHE_HOME"
  : >"$AGY_STUB_LOG"
}
rc=0
run_launch() {
  rc=0
  "$nogg" session launch --role lead --bead SPEC-agr --cwd "$root" --agent antigravity --full-access "$@" >"$out" 2>&1 || rc=$?
}
no_side_effects() {
  local label="$1"
  [[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null || true)" ]] \
    && ok "$label: no session record" || bad "$label: session state left behind"
  ! grep -qF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null \
    && ok "$label: no tmux session" || bad "$label: tmux new-session reached"
  [[ "$(cat "$settings")" == '{"toolPermission":"request-review","trustedWorkspaces":["/keep"]}' ]] \
    && ok "$label: trust settings untouched" || bad "$label: trust settings changed"
}
record_field() {  # record_field <dotted.path>
  python3 - "$root/.nogging/state/sessions" "$1" <<'PY'
import json, sys
from pathlib import Path
recs = [json.loads(p.read_text()) for p in Path(sys.argv[1]).glob('*.json')
        if not p.name.endswith('.settings.json')]
assert len(recs) == 1, recs
value = recs[0]
for key in sys.argv[2].split('.'):
    value = value[key]
print(value)
PY
}

# Gemini 5h exhausted: the Gemini model is refused with exit 75 before trust/tmux.
new_root; make_usage "$work/u1.json" 0.6 0.0; export AGY_STUB_USAGE="$work/u1.json"
run_launch --model gemini-3.8-flash-medium
[[ $rc -eq 75 ]] && grep -qF "short 100% used" "$out" && grep -qF "retry after" "$out" \
  && ok "exhausted 5h bucket of the selected group exits 75" || bad "5h denial (rc=$rc)"
no_side_effects "5h denial"
[[ "$(grep -c 'auto_update=true' "$AGY_STUB_LOG")" == 1 ]] \
  && ok "probe ran once with runtime auto-update disabled" || bad "probe invocation"
grep -qF "cwd=$root" "$AGY_STUB_LOG" && bad "probe ran inside the worktree" || ok "probe runs outside the worktree"

# Same usage, a model from the other group is admitted (independent pools).
new_root; make_usage "$work/u2.json" 0.6 0.0; export AGY_STUB_USAGE="$work/u2.json"
run_launch --model claude-sonnet-4-6
[[ $rc -eq 0 && "$(record_field usage_gate.decision)" == admitted \
   && "$(record_field usage_gate.start_observation.model_group)" == "Claude and GPT models" ]] \
  && ok "other model group is admitted from its own buckets" || bad "claude-group admission (rc=$rc)"
grep -qF "$root" "$settings" && ok "admitted launch trusted only its worktree" || bad "trust not prepared after admission"

# A launch through --tier reaches the gate with the table model (selected_model)
# and produces a known gate for a fixture cache.
new_root; make_usage "$work/u2_tier.json" 0.6 0.5; export AGY_STUB_USAGE="$work/u2_tier.json"
run_launch --tier routine
[[ $rc -eq 0 && "$(record_field usage_gate.decision)" == admitted \
   && "$(record_field usage_gate.start_observation.status)" == "known" \
   && "$(record_field usage_gate.start_observation.model_group)" == "Gemini Models" \
   && "$(record_field usage_gate.model)" == "gemini-3.8-flash-low" ]] \
  && ok "tier launch evaluates gate with selected table model" || bad "tier launch gate (rc=$rc)"

# Weekly exhausted while the 5h bucket fits.
new_root; make_usage "$work/u3.json" 0.0 0.9; export AGY_STUB_USAGE="$work/u3.json"
run_launch --model gemini-3.1-pro-high
[[ $rc -eq 75 ]] && grep -qF "weekly 100% used" "$out" && ! grep -qF "short 10%" "$out" \
  && ok "weekly bucket limits while the 5h bucket fits" || bad "weekly denial (rc=$rc)"
no_side_effects "weekly denial"

# Gate order: refused with 75 even when the guard payload is missing.
new_root; make_usage "$work/u4.json" 0.6 0.0; export AGY_STUB_USAGE="$work/u4.json"
rm "$root/.agents/hooks.json"
run_launch --model gemini-3.8-flash-medium
[[ $rc -eq 75 ]] && ! grep -qF "guard is missing" "$out" \
  && ok "quota gate precedes guard validation and trust" || bad "gate order (rc=$rc)"
no_side_effects "gate order"
# With headroom the same missing guard still refuses before trust or tmux.
new_root; make_usage "$work/u4b.json" 0.6 0.9; export AGY_STUB_USAGE="$work/u4b.json"
rm "$root/.agents/hooks.json"
run_launch --model gemini-3.8-flash-medium
[[ $rc -eq 1 ]] && grep -qF "guard is missing or inactive" "$out" \
  && ok "missing guard still refuses an admitted launch" || bad "missing guard (rc=$rc)"
no_side_effects "missing guard"

# Unknown model mapping is unknown usage: warns, never headroom.
new_root; make_usage "$work/u5.json" 0.0 0.0 0.0 0.0; export AGY_STUB_USAGE="$work/u5.json"
run_launch --model mystery-model
[[ $rc -eq 0 ]] && grep -qF "usage is unknown (short: unknown model mapping" "$out" \
  && [[ "$(record_field usage_gate.decision)" == unknown-admitted ]] \
  && ok "unknown model mapping warns as unknown usage" || bad "unknown mapping (rc=$rc)"
GATE_CONFIG='{"on_unknown":"deny"}' new_root; export AGY_STUB_USAGE="$work/u5.json"
run_launch --model mystery-model
[[ $rc -eq 75 ]] && grep -qF "on_unknown is deny" "$out" && ok "unknown mapping honors on_unknown=deny" || bad "unknown deny (rc=$rc)"
no_side_effects "unknown mapping deny"

# A probe the runtime reports as failed is unknown, whatever its exit status.
new_root; python3 - "$fixtures/usage.json" "$work/u6.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['status'] = 'SUCCESS'; d['denied_actions'] = [{'tool': 'run_command'}]
json.dump(d, open(sys.argv[2], 'w'))
PY
export AGY_STUB_USAGE="$work/u6.json"
run_launch --model gemini-3.8-flash-medium
[[ $rc -eq 0 ]] && grep -qF "usage is unknown (short: usage probe reported denied actions" "$out" \
  && ok "denied_actions with exit zero is not accepted as quota" || bad "denied_actions (rc=$rc)"
new_root; AGY_STUB_EXIT=3 run_launch --model gemini-3.8-flash-medium
[[ $rc -eq 0 ]] && grep -qF "usage probe exited 3" "$out" \
  && ok "failing probe is unknown usage" || bad "probe exit (rc=$rc)"

# nogg usage reports the group, the estimate and the projection.
new_root; make_usage "$work/u7.json" 0.6 0.5; export AGY_STUB_USAGE="$work/u7.json"
"$nogg" usage --agent agy --model gemini-3.8-flash-medium --json >"$out"
python3 - "$out" <<'PY' && ok "usage --agent agy --json exposes the group and per-bucket fit" || bad "usage json"
import json, sys
report = json.load(open(sys.argv[1]))
assert report['provider'] == 'antigravity' and report['model_group'] == 'Gemini Models'
assert report['gate']['fits'] is True and [w['bucket'] for w in report['gate']['windows']] == ['short', 'weekly']
assert report['windows'][0]['used_percent'] == 50.0 and report['windows'][1]['used_percent'] == 40.0
assert 'response' not in json.dumps(report)
PY
"$nogg" usage --agent antigravity --json >"$out"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["status"]=="unknown" and r["model_group"] is None' "$out" \
  && ok "usage without a model is unknown, not a guess" || bad "usage without model"
# A second observation inside the stale window reuses the cache.
: >"$AGY_STUB_LOG"
"$nogg" usage --agent agy --model gemini-3.8-flash-low --json >/dev/null
[[ ! -s "$AGY_STUB_LOG" ]] && ok "fresh cache is reused without another probe" || bad "cache not reused"

exit $fail
