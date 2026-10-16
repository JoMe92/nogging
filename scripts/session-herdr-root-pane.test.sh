#!/usr/bin/env bash
# TASK-HHB-007 (Decision 8): Root pane closure, retry on missing workspace,
# preserved operator pane, and doctor legacy root pane detection.
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

source = Path(sys.argv[1])
sys.dont_write_bytecode = True
for key in list(os.environ):
    if key.startswith(('NOGG_', 'HERDR_')) or key in {'TMUX', 'NOGGING_ROOT'}:
        os.environ.pop(key)
sys.path.insert(0, str(source / 'scripts/lib'))
from session_backend import BackendError
from session_backend_herdr import HerdrBackend


class LogCapture:
    def __init__(self, path, writer):
        self.path = path
        self.writer = writer
        self.max_bytes = 1048576
        self.rotation_depth = 3


with tempfile.TemporaryDirectory(prefix='nogg.', dir='/tmp') as directory:
    tmp = Path(directory)
    stub = tmp / 'stub'
    stub.mkdir()
    sock = str(tmp / 'herdr.sock')
    assert len(os.fsencode(sock)) < 108
    (stub / 'socket_path').write_text(sock)
    (stub / 'real_process').touch()
    executable = tmp / 'herdr'
    executable.write_text('#!/bin/sh\nexport HERDR_STUB_DIR=' + shlex.quote(str(stub)) +
                          '\nexec ' + shlex.quote(str(source / 'scripts/fixtures/herdr/bin/herdr')) + ' "$@"\n')
    executable.chmod(0o755)

    repo = tmp / 'repo'
    repo.mkdir()
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    subprocess.run(['git', '-C', str(repo), '-c', 'user.name=test', '-c', 'user.email=test@example.com',
                    'commit', '--allow-empty', '-m', 'init'], check=True)

    (repo / 'scripts').symlink_to(source / 'scripts', target_is_directory=True)
    (repo / '.nogging').mkdir(exist_ok=True)
    config = {'session_backend': 'herdr', 'session_herdr_command': str(executable),
              'session_herdr_session': 'nogging', 'usage_gate': {'enabled': False},
              'session_repository_root': str(repo), 'session_repository_slug': 'repo',
              'beads_command': 'bd', 'session_state_dir': '.nogging/state/sessions'}
    (repo / '.nogging/config.json').write_text(json.dumps(config))
    (repo / '.nogging/state/sessions').mkdir(parents=True, exist_ok=True)

    stub_bin = tmp / 'bin'
    stub_bin.mkdir()
    (stub_bin / 'bd').write_text('#!/bin/sh\necho "[]"\nexit 0\n')
    (stub_bin / 'bd').chmod(0o755)
    (stub_bin / 'dolt').write_text('#!/bin/sh\nexit 0\n')
    (stub_bin / 'dolt').chmod(0o755)

    # Stop any pre-existing server in the stub before starting ours
    subprocess.run([str(executable), '--session', 'nogging', 'server', 'stop'],
                   env=dict(os.environ, HERDR_STUB_DIR=str(stub)), check=True)

    # Start herdr server
    env_base = dict(os.environ, HERDR_STUB_DIR=str(stub), NOGGING_ROOT=str(repo),
                    PATH=str(stub_bin) + ':' + os.environ.get('PATH', ''))
    res = subprocess.run([str(source / 'scripts/nogg'), 'session', 'herdr-server', 'start'],
                         env=env_base, text=True, capture_output=True)
    assert res.returncode == 0, res.stderr

    backend = HerdrBackend(config, lambda *args, check=False, **kw: subprocess.run(
        args, text=True, capture_output=True, env=env_base, **kw))

    try:
        # Case 1: Root pane is closed after first layout.apply
        ref1 = backend.prepare('sf-test-1', str(repo))
        state_file = stub / 'state.json'
        st = json.loads(state_file.read_text())
        # Workspace should have been created with a root pane
        ws_id = ref1['workspace']
        assert ws_id in st['workspaces']
        initial_panes = [p for p in st['panes'].values() if p.get('workspace_id') == ws_id]
        assert len(initial_panes) == 1
        root_pane_id = initial_panes[0]['pane_id']
        assert not initial_panes[0].get('label')

        # Workspace tracking file should exist before start completes
        ws_track = backend.state / 'workspace.json'
        assert ws_track.exists()
        track_data = json.loads(ws_track.read_text())
        assert track_data['pane_id'] == root_pane_id

        # Now start session 1
        started1 = backend.start('sf-test-1', str(repo), {}, ['/bin/sleep', '120'],
                                 LogCapture(str(repo / 'test1.log'), str(source / 'scripts/session-log-writer')))
        assert started1['pane_id'] != root_pane_id

        # Verify that root pane was closed and workspace.json was removed
        st_after = json.loads(state_file.read_text())
        assert root_pane_id not in st_after['panes']
        assert not ws_track.exists()
        # Session 1's pane must still be alive and present
        assert started1['pane_id'] in st_after['panes']
        backend.kill(started1)

        # Case 2: Workspace recreation and retry on workspace_not_found error reply
        ref2 = backend.prepare('sf-test-2', str(repo))
        # Simulate workspace deletion out-of-band in herdr
        st = json.loads(state_file.read_text())
        del st['workspaces'][ref2['workspace']]
        state_file.write_text(json.dumps(st))

        # Starting session 2 encounters workspace_not_found, recreates workspace and succeeds
        started2 = backend.start('sf-test-2', str(repo), {}, ['/bin/sleep', '120'],
                                 LogCapture(str(repo / 'test2.log'), str(source / 'scripts/session-log-writer')))
        assert started2['pane_id']
        st_after2 = json.loads(state_file.read_text())
        # New workspace should be present
        assert started2['workspace'] in st_after2['workspaces']
        # The recreated root pane should also have been closed
        ws_panes = [p for p in st_after2['panes'].values() if p.get('workspace_id') == started2['workspace']]
        assert len(ws_panes) == 1
        assert ws_panes[0]['pane_id'] == started2['pane_id']
        backend.kill(started2)

        # Case 3: Unlabelled pane not matching workspace.json (e.g. operator pane) is NOT closed
        ref3 = backend.prepare('sf-test-3', str(repo))
        # Clear workspace.json to simulate an already established workspace
        ws_track.unlink(missing_ok=True)
        # Add an unlabelled operator pane manually to the workspace
        st = json.loads(state_file.read_text())
        op_pane_id = f"{ref3['workspace']}:p_operator"
        st['panes'][op_pane_id] = {
            'pane_id': op_pane_id,
            'workspace_id': ref3['workspace'],
            'terminal_id': 'term_operator',
            'cwd': str(repo)
        }
        state_file.write_text(json.dumps(st))

        started3 = backend.start('sf-test-3', str(repo), {}, ['/bin/sleep', '120'],
                                 LogCapture(str(repo / 'test3.log'), str(source / 'scripts/session-log-writer')))
        st_after3 = json.loads(state_file.read_text())
        assert op_pane_id in st_after3['panes'], "untracked unlabelled operator pane was unexpectedly closed!"
        backend.kill(started3)

        # Case 4: Doctor reports legacy root panes as NOTE
        doc_res = subprocess.run([str(source / 'scripts/nogg'), 'doctor'],
                                 env=env_base, text=True, capture_output=True)
        assert doc_res.returncode == 0, doc_res.stderr
        expected_note = f"NOTE  legacy root pane {op_pane_id} found in herdr workspace; not closed automatically"
        assert expected_note in doc_res.stdout, f"doctor did not report legacy root pane! stdout:\n{doc_res.stdout}"

        print('ok - root pane closed on first apply, workspace recreated on workspace_not_found, operator pane preserved, doctor notes legacy root pane')
    finally:
        subprocess.run([str(executable), '--session', 'nogging', 'server', 'stop'],
                       env=dict(os.environ, HERDR_STUB_DIR=str(stub)), check=True)
PY
