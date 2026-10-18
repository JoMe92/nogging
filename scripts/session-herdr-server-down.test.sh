#!/usr/bin/env bash
# TASK-HHB-005: stopped-server recovery and conservative liveness.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from unittest.mock import patch

source = Path(sys.argv[1])
sys.dont_write_bytecode = True
for key in list(os.environ):
    if key.startswith(('NOGG_', 'HERDR_')) or key in {'TMUX', 'NOGGING_ROOT'}:
        os.environ.pop(key)
sys.path.insert(0, str(source / 'scripts/lib'))
from session_backend import BackendError
from session_backend_herdr import HerdrBackend

with tempfile.TemporaryDirectory(prefix='nogg.', dir='/tmp') as directory:
    root = Path(directory)
    stub = root / 'stub'
    stub.mkdir()
    sock = str(root / 'herdr.sock')
    (stub / 'socket_path').write_text(sock)
    executable = root / 'herdr'
    executable.write_text('#!/bin/sh\nexport HERDR_STUB_DIR=' + shlex.quote(str(stub)) +
                          '\nexec ' + shlex.quote(str(source / 'scripts/fixtures/herdr/bin/herdr')) + ' "$@"\n')
    executable.chmod(0o755)
    (root / 'scripts').symlink_to(source / 'scripts', target_is_directory=True)
    (root / '.nogging').mkdir()
    config = {'session_herdr_command': str(executable), 'session_herdr_session': 'nogging',
              'session_repository_root': str(root), 'session_repository_slug': 'down-test'}
    (root / '.nogging/config.json').write_text(json.dumps(config))
    backend = HerdrBackend(config, lambda *args, check=False, **kw:
                           subprocess.run(args, text=True, capture_output=True, **kw))
    state_file = stub / 'state.json'
    receipt = backend.state / 'server.json'

    def state():
        return json.loads(state_file.read_text())

    def stop_server():
        subprocess.run([str(executable), '--session', 'nogging', 'server', 'stop'],
                       env=dict(os.environ, HERDR_STUB_DIR=str(stub)), check=True)

    # Start through the public CLI and prove it makes no session record or pane.
    stop_server()
    env = dict(os.environ, HERDR_STUB_DIR=str(stub), NOGGING_ROOT=str(root))
    result = subprocess.run([str(source / 'scripts/nogg'), 'session', 'herdr-server', 'start'],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert 'running (owned)' in result.stdout
    started = json.loads(receipt.read_text())
    snapshot = state()
    assert not snapshot['panes'] and not snapshot['workspaces']
    assert not list((root / '.nogging/state/sessions').glob('*.json'))

    result = subprocess.run([str(source / 'scripts/nogg'), 'session', 'herdr-server', 'start'],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(receipt.read_text()) == started
    assert state() == snapshot

    # A legacy receipt is upgraded only after host-side ownership verification.
    receipt.write_text(json.dumps({'pid': started['pid'], 'start': started['start']}))
    result = subprocess.run([str(source / 'scripts/nogg'), 'session', 'herdr-server', 'start'],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    upgraded = json.loads(receipt.read_text())
    assert upgraded['pid_ns'] and upgraded['socket'] == started['socket']
    assert receipt.stat().st_mode & 0o777 == 0o600

    # Fenced invocations refuse before touching the receipt or herdr state.
    before = (receipt.read_bytes(), state())
    result = subprocess.run([str(source / 'scripts/nogg'), 'session', 'herdr-server', 'start'],
                            env=dict(env, NOGG_OPENSPEC_FENCED='1'), text=True, capture_output=True)
    assert result.returncode != 0 and 'host-only' in result.stderr
    assert (receipt.read_bytes(), state()) == before

    rec = {'name': 'sf-dead', 'backend': 'herdr', 'backend_ref': {'label': 'sf-dead', 'herdr_session': 'nogging'}}
    stop_server()
    assert backend.live([rec]) == (set(), set())

    # The public reconciliation and reap paths consume the same definite-down
    # result, leaving the record terminal and available for a same-Bead retry.
    record = dict(name='sf-dead', bead_id='SPEC-test', role='lead', state='running',
                  started_at='test', backend='herdr', backend_ref=rec['backend_ref'],
                  working_dir=str(root), host='test')
    record_dir = root / '.nogging/state/sessions'
    record_dir.mkdir(parents=True)
    record_path = record_dir / 'sf-dead.json'
    record_path.write_text(json.dumps(record))
    listed = subprocess.run([str(source / 'scripts/nogg'), 'session', 'list'],
                            env=env, text=True, capture_output=True)
    assert listed.returncode == 0, (listed.returncode, listed.stdout, listed.stderr)
    assert 'failed' in listed.stdout.lower() and 'sf-dead' in listed.stdout, listed.stdout
    reaped = subprocess.run([str(source / 'scripts/nogg'), 'session', 'reap'],
                            env=env, text=True, capture_output=True)
    assert reaped.returncode == 0, reaped.stderr
    assert 'sf-dead' in reaped.stdout and json.loads(record_path.read_text())['state'] == 'failed'
    assert record['bead_id'] == 'SPEC-test'  # failed records do not cover a same-Bead retry

    # Either failed answer or a disagreement keeps the record unknown.
    (stub / 'fail_status').write_text('injected status failure')
    assert backend.live([rec]) == (set(), {'sf-dead'})
    (stub / 'fail_status').unlink()

    def disagree(*args, check=False, **kwargs):
        result = subprocess.run(args, text=True, capture_output=True, **kwargs)
        if args[-3:] == ('session', 'list', '--json') and result.returncode == 0:
            value = json.loads(result.stdout)
            for session in value['sessions']:
                if session['name'] == 'nogging':
                    session['running'] = True
            result.stdout = json.dumps(value)
        return result

    doubtful = HerdrBackend(config, disagree)
    assert doubtful.live([rec]) == (set(), {'sf-dead'})
    stop_server()
    print('ok - server recovery is idempotent and host-only; agreed shutdown is vanished; doubt remains unknown')
PY
