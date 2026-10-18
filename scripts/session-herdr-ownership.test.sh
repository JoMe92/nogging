#!/usr/bin/env bash
# TASK-HHB-006: orphan panes are limited to current checkout records.
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

with tempfile.TemporaryDirectory(prefix='nogg.', dir='/tmp') as directory:
    tmp = Path(directory)
    stub = tmp / 'stub'
    stub.mkdir()
    sock = str(tmp / 'herdr.sock')
    assert len(os.fsencode(sock)) < 108
    (stub / 'socket_path').write_text(sock)
    executable = tmp / 'herdr'
    executable.write_text('#!/bin/sh\nexport HERDR_STUB_DIR=' + shlex.quote(str(stub)) +
                          '\nexec ' + shlex.quote(str(source / 'scripts/fixtures/herdr/bin/herdr')) + ' "$@"\n')
    executable.chmod(0o755)

    # Main repo (checkout A) and linked worktree (checkout B)
    main = tmp / 'repo'
    main.mkdir()
    subprocess.run(['git', 'init', '-q', str(main)], check=True)
    subprocess.run(['git', '-C', str(main), '-c', 'user.name=test', '-c', 'user.email=test@example.com',
                    'commit', '--allow-empty', '-m', 'init'], check=True)
    wt = tmp / 'worktree'
    subprocess.run(['git', '-C', str(main), 'worktree', 'add', '-q', str(wt)], check=True)

    slug = 'repo'  # slugify of main.name
    checkout_a = main
    checkout_b = wt

    for ck in (checkout_a, checkout_b):
        (ck / 'scripts').symlink_to(source / 'scripts', target_is_directory=True)
        (ck / '.nogging').mkdir(exist_ok=True)
        config = {'session_backend': 'herdr', 'session_herdr_command': str(executable),
                  'session_herdr_session': 'nogging', 'usage_gate': {'enabled': False}}
        (ck / '.nogging/config.json').write_text(json.dumps(config))
        (ck / '.nogging/state/sessions').mkdir(parents=True, exist_ok=True)

    # Stop any pre-existing server in the stub before starting ours
    subprocess.run([str(executable), '--session', 'nogging', 'server', 'stop'],
                   env=dict(os.environ, HERDR_STUB_DIR=str(stub)), check=True)

    # Start herdr server from checkout A
    env_a = dict(os.environ, HERDR_STUB_DIR=str(stub), NOGGING_ROOT=str(checkout_a))
    res = subprocess.run([str(source / 'scripts/nogg'), 'session', 'herdr-server', 'start'],
                         env=env_a, text=True, capture_output=True)
    assert res.returncode == 0, res.stderr

    # We need a live process for checkout B's live session
    child = subprocess.Popen(['/bin/sleep', '120'])
    live_pid = child.pid

    # Dead PID for failed/restored panes: reap a child
    dead_child = subprocess.Popen(['/bin/true'])
    dead_pid = dead_child.pid
    dead_child.wait()

    try:
        # Create shared workspace with label matching slug
        state_file = stub / 'state.json'
        st = json.loads(state_file.read_text())
        workspace_id = 'w_shared'
        st['workspaces'][workspace_id] = {
            'workspace_id': workspace_id,
            'label': slug,
            'session': 'nogging'
        }

        # Setup panes in the shared workspace:
        # 1. pane_b_live: label 'sf-checkout-b-live', owned by checkout B (alive process)
        # 2. pane_a_restored: label 'sf-checkout-a-restored', owned by checkout A's failed record
        # 3. pane_foreign_orphan: label 'sf-foreign-no-record', no record anywhere
        st['panes']['p_b_live'] = {
            'pane_id': 'p_b_live',
            'workspace_id': workspace_id,
            'label': 'sf-checkout-b-live',
            'terminal_id': 'term_b_live',
            'shell_pid': live_pid
        }
        st['panes']['p_a_restored'] = {
            'pane_id': 'p_a_restored',
            'workspace_id': workspace_id,
            'label': 'sf-checkout-a-restored',
            'terminal_id': 'term_a_restored',
            'shell_pid': dead_pid
        }
        st['panes']['p_foreign'] = {
            'pane_id': 'p_foreign',
            'workspace_id': workspace_id,
            'label': 'sf-foreign-no-record',
            'terminal_id': 'term_foreign',
            'shell_pid': dead_pid
        }
        state_file.write_text(json.dumps(st))

        # Write session records:
        # In checkout B: record for 'sf-checkout-b-live' (state: running)
        rec_b = {
            'name': 'sf-checkout-b-live',
            'bead_id': 'SPEC-b',
            'role': 'lead',
            'state': 'running',
            'started_at': '2026-10-16T00:00:00Z',
            'backend': 'herdr',
            'backend_ref': {
                'label': 'sf-checkout-b-live',
                'pane_id': 'p_b_live',
                'terminal_id': 'term_b_live',
                'herdr_session': 'nogging',
                'session_pid': live_pid,
                'session_pid_ns': 'pid:[fake_ns]'
            },
            'session_pid': live_pid,
            'session_pid_ns': 'pid:[fake_ns]',
            'working_dir': str(checkout_b)
        }
        (checkout_b / '.nogging/state/sessions/sf-checkout-b-live.json').write_text(json.dumps(rec_b))

        # In checkout A: record for 'sf-checkout-a-restored' (state: failed)
        rec_a = {
            'name': 'sf-checkout-a-restored',
            'bead_id': 'SPEC-a',
            'role': 'lead',
            'state': 'retired',
            'started_at': '2026-10-16T00:00:00Z',
            'backend': 'herdr',
            'backend_ref': {
                'label': 'sf-checkout-a-restored',
                'pane_id': 'p_a_restored',
                'terminal_id': 'term_a_orig',
                'herdr_session': 'nogging',
                'session_pid': dead_pid,
                'session_pid_ns': 'pid:[fake_ns]'
            },
            'session_pid': dead_pid,
            'session_pid_ns': 'pid:[fake_ns]',
            'working_dir': str(checkout_a)
        }
        (checkout_a / '.nogging/state/sessions/sf-checkout-a-restored.json').write_text(json.dumps(rec_a))

        # 1. Test session list in checkout A:
        # Should report orphan sf-checkout-a-restored, and count 2 foreign panes (p_b_live, p_foreign)
        env_a = dict(os.environ, HERDR_STUB_DIR=str(stub), NOGGING_ROOT=str(checkout_a))
        listed_a = subprocess.run([str(source / 'scripts/nogg'), 'session', 'list'],
                                  env=env_a, text=True, capture_output=True)
        assert listed_a.returncode == 0, listed_a.stderr
        assert 'orphan herdr pane p_a_restored labelled sf-checkout-a-restored' in listed_a.stdout
        assert 'NOTE: 2 foreign herdr pane(s) left untouched' in listed_a.stdout

        # 2. Test session cleanup in checkout A:
        # Cleanup in checkout A should close p_a_restored, but NEVER close p_b_live or p_foreign.
        cleanup_a = subprocess.run([str(source / 'scripts/nogg'), 'session', 'cleanup'],
                                   env=env_a, text=True, capture_output=True)
        assert cleanup_a.returncode == 0, cleanup_a.stderr
        assert 'closed orphan herdr pane p_a_restored labelled sf-checkout-a-restored' in cleanup_a.stdout
        assert 'p_b_live' not in cleanup_a.stdout

        st_after = json.loads(state_file.read_text())
        assert 'p_a_restored' not in st_after['panes']
        assert 'p_b_live' in st_after['panes'], "checkout B's live pane was closed by checkout A cleanup!"
        assert 'p_foreign' in st_after['panes'], "pane with no record anywhere was closed!"

        # 3. Test session list in checkout B:
        # B owns p_b_live (alive), so it is not an orphan.
        # p_foreign has no record in B, so 1 foreign pane left untouched.
        env_b = dict(os.environ, HERDR_STUB_DIR=str(stub), NOGGING_ROOT=str(checkout_b))
        listed_b = subprocess.run([str(source / 'scripts/nogg'), 'session', 'list'],
                                  env=env_b, text=True, capture_output=True)
        assert listed_b.returncode == 0, listed_b.stderr
        assert 'orphan herdr pane' not in listed_b.stdout
        assert 'NOTE: 1 foreign herdr pane(s) left untouched' in listed_b.stdout

        print('ok - checkout-scoped herdr orphan detection, foreign pane protection and listing notes')
    finally:
        child.terminate()
        try:
            child.wait(timeout=5)
        except Exception:
            child.kill()
        subprocess.run([str(executable), '--session', 'nogging', 'server', 'stop'],
                       env=dict(os.environ, HERDR_STUB_DIR=str(stub)), check=True)
PY
