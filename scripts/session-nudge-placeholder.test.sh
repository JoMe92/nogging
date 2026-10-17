#!/usr/bin/env bash
# TASK-CSL-004 (#42): a suggested placeholder is never input. Real Claude
# pane captures (scripts/fixtures/claude-panes, `capture-pane -p -e`) show a
# suggestion as dim text in the framed `❯` box; nudge without --message must
# execute nothing for it, and an explicit --message is verified submitted.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import contextlib, io, os, pathlib, sys
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
for key in list(os.environ):
    if key.startswith(('NOGG_', 'NOGGING_', 'HERDR_', 'TMUX')):
        os.environ.pop(key, None)
m = SourceFileLoader('nudge_placeholder', str(root/'scripts/nogg')).load_module()
fixtures = {f.stem: f.read_text() for f in (root/'scripts/fixtures/claude-panes').glob('*.txt')}
assert set(fixtures) >= {'placeholder', 'empty', 'input'}
R = '─' * 30
cls = m._claude_prompt_input
assert cls(fixtures['placeholder']) == ('placeholder', ''), 'real dim suggestion'
assert cls(fixtures['empty']) == ('empty', '')
assert cls(fixtures['input']) == ('input', 'continue with the next task')
# Without escapes the dim attribute is lost: positive identification needs -e.
assert cls(f'{R}\n❯ \x1b[2;37mrun the tests\x1b[0m\n{R}\n') == ('placeholder', '')
assert cls(f'{R}\n❯ \x1b[7mr\x1b[0;2mun the tests\x1b[0m\n{R}\n') == ('unknown', ''), 'mixed cursor/dim'
assert cls(f'{R}\n❯ \x1b[2mhint\x1b[22m typed\n{R}\n') == ('unknown', '')
assert cls('previous output\n❯ draft text\n  ⏵⏵ footer\n') == ('unknown', ''), 'unframed'
assert cls(f'{R}\n❯ 1. Yes\n  2. No\n') == ('unknown', ''), 'dialog cursor, not a box'
assert cls(f'{R}\n  footer text\n{R}\n') == ('unknown', ''), 'no prompt marker'
assert cls(f'{R}\n❯ line one\n  line two\n{R}\n') == ('input', 'line one\n  line two')
assert cls('') == ('unknown', '')
# Other runtimes cannot positively identify input text.
with patch.object(m, 'session_pane_text', return_value='> something'):
    assert m.pane_input('s', 'antigravity') == ('unknown', '')
    assert m.pane_input('s', 'pi') == ('unknown', '')
rec = dict(name='s', agent='claude', bead_id='B1')
LAST_SENT = []
LAST_TEXT = []
TIMING = {"session_submit_delay_seconds": .3, "session_submit_verify_delay_seconds": .5,
          "session_delivery_timeout_seconds": 2., "session_startup_timeout_seconds": 4.}
def nudge(pane, after=None, message=None, agent='claude'):
    """Run session_nudge against a fixture pane; return (output, keys sent)."""
    state = {'pane': pane}
    clock = [0.0]
    def fake_sleep(seconds): clock[0] += seconds
    def fake_monotonic(): return clock[0]
    sent = LAST_SENT; sent.clear()
    texts = LAST_TEXT; texts.clear()
    def fake_tmux(*args, check=True, stdin=None):
        if args[0] == 'capture-pane':
            from types import SimpleNamespace
            return SimpleNamespace(returncode=0, stdout=state['pane'])
        sent.append(args)
        if stdin is not None:
            texts.append(stdin)
            state['pane'] = f'{R}\n❯ {stdin}\n{R}\n'
        if args[-1] in ('C-u', 'BSpace'):
            state['pane'] = fixtures['empty']
        if args[-1].lower() == 'enter' and after is not None: state['pane'] = after
        from types import SimpleNamespace
        return SimpleNamespace(returncode=0, stdout='')
    buf = io.StringIO()
    with patch.object(m, '_require_running', return_value=(None, dict(rec, agent=agent))), \
         patch.object(m, 'tmux', side_effect=fake_tmux), patch.object(m.time, 'sleep', side_effect=fake_sleep), \
         patch.object(m.time, 'monotonic', side_effect=fake_monotonic), \
         patch.object(m, 'validate_session_timing_config', return_value=TIMING), \
         contextlib.redirect_stdout(buf):
        try: m.session_nudge('s', message)
        except Exception: raise
    return buf.getvalue(), sent
# Placeholder-only, empty, unknown and multi-line panes execute nothing.
for pane, why in [(fixtures['placeholder'], 'placeholder'), (fixtures['empty'], 'empty'),
                  ('garbled pane', 'cannot be positively identified'),
                  (f'{R}\n❯ line one\n  line two\n{R}\n', 'cannot be resent')]:
    out, sent = nudge(pane)
    assert sent == [], (why, sent)
    assert 'nothing was submitted' in out and '--message' in out and why in out, (why, out)
out, sent = nudge('> pending', agent='codex')
assert sent == [] and '--message' in out
# Positively identified actual input is resent and verified.
out, sent = nudge(fixtures['input'], after=fixtures['empty'])
assert any(a[0] == 'paste-buffer' for a in sent) and LAST_TEXT == ['continue with the next task'] and 'nudged s' in out
# Explicit --message replaces the placeholder deliberately and is verified.
out, sent = nudge(fixtures['placeholder'], after=fixtures['empty'], message='Wie ist der Stand')
assert ('send-keys', '-t', 's', 'ctrl+u') not in sent, sent
assert any(a[0] == 'paste-buffer' for a in sent) and LAST_TEXT == ['Wie ist der Stand'] and 'nudged s' in out
# Explicit --message over unrelated actual input replaces it.
out, sent = nudge(fixtures['input'], after=fixtures['empty'], message='explicit')
assert any(a[0] == 'paste-buffer' for a in sent) and LAST_TEXT == ['explicit']
# Bounded retry: still-pending input is resubmitted once, then fails; an
# unidentifiable pane is unverified, never reported as submitted.
for after, reason in [(f'{R}\n❯ go\n{R}\n', 'unsubmitted'), ('unidentifiable', 'composer is unknown')]:
    try: nudge(fixtures['empty'], after=after, message='go')
    except RuntimeError as exc: assert reason in str(exc), exc
    else: raise AssertionError('unverified submission reported as success')
    enters = sum(1 for a in LAST_SENT if a[-1].lower() == 'enter')
    # Exactly one retry Enter is sent, and only while this message stays pending.
    assert enters == (2 if reason == 'unsubmitted' else 1), LAST_SENT
# Non-running sessions are refused before any tmux interaction.
with patch.object(m, 'load_session', return_value=(None, rec)), \
     patch.object(m, 'reconciled_state', return_value='stopped'), patch.object(m, 'tmux_sessions', return_value=set()), \
     patch.object(m, 'tmux') as tmux:
    try: m.session_nudge('s', 'go')
    except RuntimeError as exc: assert 'not running' in str(exc)
    else: raise AssertionError('non-running nudge accepted')
    assert not tmux.called
print('Placeholder-versus-input nudge/send regressions passed')

# Herdr variant with no SGR capture: framed text is ambiguous, so implicit
# nudge is a no-op; explicit sends use status or replacement verification.
from types import SimpleNamespace
state = {'pane': f'{R}\n❯ suggested text\n{R}\n', 'status': 'idle', 'actions': []}
herdr = SimpleNamespace(capabilities=SimpleNamespace(capture_attributes=False))
def herdr_action(name, operation, *args, **kwargs):
    state['actions'].append((operation, args))
    if operation == 'capture': return state['pane']
    if operation == 'agent_status': return state['status']
    if operation == 'send_text': state['pane'] = f'{R}\n❯ {args[0]}\n{R}\n'
    if operation == 'send_keys' and args[0] in ('ctrl+u', 'enter'): state['pane'] = f'{R}\n❯ \n{R}\n'
    return None
with patch.object(m, 'backend_for_name', return_value=(herdr, {'herdr_session': 'nogging'})), \
     patch.object(m, 'session_action', side_effect=herdr_action), \
     patch.object(m, '_require_running', return_value=(None, dict(rec, agent='claude'))), \
     patch.object(m.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()) as output:
    assert m.pane_input('s', 'claude') == ('unknown', '')
    m.session_nudge('s')
    assert not any(op in ('send_text', 'send_keys') for op, _ in state['actions']), state['actions']
    # Explicit send from a positively empty box verifies.
    state['pane'] = f'{R}\n❯ \n{R}\n'
    m.session_nudge('s', 'explicit')
    assert 'nudged s' in output.getvalue()
    assert ('send_text', ('explicit',)) in state['actions']
    state['pane'] = f'{R}\n❯ \n{R}\n'
    state['actions'].clear()
    with patch.object(m, 'load_session', return_value=(None, dict(rec, agent='claude'))), \
         patch.object(m, 'tmux_has_session', return_value=True):
        m.session_send('s', 'send verify', verify=True)
    assert ('send_text', ('send verify',)) in state['actions']

# If the sent text remains in the identifiable box and status stays idle,
# verification retries once and reports failure.
state.update(pane=f'{R}\n❯ \n{R}\n', status='idle', actions=[])
def herdr_stuck_action(name, operation, *args, **kwargs):
    state['actions'].append((operation, args))
    if operation == 'capture': return state['pane']
    if operation == 'send_text': state['pane'] = f'{R}\n❯ {args[0]}\n{R}\n'
    if operation == 'agent_status': return 'idle'
    if operation == 'send_keys' and args[0] == 'ctrl+u': state['pane'] = f'{R}\n❯ \n{R}\n'
    return None
clock = [0.0]
def fake_stuck_sleep(seconds): clock[0] += seconds
def fake_stuck_monotonic(): return clock[0]
with patch.object(m, 'backend_for_name', return_value=(herdr, {'herdr_session': 'nogging'})), \
     patch.object(m, 'session_action', side_effect=herdr_stuck_action), \
     patch.object(m, '_require_running', return_value=(None, dict(rec, agent='claude'))), \
     patch.object(m.time, 'sleep', side_effect=fake_stuck_sleep), \
     patch.object(m.time, 'monotonic', side_effect=fake_stuck_monotonic), \
     patch.object(m, 'validate_session_timing_config', return_value=TIMING), \
     contextlib.redirect_stdout(io.StringIO()):
    try: m.session_nudge('s', 'explicit')
    except RuntimeError as exc: assert 'after a retry' in str(exc), exc
    else: raise AssertionError('herdr submission without replacement was accepted')
    assert sum(op == 'send_keys' and args == ('enter',) for op, args in state['actions']) == 2
print('Herdr no-attributes nudge/send verification regressions passed')
PY
