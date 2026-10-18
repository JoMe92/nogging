#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading

source = Path(sys.argv[1])
# Remove inherited NOGG_* and HERDR_* variables and TMUX / TMUX_TMPDIR
env = {key: value for key, value in os.environ.items()
       if not key.startswith(('NOGG_', 'HERDR_')) and key not in ('TMUX', 'TMUX_TMPDIR')}

with tempfile.TemporaryDirectory(dir='/tmp', prefix='nogg.') as temporary:
    base = Path(temporary)
    main = base / 'main'
    main.mkdir()
    (main / '.nogging').mkdir()
    tasks_dir = main / 'openspec/changes/proof'
    tasks_dir.mkdir(parents=True)
    task_file = tasks_dir / 'tasks.md'
    task_file.write_text('- [ ] TASK-PROOF-001 tick a closed task\n')

    # Stub bd through PATH / config
    bd = main / 'bd-stub'
    bd.write_text('''#!/usr/bin/env python3
import json, sys
print(json.dumps([{"id": sys.argv[2], "status": "closed",
  "labels": ["openspec:change:proof", "openspec:task:TASK-PROOF-001"]}]))
''')
    bd.chmod(0o755)
    (main / '.nogging/config.json').write_text(json.dumps({'beads_command': str(bd)}))

    def git(*args):
        return subprocess.run(['git', '-C', str(main), *args], check=True,
                              capture_output=True, text=True, env=env)
    git('init', '-q')
    git('add', '.')
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '-qm', 'seed')
    checkout = base / 'execution'
    git('worktree', 'add', '-q', '-b', 'execution', str(checkout))

    # Short socket path under /tmp/nogg.XXXXXX
    socket_dir = base / 's'
    socket_dir.mkdir()
    address = socket_dir / 'b'
    assert len(str(address).encode()) < 108, f'Unix socket path too long: {address}'

    # Test helper to run a broker responder and invoke task-done
    def run_case(response_fn):
        requests_received = []
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(address))
        server.listen(5)
        stop_event = threading.Event()

        def serve():
            server.settimeout(1.0)
            while not stop_event.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                with conn:
                    conn.settimeout(5.0)
                    raw = b''
                    while chunk := conn.recv(4096):
                        raw += chunk
                    if raw:
                        req = json.loads(raw)
                        requests_received.append(req)
                        resp = response_fn(req, len(requests_received))
                        conn.sendall(json.dumps(resp).encode())

        t = threading.Thread(target=serve)
        t.start()
        try:
            client_env = {**env, 'NOGGING_ROOT': str(main), 'NOGG_TASK_DONE_SOCKET': str(address)}
            res = subprocess.run([str(source / 'scripts/nogg'), 'task-done', 'SPEC-proof'],
                                 cwd=checkout, env=client_env, text=True,
                                 capture_output=True, timeout=15)
        finally:
            stop_event.set()
            server.close()
            t.join(timeout=5)
            if address.exists():
                address.unlink()
        return res, requests_received

    # Case 1: Old pre-update broker refusal ('only one closed Bead identifier')
    # Expected: one request carrying both bead_id and checkout, relaunch error message,
    # non-zero exit, no second request sent, tasks.md untouched.
    def old_broker_resp(req, count):
        return {'ok': False, 'error': 'broker accepts only one closed Bead identifier'}

    res1, reqs1 = run_case(old_broker_resp)
    assert res1.returncode != 0, f"Expected non-zero exit, got {res1.returncode}"
    expected_msg = "task-done: this session's sandbox broker predates checkout-aware ticks; relaunch the session and run task-done again; nothing was ticked"
    assert expected_msg in res1.stderr or expected_msg in res1.stdout, (res1.stdout, res1.stderr)
    assert len(reqs1) == 1, f"Expected exactly 1 request, got {len(reqs1)}: {reqs1}"
    assert reqs1[0] == {'bead_id': 'SPEC-proof', 'checkout': str(checkout)}
    assert '- [ ] TASK-PROOF-001' in (checkout / 'openspec/changes/proof/tasks.md').read_text(), "tasks.md in checkout was modified"
    assert '- [ ] TASK-PROOF-001' in task_file.read_text(), "tasks.md in main was modified"

    # Case 2: Current broker (success)
    # Expected: one request carrying both keys, success output printed, returncode 0.
    def current_broker_resp(req, count):
        return {'ok': True, 'output': 'task-done: ticked TASK-PROOF-001 in openspec/changes/proof/tasks.md\n'}

    res2, reqs2 = run_case(current_broker_resp)
    assert res2.returncode == 0, (res2.stdout, res2.stderr)
    assert 'task-done: ticked TASK-PROOF-001' in res2.stdout, res2.stdout
    assert len(reqs2) == 1, f"Expected exactly 1 request, got {len(reqs2)}: {reqs2}"
    assert reqs2[0] == {'bead_id': 'SPEC-proof', 'checkout': str(checkout)}

    # Case 3: Any other refusal (e.g. unknown checkout or bead not closed)
    # Expected: non-zero exit, error message printed, no second request sent.
    def other_broker_resp(req, count):
        return {'ok': False, 'error': 'checkout belongs to a different repository'}

    res3, reqs3 = run_case(other_broker_resp)
    assert res3.returncode != 0, f"Expected non-zero exit, got {res3.returncode}"
    assert 'checkout belongs to a different repository' in res3.stderr or 'checkout belongs to a different repository' in res3.stdout, (res3.stdout, res3.stderr)
    assert len(reqs3) == 1, f"Expected exactly 1 request, got {len(reqs3)}: {reqs3}"
    assert reqs3[0] == {'bead_id': 'SPEC-proof', 'checkout': str(checkout)}

    print('task-done-mixed-broker: all cases passed (old refusal relaunch instruction, current broker success, other refusal no retry)')
PY
