#!/usr/bin/env bash
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$here" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import threading
import os

sys.dont_write_bytecode = True
for key in list(os.environ):
    if key.startswith(('NOGG_', 'NOGGING_')):
        os.environ.pop(key, None)
sys.path.insert(0, str(Path(sys.argv[1]) / 'lib'))
from session_backend_tmux import TmuxBackend

messages = ['Unicode 🙂; quote " and apostrophe \'\nsecond\n', 'other\nmessage']
calls = []
lock = threading.Lock()
loaded = threading.Barrier(2)
def operation(argv):
    return next((arg for arg in argv if arg in
                 ('load-buffer', 'paste-buffer', 'delete-buffer')), None)

def run(*argv, **kwargs):
    if operation(argv) == 'load-buffer':
        with lock:
            calls.append((argv, kwargs))
        loaded.wait(timeout=3)
    else:
        with lock:
            calls.append((argv, kwargs))
    return subprocess.CompletedProcess(argv, 0, '', '')

backend = TmuxBackend({'session_tmux_command': 'tmux', 'session_tmux_socket': 'nogging'}, run)
with ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(lambda message: backend.send_text({'name': 'pane'}, message), messages))

loads = [c for c in calls if operation(c[0]) == 'load-buffer']
pastes = [c for c in calls if operation(c[0]) == 'paste-buffer']
deletes = [c for c in calls if operation(c[0]) == 'delete-buffer']
assert len(loads) == len(pastes) == len(deletes) == 2
buffers = {c[0][-2] for c in loads}
assert len(buffers) == 2 and all(name.startswith('nogg-') for name in buffers)
assert {c[1]['input'] for c in loads} == set(messages)
assert all(c[0][3:] == ('load-buffer', '-b', c[0][-2], '-') for c in loads)
assert all(c[0][3:8] == ('paste-buffer', '-p', '-r', '-d', '-b') for c in pastes)
assert {c[0][8] for c in pastes} == buffers
assert all(c[0][9:] == ('-t', 'pane') for c in pastes)
assert {c[0][-1] for c in deletes} == buffers
assert all('send-keys' not in c[0] for c in calls)

# The command path keeps socket and sandbox fencing, and legacy calls still
# omit the stdin keyword when they do not carry text.
fenced_calls = []
def fenced_run(*argv, **kwargs):
    fenced_calls.append((argv, kwargs))
    return subprocess.CompletedProcess(argv, 0, '', '')
backend = TmuxBackend({'session_tmux_command': '/custom/tmux',
                       'session_tmux_socket': 'isolated'}, fenced_run)
os.environ['NOGG_OPENSPEC_FENCED'] = '1'
backend.command('list-sessions')
backend.send_text('pane', 'x\ny')
del os.environ['NOGG_OPENSPEC_FENCED']
assert fenced_calls[0] == (('/custom/tmux', '-L', 'isolated', '-N', 'list-sessions'),
                           {'check': True})
assert all(c[0][:4] == ('/custom/tmux', '-L', 'isolated', '-N') for c in fenced_calls)
assert fenced_calls[1][1] == {'check': True, 'input': 'x\ny'}

# Load and paste failures both attempt cleanup while preserving the original
# error; no submission key or message contents enter an argv list.
for failed_operation, expected in (
        ('load-buffer', ['load-buffer', 'delete-buffer']),
        ('paste-buffer', ['load-buffer', 'paste-buffer', 'delete-buffer'])):
    failure_calls = []
    def failing_run(*argv, **kwargs):
        failure_calls.append((argv, kwargs))
        if operation(argv) == failed_operation:
            raise RuntimeError(f'{failed_operation} failed')
        return subprocess.CompletedProcess(argv, 0, '', '')
    backend = TmuxBackend({}, failing_run)
    try:
        backend.send_text('pane', 'secret body\n')
    except RuntimeError as exc:
        assert str(exc) == f'{failed_operation} failed'
    else:
        raise AssertionError(f'{failed_operation} failure was swallowed')
    assert [operation(c[0]) for c in failure_calls] == expected
    buffer = failure_calls[0][0][-2]
    assert failure_calls[-1][0][3:] == ('delete-buffer', '-b', buffer)
    assert all('secret body' not in ' '.join(c[0]) for c in failure_calls)
print('ok - isolated stdin paste buffers, LF preservation, fencing, concurrency and cleanup')
PY
