#!/usr/bin/env bash
# TASK-CSL-004 (#42): a suggested placeholder is never input. Real Claude
# pane captures (scripts/fixtures/claude-panes, `capture-pane -p -e`) show a
# suggestion as dim text in the framed `❯` box; nudge without --message must
# execute nothing for it, and an explicit --message is verified submitted.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import contextlib, io, pathlib, sys
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
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
def nudge(pane, after=None, message=None, agent='claude'):
    """Run session_nudge against a fixture pane; return (output, keys sent)."""
    state = {'pane': pane}
    sent = LAST_SENT; sent.clear()
    def fake_tmux(*args, check=True):
        if args[0] == 'capture-pane':
            from types import SimpleNamespace
            return SimpleNamespace(returncode=0, stdout=state['pane'])
        sent.append(args)
        if args[-1] == 'Enter' and after is not None: state['pane'] = after
        from types import SimpleNamespace
        return SimpleNamespace(returncode=0, stdout='')
    buf = io.StringIO()
    with patch.object(m, '_require_running', return_value=(None, dict(rec, agent=agent))), \
         patch.object(m, 'tmux', side_effect=fake_tmux), patch.object(m.time, 'sleep'), \
         contextlib.redirect_stdout(buf):
        m.session_nudge('s', message)
    return buf.getvalue(), sent
# Placeholder-only, empty, unknown and multi-line panes execute nothing.
for pane, why in [(fixtures['placeholder'], 'placeholder'), (fixtures['empty'], 'empty'),
                  ('garbled pane', 'cannot be positively identified'),
                  (f'{R}\n❯ line one\n  line two\n{R}\n', 'cannot be resent')]:
    out, sent = nudge(pane)
    assert sent == [], (why, sent)
    assert 'nothing was submitted' in out and '--message' in out and why in out, out
out, sent = nudge('> pending', agent='codex')
assert sent == [] and '--message' in out
# Positively identified actual input is resent and verified.
out, sent = nudge(fixtures['input'], after=fixtures['empty'])
assert ('send-keys', '-t', 's', '-l', 'continue with the next task') in sent and 'nudged s' in out
# Explicit --message replaces the placeholder deliberately and is verified.
out, sent = nudge(fixtures['placeholder'], after=fixtures['placeholder'], message='Wie ist der Stand')
assert sent[0] == ('send-keys', '-t', 's', 'C-u')
assert ('send-keys', '-t', 's', '-l', 'Wie ist der Stand') in sent and 'nudged s' in out
# Explicit --message over unrelated actual input replaces it.
out, sent = nudge(fixtures['input'], after=fixtures['empty'], message='explicit')
assert [a for a in sent if '-l' in a] == [('send-keys', '-t', 's', '-l', 'explicit')]
# Bounded retry: still-pending input is resubmitted once, then fails; an
# unidentifiable pane is unverified, never reported as submitted.
for after, reason in [(fixtures['input'], 'unsubmitted'), ('unidentifiable', 'could not be verified')]:
    try: nudge(fixtures['empty'], after=after, message='go')
    except RuntimeError as exc: assert reason in str(exc), exc
    else: raise AssertionError('unverified submission reported as success')
    enters = sum(1 for a in LAST_SENT if a[-1] == 'Enter')
    # Claude submits with two Enters; a single retry doubles that, no more.
    assert enters == (4 if reason == 'unsubmitted' else 2), LAST_SENT
# Non-running sessions are refused before any tmux interaction.
with patch.object(m, 'load_session', return_value=(None, rec)), \
     patch.object(m, 'reconciled_state', return_value='stopped'), patch.object(m, 'tmux_sessions', return_value=set()), \
     patch.object(m, 'tmux') as tmux:
    try: m.session_nudge('s', 'go')
    except RuntimeError as exc: assert 'not running' in str(exc)
    else: raise AssertionError('non-running nudge accepted')
    assert not tmux.called
print('Placeholder-versus-input nudge/send regressions passed')
PY
