#!/usr/bin/env bash
# TASK-LCD-002: a real backend start must remove a pane/session created before
# a later startup step fails. The fake models tmux's stateful session table.
set -euo pipefail
source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$source_root/scripts/lib/test-agents.sh"
stub_agent_binaries "${TMPDIR:-/tmp}/lcd002-agent-stubs-$$"
python3 - "$source_root" <<'PY'
from pathlib import Path
import subprocess
import sys

source = Path(sys.argv[1])
sys.path.insert(0, str(source / 'scripts/lib'))
from session_backend_tmux import TmuxBackend
from session_backend_herdr import HerdrBackend
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

# Keep the real HerdrBackend.start wrapper and drive its stateful pane boundary:
# layout.apply has created a pane, then post-create identity inspection fails.
panes = []
closed = []
herdr = HerdrBackend({'session_repository_root': '/tmp', 'session_herdr_session': 'test'},
                     lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, '', ''))
def fail_after_create(name, cwd, env, argv, log):
    panes.append({'pane_id': 'pane-1', 'label': name})
    raise RuntimeError('injected Herdr identity failure')
def cli(*args, **kwargs):
    if args[:2] == ('pane', 'close'):
        closed.append(args[2])
        panes.clear()
    return subprocess.CompletedProcess(args, 0, '', '')
herdr._start = fail_after_create
herdr._panes = lambda ref: list(panes)
herdr._cli = cli
try:
    herdr.start('lcd-herdr-test', '/tmp', {}, ['agent'], LogCapture('/tmp/log', '/writer', 100, 1))
except RuntimeError as exc:
    assert str(exc) == 'injected Herdr identity failure'
else:
    raise AssertionError('injected Herdr failure was swallowed')
assert closed == ['pane-1'] and not panes, (closed, panes)
print('session launch cleanup: tmux and Herdr partial starts removed')
PY
