#!/usr/bin/env bash
# Primitive seam contracts and backend-neutral reservation migration (HDR-002).
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Command construction/execution must stay in the tmux module, including
# orphan/adopt/cleanup paths. Keep the legacy injectable function definition.
if grep -nE '\btmux\(|\b(tmux_bin|tmux_socket)\(' "$here/nogg" | grep -vE '^[0-9]+:def tmux\('; then
  echo 'FAIL - direct tmux call in scripts/nogg' >&2
  exit 1
fi
python3 - "$here" <<'PY'
import ast
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from unittest.mock import patch
import os
sys.dont_write_bytecode = True
for key in list(os.environ):
    if key.startswith(('NOGG_', 'NOGGING_')):
        os.environ.pop(key, None)
here = Path(sys.argv[1])
sys.path[:0] = [str(here / 'lib'), str(here)]
import session_backend as b
import nogg_usage as u

# Also catch reintroducing raw substrate argv through run/subprocess directly.
tree = ast.parse((here / 'nogg').read_text())
commands = {'new-session', 'pipe-pane', 'has-session', 'list-sessions',
            'send-keys', 'load-buffer', 'paste-buffer', 'delete-buffer',
            'capture-pane', 'display-message', 'kill-session', 'kill-server'}
assert not any(isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value in commands
               for n in ast.walk(tree)), 'tmux command construction escaped seam'

calls = []
reply = subprocess.CompletedProcess([], 0, '', '')
def run(*args, **kwargs):
    calls.append((args, kwargs))
    return reply
backend = b.resolve('tmux', {'session_tmux_command': '/custom/tmux',
                            'session_tmux_socket': 'isolated'}, run)
assert not calls, 'resolving a backend has side effects'
assert backend.capabilities.capture_attributes
assert backend.capabilities.read_only_attach and not backend.capabilities.agent_status
assert backend.agent_status('s') is None
try: b.resolve('missing', {}, run)
except RuntimeError: pass
else: raise AssertionError('unknown backend resolved')

log = b.LogCapture('/logs/with space.log', '/writer with space', 1234, 2)
ref = backend.start('s', '/cwd with space', {'NOGG_SESSION_NAME': 's', 'OTHER': 'x y'},
                    ['wrapper', '--flag', 'literal $text'], log)
assert ref == {'name': 's', 'socket': 'isolated'}
assert calls[0][0] == ('/custom/tmux', '-L', 'isolated', 'new-session', '-d', '-s', 's',
                       '-c', '/cwd with space', '-e', 'NOGG_SESSION_NAME=s',
                       '-e', 'OTHER=x y', '--', 'wrapper', '--flag', 'literal $text')
assert calls[1][0][3:7] == ('pipe-pane', '-o', '-t', 's')
assert shlex.split(calls[1][0][-1]) == ['exec', '/writer with space', '/logs/with space.log', '1234', '2']
assert calls[0][1] == calls[1][1] == {'check': True}
backend.send_text(ref, 'text; $(literal)\nsecond line')
load, paste, cleanup = calls[-3:]
buffer = load[0][-2]
assert load[0][3:] == ('load-buffer', '-b', buffer, '-')
assert load[1] == {'check': True, 'input': 'text; $(literal)\nsecond line'}
assert paste[0][3:] == ('paste-buffer', '-p', '-r', '-d', '-b', buffer, '-t', 's')
assert cleanup == (('/custom/tmux', '-L', 'isolated', 'delete-buffer', '-b', buffer),
                   {'check': False})
for key, raw in [('enter', 'Enter'), ('escape', 'Escape'), ('ctrl+c', 'C-c'), ('ctrl+u', 'C-u')]:
    backend.send_keys(ref, key)
    assert calls[-1][0][3:] == ('send-keys', '-t', 's', raw)
try: backend.send_keys(ref, 'unrecognized')
except ValueError: pass
else: raise AssertionError('invalid key accepted')
reply = subprocess.CompletedProcess([], 0, '\x1b[2m❯ hint\x1b[0m\n', '')
assert backend.capture(ref, True) == reply.stdout
assert calls[-1][0][3:] == ('capture-pane', '-p', '-e', '-t', 's')
backend.capture(ref)
assert calls[-1][0][3:] == ('capture-pane', '-p', '-t', 's')
reply = subprocess.CompletedProcess([], 0, ' 1234\n', '')
assert backend.pid(ref) == 1234
assert calls[-1][0][3:] == ('display-message', '-p', '-t', 's', '#{pane_pid}')
reply = subprocess.CompletedProcess([], 0, 's\nunmanaged\n\n', '')
assert backend.live([{'name': 's'}]) == ({'s', 'unmanaged'}, set())
reply = subprocess.CompletedProcess([], 1, '', 'no server')
assert backend.live([{'name': 's'}]) == (set(), set())
assert not backend.exists(ref) and backend.capture(ref) == '' and backend.pid(ref) is None
assert backend.attach_argv(ref, True) == ['/custom/tmux', '-L', 'isolated', 'attach', '-t', 's', '-r']
backend.kill(ref)
assert calls[-1] == (('/custom/tmux', '-L', 'isolated', 'kill-session', '-t', 's'), {'check': False})
backend.idle_shutdown()
assert calls[-1][0][3:] == ('kill-server',)
probe = backend.liveness_probe(ref)
assert probe == {'backend': 'tmux', 'argv': ['/custom/tmux', '-L', 'isolated', 'has-session', '-t', 's']}
print('ok - registry, capabilities, normalized keys and unchanged tmux primitives')

# Bound reservations survive launcher death and transient probe errors, and
# read pre-seam ledgers without rewriting their on-disk representation.
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    record = root / 'session.json'
    record.write_text('{"state":"running"}')
    report = dict(provider='codex', account=None, model_group=None, windows=[
        dict(bucket=name, status='known', reason=None, used_percent=80, resets_at='2099-01-01T00:00:00Z')
        for name in ['short', 'weekly']])
    ledger = u.Reservations(root / 'ledger')
    token = ledger.admit(report, u.gate_config(None), 5)['reservation_id']
    with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0)):
        ledger.bind(token, record, 's', probe)
        ledger.finish(token)
        entries = json.loads((ledger.root / 'ledger.json').read_text())
        assert entries[token]['session']['probe'] == probe
        assert 'tmux' not in entries[token]['session']
        assert ledger.totals(report) == {'short': 5, 'weekly': 5}
    for result in [subprocess.CompletedProcess([], 2), FileNotFoundError(),
                   subprocess.TimeoutExpired('probe', 5)]:
        kwargs = {'side_effect': result} if isinstance(result, Exception) else {'return_value': result}
        with patch('subprocess.run', **kwargs):
            assert ledger.totals(report) == {'short': 5, 'weekly': 5}
    legacy = entries[token]['session']
    legacy.pop('probe')
    legacy.update(tmux='/old/tmux', socket='old-socket')
    path = ledger.root / 'ledger.json'
    path.write_text(json.dumps(entries))
    before = path.read_bytes()
    with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0)) as mocked:
        assert ledger.totals(report) == {'short': 5, 'weekly': 5}
        assert mocked.call_args.args[0] == ['/old/tmux', '-L', 'old-socket', 'has-session', '-t', 's']
    assert path.read_bytes() == before
    with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 1)):
        assert ledger.totals(report) == {'short': 0, 'weekly': 0}
    record.write_text('{"state":"stopped"}')
    with patch('subprocess.run', side_effect=AssertionError('terminal session probed')):
        assert ledger.totals(report) == {'short': 0, 'weekly': 0}
print('ok - backend probes, legacy ledgers, terminal owners and unknown liveness')
PY
