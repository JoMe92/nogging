#!/usr/bin/env bash
# TASK-HHB-004: namespace-safe identities, without namespaces or a real agent.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import contextlib
import importlib.machinery
import io
import json
import os
from pathlib import Path
import shlex
import shutil
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
from session_backend_herdr import HerdrBackend, pid_namespace, process_start

with tempfile.TemporaryDirectory(prefix='nogg.', dir='/tmp') as directory:
    root = Path(directory)
    stub = root / 'stub'
    stub.mkdir()
    socket_path = str(root / 'herdr.sock')
    assert len(os.fsencode(socket_path)) < 108
    (stub / 'socket_path').write_text(socket_path)
    executable = root / 'herdr'
    executable.write_text('#!/bin/sh\nexport HERDR_STUB_DIR=' + shlex.quote(str(stub)) +
                          '\nexec ' + shlex.quote(str(source / 'scripts/fixtures/herdr/bin/herdr')) + ' "$@"\n')
    executable.chmod(0o755)
    (root / 'scripts').symlink_to(source / 'scripts', target_is_directory=True)
    (root / '.nogging').mkdir()
    config = {'session_herdr_command': str(executable), 'session_repository_root': str(root),
              'session_repository_slug': 'namespace-test', 'session_stop_grace_seconds': 0,
              'usage_gate': {'enabled': False}}
    (root / '.nogging/config.json').write_text(json.dumps(config))
    for name in ('launch-profiles', 'launch-prompts'):
        shutil.copytree(source / '.nogging' / name, root / '.nogging' / name)
    sessions = root / '.nogging/state/sessions'
    foreign = False
    child = subprocess.Popen(['/bin/true'])
    dead_pid = child.pid
    child.wait()  # A genuinely reaped child, never a guessed PID range.
    assert not Path(f'/proc/{dead_pid}').exists()
    server_pid = None

    def state():
        return json.loads((stub / 'state.json').read_text())

    def save(value):
        (stub / 'state.json').write_text(json.dumps(value))

    def run(*args, check=False, **kwargs):
        # Simulate server-namespace PIDs in the fake's state, using a reaped
        # child that a local /proc lookup can never use as proof of identity.
        if foreign and 'process-info' in args:
            value = state()
            for pane in value['panes'].values():
                pane['shell_pid'] = dead_pid
            save(value)
        return subprocess.run(args, capture_output=True, text=True, **kwargs)

    def rejects(call, message):
        try:
            call()
        except BackendError as exc:
            assert message in str(exc), str(exc)
        else:
            raise AssertionError('expected refusal: ' + message)

    backend = HerdrBackend(config, run)
    receipt_path = backend.state / 'server.json'
    def receipt(value=None):
        if value is not None:
            receipt_path.write_text(json.dumps(value))
        return json.loads(receipt_path.read_text())

    try:
        run(str(executable), 'server', 'stop')
        baseline = state()
        with patch.dict(os.environ, NOGG_OPENSPEC_FENCED='1'):
            rejects(lambda: backend.prepare('sf-refused', str(root)), 'session herdr-server start')
        assert not backend.state.exists()
        assert not sessions.exists()
        assert state() == baseline  # No workspace, pane, config or receipt.
        assert not any(line.endswith(' server') for line in (stub / 'calls.log').read_text().splitlines())

        # Host-only server startup writes a receipt after the socket is ready.
        prepared = backend.prepare('sf-host', str(root))
        owned = receipt()
        server_pid = owned['pid']
        assert owned['start'] == process_start(server_pid)
        assert owned['pid_ns'] == pid_namespace()
        assert owned['socket'] == backend.verify_socket(socket_path)
        assert prepared['session_pid_ns'] == owned['pid_ns']
        assert receipt_path.stat().st_mode & 0o777 == 0o600
        with patch.dict(os.environ, NOGG_OPENSPEC_FENCED='1'):
            assert backend._ensure_server() == owned

        # All callers reject a replaced socket, including when PID checks are
        # impossible. Changing the receipt avoids relying on inode recycling.
        corrupt = dict(owned, socket=dict(owned['socket'], ino=owned['socket']['ino'] + 1))
        receipt(corrupt)
        rejects(backend._ensure_server, 'socket identity')
        receipt(owned)
        bad_config = backend.state / 'config.toml'
        bad_config.write_text('unowned config')
        rejects(backend._ensure_server, 'config mismatch')
        bad_config.write_bytes(backend._CONFIG.replace('\n', '\r\n').encode())
        rejects(backend._ensure_server, 'config mismatch')
        bad_config.write_text(backend._CONFIG)
        receipt(dict(owned, start='wrong-start'))
        rejects(backend._ensure_server, 'process identity')
        receipt(owned)

        # Legacy ownership is verified and upgraded by a host caller; fenced
        # callers can then verify the resulting modern receipt.
        legacy = {key: owned[key] for key in ('pid', 'start')}
        receipt(legacy)
        upgraded = backend._ensure_server()
        assert upgraded['pid'] == legacy['pid'] and upgraded['start'] == legacy['start']
        assert upgraded['pid_ns'] == pid_namespace() and upgraded['socket'] == owned['socket']
        with patch.dict(os.environ, NOGG_OPENSPEC_FENCED='1'):
            assert backend._ensure_server() == upgraded

        # Real same-namespace process birth checks are retained for old records.
        local_child = subprocess.Popen(['/bin/sleep', '120'])
        try:
            pane = {'pane_id': 'local', 'terminal_id': 'term_local'}
            old_ref = {'session_pid': local_child.pid, 'session_pid_start': process_start(local_child.pid),
                       'session_pid_ns': pid_namespace()}
            with patch.object(backend, '_process_pid', return_value=local_child.pid):
                assert backend._identity(old_ref, pane) is True
                assert backend._identity(dict(old_ref, session_pid_start='wrong'), pane) is False
                assert backend._identity(dict(old_ref, session_pid_ns='pid:[foreign]'), pane) is None
                modern = dict(old_ref, terminal_id='term_local')
                assert backend._identity(modern, pane) is True
                assert backend._identity(dict(modern, session_pid_start='wrong'), pane) is False
                assert backend._identity(modern, dict(pane, terminal_id='term_new')) is False
        finally:
            local_child.terminate()
            local_child.wait()

        # A receipt/PID from another namespace is opaque. Both the backend and
        # the real launch/stop record path must avoid all foreign /proc reads
        # and all local signals (including signal 0).
        receipt(dict(owned, pid=dead_pid, pid_ns='pid:[server-namespace]'))
        foreign = True
        os.environ['NOGGING_ROOT'] = str(root)
        module = importlib.machinery.SourceFileLoader('nogg_namespace_test', str(source / 'scripts/nogg')).load_module()
        module.bead_records = lambda bead: [{'id': bead, 'labels': []}]
        module.unmet_dependencies = lambda bead: []
        module.usage_gate_admission = lambda *args, **kwargs: {}
        module.collect_session_usage = lambda *args, **kwargs: None
        module.release_planning_lock = lambda **kwargs: False
        module.session_backend = lambda name=None: backend
        def local_namespace(pid='self'):
            assert pid == 'self', 'foreign namespace read'
            return pid_namespace()
        with patch.dict(os.environ, NOGG_OPENSPEC_FENCED='1'), \
                patch('session_backend_herdr.process_start', side_effect=AssertionError('foreign /proc read')), \
                patch.object(module, 'process_start', side_effect=AssertionError('foreign launch /proc read')), \
                patch.object(module, 'pid_namespace', side_effect=local_namespace), \
                patch('os.kill', side_effect=AssertionError('foreign signal')), \
                patch('os.killpg', side_effect=AssertionError('foreign group signal')):
            assert backend._ensure_server()['pid_ns'] == 'pid:[server-namespace]'
            foreign_owned = receipt()
            receipt(dict(foreign_owned, socket=corrupt['socket']))
            rejects(backend._ensure_server, 'socket identity')
            receipt(foreign_owned)
            with contextlib.redirect_stdout(io.StringIO()):
                module.session_launch('lead', 'SPEC-test', str(root), False, None,
                                      agent='claude', full_access=True, backend='herdr')
            records = [json.loads(p.read_text()) for p in sessions.glob('sf-*.json')
                       if not p.name.endswith('.settings.json')]
            assert len(records) == 1
            rec = records[0]
            ref = rec['backend_ref']
            assert ref['terminal_id']
            assert rec['session_pid'] == ref['session_pid'] == dead_pid
            assert rec['session_pid_ns'] == ref['session_pid_ns'] == 'pid:[server-namespace]'
            assert rec['session_pid_start'] is ref['session_pid_start'] is None
            assert backend.live([rec]) == ({rec['name']}, set())
            assert backend.live([dict(rec, session_pid=os.getpid())]) == (set(), set())
            probe = backend.liveness_probe(ref)
            assert run(*probe['argv']).returncode == 0
            old_ref = dict(ref)
            old_ref.pop('terminal_id')
            old_rec = dict(rec, backend_ref=old_ref)
            assert backend.live([old_rec]) == (set(), {rec['name']})

            # Pane-ID changes keep identity; restored terminals never do.
            value = state()
            value['panes'][ref['pane_id']]['label'] = 'renamed-label'
            save(value)
            assert backend.live([rec]) == ({rec['name']}, set())
            value['panes'][ref['pane_id']]['label'] = ref['label']
            pane = value['panes'].pop(ref['pane_id'])
            pane['pane_id'] = 'w1:renamed'
            value['panes'][pane['pane_id']] = pane
            save(value)
            assert backend.live([rec]) == ({rec['name']}, set())
            pane['terminal_id'] = 'term_restored'
            save(value)
            assert backend.live([rec]) == (set(), set())
            pane['terminal_id'] = ref['terminal_id']
            save(value)
            with patch.object(module, 'process_ancestors', return_value=[(dead_pid, None)]):
                assert module.calling_session_record() is None
            with contextlib.redirect_stdout(io.StringIO()):
                module.session_stop(rec['name'], 'namespace test')
            assert backend.live([rec]) == (set(), set())
            assert json.loads((sessions / (rec['name'] + '.json')).read_text())['state'] == 'stopped'
        calls = (stub / 'calls.log').read_text()
        assert 'pane close w1:renamed' in calls
        print('ok - fenced refusal, receipts, terminal identity, foreign launch/probe/stop without local PID access')
    finally:
        run(str(executable), 'server', 'stop')
        if server_pid:
            os.waitpid(server_pid, 0)
PY
