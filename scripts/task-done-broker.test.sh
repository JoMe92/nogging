#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import importlib.machinery
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading

source = Path(sys.argv[1])
env = {key: value for key, value in os.environ.items()
       if not key.startswith(('NOGG_', 'HERDR_')) and key != 'TMUX'}
with tempfile.TemporaryDirectory(prefix='nogg.') as temporary:
    base = Path(temporary)
    main = base / 'main'
    main.mkdir()
    (main / '.nogging').mkdir()
    tasks_dir = main / 'openspec/changes/proof'
    tasks_dir.mkdir(parents=True)
    task_file = tasks_dir / 'tasks.md'
    task_file.write_text('- [ ] TASK-PROOF-001 tick a closed task\n')
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

    os.environ.clear()
    os.environ.update(env)
    os.environ['NOGGING_ROOT'] = str(main)
    bridge = importlib.machinery.SourceFileLoader(
        'nogg_task_done_test', str(source / 'scripts/nogg')).load_module()
    broker = importlib.machinery.SourceFileLoader(
        'openspec_sandbox_test', str(source / 'scripts/openspec-sandbox')).load_module()
    repository = bridge.canonical_repository_state(main)

    socket_dir = Path(temporary) / 's'
    socket_dir.mkdir()
    address = socket_dir / 'b'
    assert len(str(address).encode()) < 108, f'Unix socket path too long: {address}'
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(address))
    server.listen(1)
    request_seen = {}
    response_seen = {}

    def serve_one():
        connection, _ = server.accept()
        with connection:
            raw = b''
            while chunk := connection.recv(4096):
                raw += chunk
            request_seen.update(json.loads(raw))
            response_seen.update(broker.handle_task_done_request(bridge, request_seen, repository))
            connection.sendall(json.dumps(response_seen).encode())

    worker = threading.Thread(target=serve_one)
    worker.start()
    client_env = {**env, 'NOGGING_ROOT': str(main), 'NOGG_TASK_DONE_SOCKET': str(address)}
    result = subprocess.run([str(source / 'scripts/nogg'), 'task-done', 'SPEC-proof'],
                            cwd=checkout, env=client_env, text=True,
                            capture_output=True, timeout=15)
    worker.join(timeout=15)
    server.close()
    assert not worker.is_alive(), 'broker handler did not finish'
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert request_seen == {'bead_id': 'SPEC-proof', 'checkout': str(checkout)}
    assert response_seen.get('ok'), response_seen
    assert '- [x] TASK-PROOF-001' in (checkout / 'openspec/changes/proof/tasks.md').read_text()
    assert '- [ ] TASK-PROOF-001' in task_file.read_text(), 'broker ticked launch checkout'

    def refused(request, phrase):
        response = broker.handle_task_done_request(bridge, request, repository)
        assert not response.get('ok') and phrase in response.get('error', ''), response
    refused({'bead_id': 'SPEC-proof'}, 'exactly')
    refused({'bead_id': 'SPEC-proof', 'checkout': str(base / 'unknown')}, 'registered')
    refused({'bead_id': 'SPEC-proof', 'checkout': str(checkout), 'extra': True}, 'exactly')

    other = base / 'other'
    other.mkdir()
    subprocess.run(['git', '-C', str(other), 'init', '-q'], check=True, env=env)
    refused({'bead_id': 'SPEC-proof', 'checkout': str(other)}, 'different repository')

    contract = subprocess.run([str(source / 'scripts/openspec-sandbox'), '--contract'],
                              check=True, capture_output=True, text=True, env=env)
    assert 'checkout-task-broker' in json.loads(contract.stdout)['features']
    print('task-done broker: caller checkout is ticked; malformed, unregistered, and foreign paths are refused')
PY
