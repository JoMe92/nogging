#!/usr/bin/env bash
# TASK-LCD-002: a real backend start must remove a pane/session created before
# a later startup step fails. The fake models tmux's stateful session table.
set -euo pipefail
source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$source_root" <<'PY'
from pathlib import Path
import subprocess
import sys

source = Path(sys.argv[1])
sys.path.insert(0, str(source / 'scripts/lib'))
from session_backend_tmux import TmuxBackend
from session_backend import LogCapture

sessions = set()
calls = []
def run(*argv, check=True, **kwargs):
    calls.append(argv)
    command = next(arg for arg in argv if arg in {'new-session', 'pipe-pane', 'kill-session'})
    if command == 'new-session':
        name = argv[argv.index('-s') + 1]
        sessions.add(name)
    elif command == 'pipe-pane':
        raise RuntimeError('injected pipe-pane failure')
    elif command == 'kill-session':
        sessions.discard(argv[argv.index('-t') + 1])
    return subprocess.CompletedProcess(argv, 0, '', '')

backend = TmuxBackend({'session_tmux_command': 'tmux', 'session_tmux_socket': 'test'}, run)
try:
    backend.start('lcd-test', '/tmp', {}, ['agent'], LogCapture('/tmp/log', '/writer', 100, 1))
except RuntimeError as exc:
    assert str(exc) == 'injected pipe-pane failure'
else:
    raise AssertionError('injected failure was swallowed')
assert sessions == set(), f'orphaned tmux sessions: {sessions}'
assert [next(arg for arg in call if arg in {'new-session', 'pipe-pane', 'kill-session'}) for call in calls] == ['new-session', 'pipe-pane', 'kill-session'], calls
assert all('kill-server' not in call for call in calls)
print('session launch cleanup: tmux partial start removed')
PY
