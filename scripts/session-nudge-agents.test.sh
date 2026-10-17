#!/usr/bin/env bash
# TASK-HHB-009: agent-specific nudge and composer verification.
set -euo pipefail
for name in $(compgen -e); do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX) unset "$name" ;; esac
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import contextlib, io, pathlib, sys
from importlib.machinery import SourceFileLoader
from types import SimpleNamespace
from unittest.mock import patch

root = pathlib.Path(sys.argv[1])
m = SourceFileLoader('nudge_agents', str(root / 'scripts/nogg')).load_module()
codex_spike = (root / 'scripts/fixtures/herdr/spike/read/codex/idle-placeholder.ansi').read_text()
agy_spike = (root / 'scripts/fixtures/herdr/spike/read/agy/idle.ansi').read_text()
R = '─' * 30

# Typed captures are labelled derivatives of the committed spike captures.
codex_placeholder = next(line for line in codex_spike.splitlines() if 'Ask Codex' in line)
assert m._codex_composer_input(codex_spike) == ('placeholder', '')
assert m._codex_composer_input('[Pasted Content]') == ('input', '')
codex_typed = codex_spike.replace(codex_placeholder,
    '\x1b[0m\x1b[1m› \x1b[0mcontinue testing\x1b[0m')
assert m._codex_composer_input(codex_typed) == ('input', 'continue testing')
assert m._codex_composer_input('ordinary output\n') == ('unknown', '')
assert m._codex_composer_input('› \x1b[2mplaceholder\x1b[0m') == ('placeholder', '')

# Antigravity ignores all status-bar text below its framed composer.
agy_empty = f'{R}\n\x1b[0m> \x1b[0m\n{R}\n? for shortcuts · Gemini 3.8 Flash · high\n'
assert m._antigravity_composer_input(agy_empty) == ('empty', '')
agy_input = f'{R}\n> \x1b[0mcontinue testing\x1b[0m\n{R}\n? for shortcuts · Gemini\n'
assert m._antigravity_composer_input(agy_input) == ('input', 'continue testing')
agy_plan_line = next(line for line in agy_spike.splitlines() if 'Plan mode:' in line)
agy_placeholder = agy_spike.replace(agy_plan_line,
    f'\x1b[0m> \x1b[2mPlan mode: research & plan only\x1b[0m')
assert m._antigravity_composer_input(agy_placeholder) == ('placeholder', '')
assert m._antigravity_composer_input('> unframed\n? for shortcuts') == ('unknown', '')

# Antigravity composer soft-wraps a long message at narrow pane width onto
# continuation lines indented by two spaces (Decision 4, TASK-RSI-003).
# Composer extraction and normalized comparison tolerate soft-wrap while
# still refusing genuinely different text.
agy_wrapped_fixture = (root / 'scripts/fixtures/herdr/spike/read/agy/wrapped-narrow.ansi').read_text()
long_msg = "Orchestrator live delivery check for Antigravity session. Please confirm receipt and status. Thank you. Reply with BEREIT."
kind, wrapped_input = m._antigravity_composer_input(agy_wrapped_fixture)
assert kind == 'input'
assert m._normalized_delivery_text(wrapped_input) == m._normalized_delivery_text(long_msg)
assert m._normalized_delivery_text(wrapped_input) != m._normalized_delivery_text("different text")

# Plain text fallback (no SGR attributes):
plain_box = m._antigravity_prompt_box_text(agy_wrapped_fixture)
assert plain_box is not None
assert m._normalized_delivery_text(plain_box) == m._normalized_delivery_text(long_msg)

# _composer_holds_message and _delivery_composer_state accept soft-wrapped Antigravity composer
probe_rec = {'name': 'probe', 'agent': 'antigravity'}
with patch.object(m, 'session_pane_text', return_value=agy_wrapped_fixture), \
     patch.object(m, '_require_running', return_value=(None, probe_rec)), \
     patch.object(m, 'backend_for_name', return_value=(SimpleNamespace(capabilities=SimpleNamespace(capture_attributes=True)), {})):
    assert m._composer_holds_message('probe', 'antigravity', long_msg)
    assert m._delivery_composer_state('probe', 'antigravity', long_msg) == 'pending'
    # Genuinely different text is refused as other
    assert not m._composer_holds_message('probe', 'antigravity', 'different message')
    assert m._delivery_composer_state('probe', 'antigravity', 'different message') == 'other'

# Codex nudge uses the queue first and never touches the pane when accepted.
rec = {'name': 'probe', 'agent': 'codex', 'codex_thread_id': 'thread'}
out = io.StringIO()
with patch.object(m, '_require_running', return_value=(None, rec)), \
     patch.object(m, '_codex_queue_deliver_locked', return_value='submitted') as queue, \
     patch.object(m, 'session_action') as action, contextlib.redirect_stdout(out):
    m.session_nudge('probe', 'please continue')
assert queue.call_args.args[:3] == ('probe', rec, 'please continue')
assert not action.called and 'nudged probe' in out.getvalue()

# If the queue refuses, a pending Codex composer is retried once and the
# command fails without claiming that it nudged the session.
codex_tmux = SimpleNamespace(capabilities=SimpleNamespace(capture_attributes=True))
codex_rec = {'name': 'probe', 'agent': 'codex'}
out = io.StringIO()
with patch.object(m, '_require_running', return_value=(None, codex_rec)), \
     patch.object(m, '_codex_queue_deliver_locked', return_value='not-attempted'), \
     patch.object(m, 'backend_for_name', return_value=(codex_tmux, {})), \
     patch.object(m, 'session_pane_text', return_value=codex_typed), \
     patch.object(m, 'session_action') as action, \
     patch.object(m.time, 'sleep'), contextlib.redirect_stdout(out):
    try:
        m.session_nudge('probe', 'continue testing')
    except RuntimeError as exc:
        assert 'unsubmitted after one retry' in str(exc)
    else:
        raise AssertionError('pending Codex composer was accepted')
assert not action.called or any(call.args[1:] == ('send_text', 'continue testing') for call in action.call_args_list)
assert 'nudged probe' not in out.getvalue()

# A herdr status of working or done confirms submit without another Enter.
herdr = SimpleNamespace(capabilities=SimpleNamespace(capture_attributes=False))
for status in ('working', 'done'):
    actions = []
    def action(name, operation, *args, **kwargs):
        actions.append((operation, args))
        return status if operation == 'agent_status' else None
    with patch.object(m, 'backend_for_name', return_value=(herdr, {'herdr_session': 'probe'})), \
         patch.object(m, 'session_action', side_effect=action), patch.object(m.time, 'sleep'):
        m._verify_submitted('probe', 'antigravity', 'continue testing')
    assert actions == [('agent_status', ())], (status, actions)

# If the submitted text remains in the framed composer, one retry is allowed,
# then the send fails as unsubmitted; a status-bar line cannot change this.
state = {'count': 0}
def capture(name, operation, *args, **kwargs):
    if operation == 'capture':
        state['count'] += 1
        return agy_input
    if operation == 'agent_status':
        return 'idle'
    return None
with patch.object(m, 'backend_for_name', return_value=(herdr, {'herdr_session': 'probe'})), \
     patch.object(m, 'session_action', side_effect=capture), patch.object(m.time, 'sleep'):
    try:
        m._verify_submitted('probe', 'antigravity', 'continue testing')
    except RuntimeError as exc:
        assert 'unverified after a retry' in str(exc)
    else:
        raise AssertionError('pending Antigravity input was accepted')
assert state['count'] == 2, state
print('Codex and Antigravity nudge verification regressions passed')
PY
