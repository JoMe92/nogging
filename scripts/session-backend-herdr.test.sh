#!/usr/bin/env bash
# HDR-006: exercise the backend against the real fake CLI/socket boundary.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs
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
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

source = Path(sys.argv[1])
for key in list(os.environ):
    if key.startswith(('NOGG_', 'HERDR_')) or key in {'TMUX', 'NOGGING_ROOT'}:
        os.environ.pop(key)
sys.path.insert(0, str(source / 'scripts/lib'))
from session_backend import BackendError, LogCapture, resolve
from session_backend_herdr import HerdrBackend, process_start

def run(*args, check=False, **kw):
    return subprocess.run(args, text=True, capture_output=True, **kw)

with tempfile.TemporaryDirectory(prefix='nogg.', dir='/tmp') as temp:
    root = Path(temp)
    stub = root / 'stub'
    stub.mkdir()
    (root / 'scripts').symlink_to(source / 'scripts', target_is_directory=True)
    executable = root / 'herdr'
    executable.write_text('#!/bin/sh\nexport HERDR_STUB_DIR=' + shlex.quote(str(stub)) +
                          '\nexec ' + shlex.quote(str(source / 'scripts/fixtures/herdr/bin/herdr')) + ' "$@"\n')
    executable.chmod(0o755)
    config = {'session_herdr_command': str(executable), 'session_repository_root': str(root),
              'session_repository_slug': 'backend-test', 'session_stop_grace_seconds': 0}
    (root / '.nogging').mkdir()
    (root / '.nogging/config.json').write_text(json.dumps(config))
    backend = resolve('herdr', config, run)
    server_pid = None
    processes = []

    def state():
        return json.loads((stub / 'state.json').read_text())

    def save(value):
        (stub / 'state.json').write_text(json.dumps(value))

    def rejects(call, message):
        try:
            call()
        except BackendError as exc:
            assert message in str(exc), str(exc)
        else:
            raise AssertionError('expected refusal: ' + message)

    def fault(name, enabled=True):
        path = stub / name
        if enabled:
            path.touch()
        else:
            path.unlink(missing_ok=True)

    sessions = root / '.nogging/state/sessions'
    sessions.mkdir(parents=True)
    def record(name, ref):
        value = {'name': name, 'backend': 'herdr', 'backend_ref': ref,
                 'state': 'running', 'role': 'lead', 'working_dir': str(root),
                 'log_path': str(root / (name + '.log'))}
        for key in ('session_pid', 'session_pid_start', 'session_pid_ns'):
            if key in ref:
                value[key] = ref[key]
        (sessions / (name + '.json')).write_text(json.dumps(value))
        return value

    def launch(name):
        ref = backend.prepare(name, str(root))
        record(name, ref)  # The record must exist before layout.apply executes.
        log = root / (name + '.log')
        ref = backend.start(name, str(root), {'NOGG_SESSION_AGENT': 'codex',
                            'NOGG_SESSION_NAME': name, 'NOGG_OPENSPEC_FENCE': '1',
                            'NOGG_SESSION_ROOT': str(root), 'NOGG_STARTUP_LOG': str(log)},
                            ['/bin/sh', '-c', 'echo recorder-output; sleep 120'],
                            LogCapture(str(log), str(source / 'scripts/session-log-writer')))
        processes.append(ref['session_pid'])
        return record(name, ref)

    try:
        # Preflight is side-effect free, including refusals for ungated agents.
        backend.preflight('claude')
        backend.preflight('codex')
        backend.preflight('antigravity')
        backend.preflight('pi')
        rejects(lambda: backend.preflight('unknown-agent'), '--backend tmux')
        missing = HerdrBackend(dict(config, session_herdr_command='/missing/herdr'), run)
        rejects(lambda: missing.preflight('codex'), 'backend binary')
        missing_recorder = HerdrBackend(dict(config, session_repository_root=str(root / 'missing')), run)
        rejects(lambda: missing_recorder.preflight('codex'), 'recorder contract')
        assert not (root / '.nogging/state/herdr').exists()

        # Socket checks name every rejected condition, before layout/record.
        unsafe = root / 'unsafe'
        unsafe.write_text('regular file')
        rejects(lambda: backend.verify_socket(str(unsafe)), 'not a Unix socket')
        link = root / 'link'
        link.symlink_to(unsafe)
        rejects(lambda: backend.verify_socket(str(link)), 'symlink')
        rejects(lambda: backend.verify_socket('/tmp/' + 'x' * 110), '108 bytes')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as local:
            path = str(root / 'check.sock')
            local.bind(path)
            os.chmod(path, 0o660)
            rejects(lambda: backend.verify_socket(path), '0600')
            os.chmod(path, 0o600)
            with patch('session_backend_herdr.os.getuid', return_value=os.getuid() + 1):
                rejects(lambda: backend.verify_socket(path), 'owned')
            backend.verify_socket(path)

        # Seed a stopped fake. A tiny executable adapter supplies its test-only
        # state location without adding test variables to the server allowlist.
        run(str(executable), 'server', 'stop')
        fault('real_process')
        os.environ.update(CLAUDECODE='synthetic-nesting', TMUX='synthetic-parent',
                          TEST_TOKEN='synthetic-token', HERDR_SOCKET_PATH='/untrusted/other.sock')
        first = launch('sf-test-first')
        receipt = json.loads((backend.state / 'server.json').read_text())
        server_pid = receipt['pid']
        server_env = dict(item.split('=', 1) for item in Path(f'/proc/{server_pid}/environ').read_bytes()
                          .decode().split('\0') if '=' in item)
        assert not {'CLAUDECODE', 'TMUX', 'TEST_TOKEN', 'HERDR_SOCKET_PATH'} & server_env.keys()
        assert server_env['HERDR_CONFIG_PATH'] == str(backend.state / 'config.toml')
        assert (backend.state / 'config.toml').read_text() == backend._CONFIG
        assert stat.S_IMODE((backend.state / 'config.toml').stat().st_mode) == 0o600
        assert backend.live([first]) == ({first['name']}, set())
        panes = state()['panes']
        pane = panes[first['backend_ref']['pane_id']]
        argv = pane['foreground_processes'][0]['argv']
        assert argv[0].endswith('/scripts/session-pty-recorder') and argv[4] == '--'
        assert argv[5:] == ['/bin/sh', '-c', 'echo recorder-output; sleep 120']
        assert pane['agent'] == 'codex'
        child_env = Path(f"/proc/{first['session_pid']}/environ").read_bytes()
        assert b'HERDR_AGENT=codex\0' in child_env
        assert b'NOGG_OPENSPEC_FENCE=1\0' in child_env
        assert b'TEST_TOKEN=' not in child_env
        assert 'synthetic-token' not in (stub / 'calls.log').read_text()
        assert backend.agent_status(first['backend_ref']) == 'unknown'
        for status in ('idle', 'working', 'blocked', 'done'):
            value = state()
            value['panes'][first['backend_ref']['pane_id']]['agent_status'] = status
            save(value)
            assert backend.agent_status(first['backend_ref']) == status
        fault('fail_agent_get')
        assert backend.agent_status(first['backend_ref']) == 'unknown'
        fault('fail_agent_get', False)
        backend.send_text(first['backend_ref'], 'literal text')
        backend.send_keys(first['backend_ref'], 'enter')
        backend.send_keys(first['backend_ref'], 'escape')
        assert ' esc\n' in (stub / 'calls.log').read_text()
        rejects(lambda: backend.attach_argv(first['backend_ref'], True), 'session log --follow')
        assert backend.attach_argv(first['backend_ref'])[:4] == [str(executable), '--session', 'nogging', 'agent']
        assert backend.capture(first['backend_ref'])
        assert '\x1b[' in backend.capture(first['backend_ref'], attributes=True)

        # A changed pane ID is resolved by label and original process identity.
        value = state()
        old_id = first['backend_ref']['pane_id']
        value['panes']['w1:pZ'] = value['panes'].pop(old_id)
        value['panes']['w1:pZ']['pane_id'] = 'w1:pZ'
        save(value)
        assert backend.live([first]) == ({first['name']}, set())
        # Process-info failures are unknown, never evidence of death.
        fault('fail_pane_process_info')
        assert backend.live([first]) == (set(), {first['name']})
        fault('fail_pane_process_info', False)
        fault('fail_pane_list')
        assert backend.live([first]) == (set(), {first['name']})
        fault('fail_pane_list', False)
        original_json = backend._json
        def malformed_process_info(*args, **kwargs):
            if args[:2] == ('pane', 'process-info'):
                return {'process_info': []}
            return original_json(*args, **kwargs)
        with patch.object(backend, '_json', side_effect=malformed_process_info):
            assert backend.live([first]) == (set(), {first['name']})

        # Invalid birth token disproves liveness even when PID/label match.
        wrong = dict(first, session_pid_start='wrong-birth')
        assert backend.live([wrong]) == (set(), set())
        foreign_namespace = dict(first, session_pid_ns='pid:[unobservable]')
        assert backend.live([foreign_namespace]) == ({first['name']}, set())
        # Reservation probes read the updated record and use only CLI queries.
        probe = backend.liveness_probe(first['backend_ref'])
        assert run(*probe['argv']).returncode == 0
        record(first['name'], dict(first['backend_ref'], session_pid_start='wrong-birth'))
        assert run(*probe['argv']).returncode == 1
        record(first['name'], first['backend_ref'])

        # Unsafe permissions are rejected before the next session is recorded.
        sock = Path(first['backend_ref']['socket_path'])
        sock.chmod(0o660)
        rejects(lambda: backend.prepare('sf-test-unsafe', str(root)), '0600')
        assert not (sessions / 'sf-test-unsafe.json').exists()
        sock.chmod(0o600)
        # Restoring the deliberately changed mode also changes ctime. Restore
        # the fixture's receipt to the new socket identity before further work.
        receipt['socket'] = backend.verify_socket(str(sock))
        (backend.state / 'server.json').write_text(json.dumps(receipt))

        # A definite socket error is surfaced by code, without logging params.
        backend.prepare('sf-test-error', str(root))
        fault('fault_workspace_not_found')
        rejects(lambda: backend.start('sf-test-error', str(root), {}, ['/bin/true'],
                LogCapture(str(root / 'error.log'), str(source / 'scripts/session-log-writer'))), 'workspace_not_found')
        fault('fault_workspace_not_found', False)

        # The fake's drop fault discards the request before creating a pane:
        # the backend must fail, and must still never resend layout.apply.
        backend.prepare('sf-test-no-reply', str(root))
        fault('fault_drop_reply')
        rejects(lambda: backend.start('sf-test-no-reply', str(root), {}, ['/bin/true'],
                LogCapture(str(root / 'no-reply.log'), str(source / 'scripts/session-log-writer'))), 'no unique pane')
        fault('fault_drop_reply', False)
        calls = (stub / 'calls.log').read_text().splitlines()
        assert sum('socket layout.apply ' in line and 'sf-test-no-reply' in line for line in calls) == 1

        # Drop a successful reply at the receiving boundary, after fake creates
        # a real pane; unique-label CLI resolution must avoid a second request.
        backend.prepare('sf-test-lost', str(root))
        original_loads = json.loads
        def lose_layout_reply(data, *args, **kwargs):
            value = original_loads(data, *args, **kwargs)
            if isinstance(value, dict) and value.get('result', {}).get('type') == 'layout_apply':
                raise ValueError('lost reply')
            return value
        with patch('session_backend_herdr.json.loads', side_effect=lose_layout_reply):
            ref = backend.start('sf-test-lost', str(root), {'NOGG_SESSION_AGENT': 'claude'},
                                ['/bin/sleep', '120'], LogCapture(str(root / 'lost.log'),
                                str(source / 'scripts/session-log-writer')))
        processes.append(ref['session_pid'])
        lost = record('sf-test-lost', ref)
        calls = (stub / 'calls.log').read_text().splitlines()
        assert sum('socket layout.apply ' in line and 'sf-test-lost' in line for line in calls) == 1, calls
        backend.kill(ref)
        assert backend.live([lost]) == (set(), set())

        # Restart preserves pane label/ID but replaces the process: dead, not
        # adopted. Listing reports it; cleanup closes it and keeps server alive.
        fault('simulate_restart')
        assert backend.live([first]) == (set(), set())
        orphans_found, _ = backend.orphans([first])
        assert orphans_found
        os.environ['NOGGING_ROOT'] = str(root)
        module = importlib.machinery.SourceFileLoader('nogg_herdr_test', str(source / 'scripts/nogg')).load_module()
        module.collect_session_usage = lambda *args, **kw: None
        module.release_planning_lock = lambda **kw: False
        module.tmux_server_sessions = lambda: set()

        # Exercise the real launcher with a contract-compatible inert wrapper.
        # It observes its already-written record and never starts an agent.
        (root / 'scripts').unlink()
        (root / 'scripts').mkdir()
        for helper in ('session-pty-recorder', 'session-log-writer', 'openspec-sandbox'):
            (root / 'scripts' / helper).symlink_to(source / 'scripts' / helper)
        contract = run(str(source / 'scripts/session-launch'), '--contract').stdout
        wrapper = root / 'scripts/session-launch'
        wrapper.write_text('#!' + sys.executable + '\n' +
            'import json, os, pathlib, sys, time\n' +
            'if sys.argv[1:] == ["--contract"]:\n print(' + repr(contract) + '); sys.exit(0)\n' +
            'p=pathlib.Path(os.environ["NOGG_SESSION_ROOT"])/".nogging/state/sessions"\n' +
            'rec=json.loads((p/(os.environ["NOGG_SESSION_NAME"]+".json")).read_text())\n' +
            '(p/"observed.json").write_text(json.dumps({"state":rec["state"],"argv":sys.argv}))\n' +
            'print("launcher-observed-record", flush=True)\ntime.sleep(120)\n')
        wrapper.chmod(0o755)
        for directory in ('launch-profiles', 'launch-prompts'):
            shutil.copytree(source / '.nogging' / directory, root / '.nogging' / directory)
        module.bead_records = lambda bead: [{'id': bead, 'labels': []}]
        module.unmet_dependencies = lambda bead: []
        module.usage_gate_admission = lambda *args, **kwargs: {}
        with contextlib.redirect_stdout(io.StringIO()):
            module.session_launch('lead', 'SPEC-test', str(root), False, None,
                                  agent='claude', full_access=True, backend='herdr')
        observed = sessions / 'observed.json'
        for _ in range(40):
            if observed.exists():
                break
            time.sleep(0.05)
        proof = json.loads(observed.read_text())
        assert proof['state'] in {'starting', 'running'}
        assert '--settings' in proof['argv'] and '--prompt' in proof['argv']
        actual_records = [json.loads(p.read_text()) for p in sessions.glob('sf-lead-*.json')
                          if not p.name.endswith('.settings.json')]
        assert len(actual_records) == 1
        processes.append(actual_records[0]['session_pid'])
        assert actual_records[0]['backend'] == 'herdr'
        assert actual_records[0]['session_pid_start']
        # Unsafe socket refuses this launcher before its record is created.
        count_before = len(list(sessions.glob('sf-lead-*.json')))
        sock.chmod(0o660)
        rejects(lambda: module.session_launch('lead', 'SPEC-unsafe', str(root), False, None,
                    agent='claude', full_access=True, backend='herdr'), '0600')
        sock.chmod(0o600)
        receipt['socket'] = backend.verify_socket(str(sock))
        (backend.state / 'server.json').write_text(json.dumps(receipt))
        assert len(list(sessions.glob('sf-lead-*.json'))) == count_before

        fault('fault_workspace_not_found')
        try:
            module.session_launch('lead', 'SPEC-error', str(root), False, None,
                                  agent='claude', full_access=True, backend='herdr')
        except module.ToolError as exc:
            assert 'workspace_not_found' in str(exc)
        else:
            raise AssertionError('socket error did not fail launch')
        fault('fault_workspace_not_found', False)
        failed = [json.loads(p.read_text()) for p in sessions.glob('sf-lead-spec-error-*.json')
                  if not p.name.endswith('.settings.json')]
        assert len(failed) == 1 and failed[0]['state'] == 'failed'

        # Test session_list AGENT_STATUS column in mixed listing (tmux shows '-', herdr shows status).
        live_herdr_name = actual_records[0]['name']
        tmux_rec_file = sessions / 'sf-tmux-test.json'
        tmux_rec_file.write_text(json.dumps({
            'name': 'sf-tmux-test', 'role': 'lead', 'bead_id': 'SPEC-tmux',
            'started_at': '2026-10-16T00:00:00Z', 'state': 'running',
            'owner': 12345, 'backend': 'tmux', 'backend_ref': {'session': 'sf-tmux-test'},
            'session_pid': 12345, 'working_dir': str(root)
        }))
        # Set agent_status on live herdr pane
        current_state = state()
        for p in current_state['panes'].values():
            if p.get('label') == live_herdr_name:
                p['agent_status'] = 'working'
        save(current_state)

        module.session_backend = lambda name=None: backend if name == 'herdr' else type('Empty', (), {'live': lambda self, records: (set(), set()), 'capabilities': type('Caps', (), {'agent_status': False})()})()
        mixed_out = io.StringIO()
        with contextlib.redirect_stdout(mixed_out):
            module.session_list()
        listing_lines = mixed_out.getvalue().splitlines()
        hdr_line = listing_lines[0]
        assert 'AGENT_STATUS' in hdr_line
        assert any('sf-tmux-test' in l and 'tmux' in l and '-' in l for l in listing_lines)
        assert any(live_herdr_name in l and 'herdr' in l and 'working' in l for l in listing_lines)
        tmux_rec_file.unlink()

        module.session_backend = lambda name=None: backend if name == 'herdr' else type('Empty', (), {'live': lambda self, records: (set(), set())})()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            module.session_list()
            module.session_reap()
            module.session_cleanup(None)
        assert 'orphan herdr pane' in output.getvalue()
        assert json.loads((sessions / 'sf-test-first.json').read_text())['state'] == 'retired'
        assert sock.exists() and backend._running()
        assert not [p for p in state()['panes'].values() if p.get('label') == first['name']]

        # Packaging ships both the backend and recorder.
        manifest = subprocess.check_output(['node', '-e',
            'process.stdout.write(JSON.stringify(require(process.argv[1]).verbatim))',
            str(source / 'bin/lib/manifest.js')], text=True)
        assert {'scripts/lib/session_backend_herdr.py', 'scripts/session-pty-recorder'} <= set(json.loads(manifest))
        print('ok - herdr backend socket, config/env, recorder, identity, lifecycle and packaging')
    finally:
        for pid in processes:
            if process_start(pid):
                try:
                    os.killpg(pid, signal.SIGHUP)
                except ProcessLookupError:
                    pass
        run(str(executable), 'server', 'stop')
        if server_pid:
            for _ in range(30):
                if not process_start(server_pid):
                    break
                time.sleep(0.05)
PY
