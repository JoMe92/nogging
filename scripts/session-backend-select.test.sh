#!/usr/bin/env bash
# Selection precedence, record-based dispatch, and unknown-liveness safety (HDR-003).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import contextlib
import importlib.machinery
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='session-backend-select-') as temp:
    repo = Path(temp)
    (repo / '.nogging').mkdir()
    config = json.loads((source / '.nogging/config.json').read_text())
    config.pop('session_backend', None)
    config['session_state_dir'] = '.nogging/state/sessions'
    config['session_tmux_command'] = '/missing/tmux'
    config['session_herdr_command'] = '/missing/herdr'
    (repo / '.nogging/config.json').write_text(json.dumps(config))
    env = os.environ.copy()
    env['NOGGING_ROOT'] = str(repo)

    def cli(*args):
        return subprocess.run([str(source / 'scripts/nogg'), *args], env=env,
                              text=True, capture_output=True, timeout=10)

    # Invalid and unavailable selections fail before records, usage, worktrees,
    # trust or backend effects can be created.
    for value in ('bogus', 'herdr'):
        result = cli('session', 'launch', '--role', 'lead', '--bead', 'SPEC-test',
                     '--backend', value)
        assert result.returncode != 0, (value, result.stdout, result.stderr)
        assert 'backend' in (result.stdout + result.stderr).lower()
        assert not (repo / '.nogging/state').exists(), value

    # Orchestrator is pinned to tmux despite config and rejects explicit herdr.
    result = cli('session', 'launch', '--role', 'orchestrator', '--backend', 'herdr')
    assert result.returncode != 0 and 'pinned to tmux' in result.stderr
    assert not (repo / '.nogging/state').exists()

    os.environ['NOGGING_ROOT'] = str(repo)
    module = importlib.machinery.SourceFileLoader('nogg_backend_select', str(source / 'scripts/nogg')).load_module()
    assert module.choose_launch_backend(False, None, None) == 'tmux'
    assert module.choose_launch_backend(False, 'herdr', 'tmux') == 'herdr'
    assert module.choose_launch_backend(False, 'tmux', 'herdr') == 'tmux'
    assert module.choose_launch_backend(False, None, 'herdr') == 'herdr'
    assert module.choose_launch_backend(True, None, 'herdr') == 'tmux'
    try:
        module.choose_launch_backend(True, 'herdr', 'tmux')
    except RuntimeError as exc:
        assert 'pinned to tmux' in str(exc)
    else:
        raise AssertionError('orchestrator herdr override was accepted')

    backend_module = module.session_backend_module()
    calls = []
    class FakeBackend:
        name = 'herdr'
        def live(self, records):
            return set(), {record['name'] for record in records}
        def send_text(self, ref, text):
            calls.append((ref, text))
    backend_module.register('herdr', lambda config, run, **kwargs: FakeBackend())
    sessions = repo / '.nogging/state/sessions'
    sessions.mkdir(parents=True)
    record = {'name': 'herdr-session', 'backend': 'herdr',
              'backend_ref': {'herdr_session': 'nogging', 'workspace': 'ws',
                              'pane_id': 'p-1', 'label': 'herdr-session'},
              'state': 'running', 'role': 'lead', 'started_at': 'now'}
    (sessions / 'herdr-session.json').write_text(json.dumps(record))

    assert module.backend_for_record({'name': 'legacy'})[1] == 'legacy'
    assert module.backend_for_record({'name': 'herdr-session', 'backend': 'herdr',
                                      'backend_ref': record['backend_ref']})[1] == record['backend_ref']
    module.session_action('herdr-session', 'send_text', 'hello')
    assert calls == [(record['backend_ref'], 'hello')]
    alive, unknown = module.session_liveness()
    assert 'herdr-session' in unknown and 'herdr-session' not in alive

    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        module.session_reap()
        module.session_list()
    rendered = output.getvalue()
    assert 'left records untouched' in rendered
    assert 'running (unknown)' in rendered
    assert 'BACKEND' in rendered and 'herdr' in rendered
    assert json.loads((sessions / 'herdr-session.json').read_text())['state'] == 'running'
    record['state'] = 'failed'
    (sessions / 'herdr-session.json').write_text(json.dumps(record))
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        module.session_cleanup('herdr-session')
    assert 'left herdr-session untouched' in output.getvalue()
    assert json.loads((sessions / 'herdr-session.json').read_text())['state'] == 'failed'

print('session backend selection and per-record dispatch passed')
PY
