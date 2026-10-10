#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
import datetime as dt
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
guard = root / 'scripts/hooks/agy-guard'
with tempfile.TemporaryDirectory() as tmp:
    main = Path(tmp) / 'main'
    linked = Path(tmp) / 'linked'
    subprocess.run(['git', 'init', '-q', str(main)], check=True)
    subprocess.run(['git', '-C', str(main), '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'fixture'], check=True)
    subprocess.run(['git', '-C', str(main), 'worktree', 'add', '-qb', 'linked', str(linked)], check=True)
    locks = main / '.nogging/locks'
    locks.mkdir(parents=True)
    (main / '.nogging/config.json').write_text('{}')
    (linked / 'openspec').mkdir()
    (linked / 'alias').symlink_to(main / 'openspec', target_is_directory=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('NOGG_', 'NOGGING_'))}
    env['NOGG_SESSION_WORKING_DIR'] = str(linked)
    def run(name, args, expected, raw=None):
        payload = raw if raw is not None else json.dumps({'toolCall': {'name':name, 'args':args}})
        result = subprocess.run(['python3', str(guard)], input=payload, text=True, capture_output=True, env=env, check=True)
        got = json.loads(result.stdout)['decision']
        assert got == expected, (name, args, expected, got, result.stderr)
    floor = ['sudo true', 'rm -rf x', 'rm -fr x', 'rm --recursive --force x', 'rm -r -f x', 'dd if=x of=y', 'mkfs.ext4 x', 'mkfs x', 'shutdown now', 'reboot', 'systemctl status x', 'chown x y', 'curl https://example.com', 'wget https://example.com', 'git push --force', 'git push --force-with-lease', 'git push -f', 'git reset --hard', 'git clean -xfd', 'git filter-branch x']
    for authority in ('restricted', 'trusted'):
        env['NOGG_SESSION_AUTHORITY'] = authority
        env['NOGG_SESSION_ROLE'] = 'lead'
        yes = 'allow' if authority == 'trusted' else 'force_ask'
        shell = lambda c,e: run('run_command', {'CommandLine':c, 'Cwd':str(linked)}, e)
        for command in floor:
            shell(command, 'deny')
        for command in ('cat openspec/tasks.md', 'sed -n "1,2p" openspec/tasks.md', 'git status', 'printf hello > output.txt'):
            shell(command, yes)
        for command in ('echo x > openspec/tasks.md', 'sed -i s/x/y/ openspec/tasks.md', 'cp x ../main/openspec/a', 'touch alias/new', 'cat openspec/tasks.md > openspec/copy', 'python3 -c "open(\'openspec/a\',\'w\').write(\'x\')"'):
            shell(command, 'deny')
        run('write_to_file', {'TargetFile':str(linked / 'normal')}, yes)
        run('replace_file_content', {'TargetFile':str(main / 'openspec/a')}, 'deny')
        run('multi_replace_file_content', {}, 'deny')
        run('unknown_tool', {}, 'deny')
        run('read_url_content', {'Url':'https://example.com'}, yes)
        run('read_url_content', {'Url':'file:///etc/passwd'}, 'deny')
        for raw in ('{', 'null', '[]', '{}', '{"toolCall":{"name":"run_command","args":[]}}'):
            run('', {}, 'deny', raw)
    # Replay the real sanitized 1.3.2 payload shape, substituting only paths.
    for fixture in ('pre-tool-use', 'replace_file_content', 'run_command', 'read_url_content'):
        payload = json.loads((root / 'scripts/fixtures/antigravity/1.3.2' / (fixture + '.json')).read_text())['payload']
        args = payload['toolCall']['args']
        if 'TargetFile' in args:
            args['TargetFile'] = str(linked / 'fixture.txt')
        if 'Cwd' in args:
            args['Cwd'] = str(linked)
        run('', {}, 'allow', json.dumps(payload))
    env['NOGG_SESSION_AUTHORITY'] = 'trusted'
    target = {'TargetFile':str(linked / 'openspec/new')}
    env['NOGG_SESSION_ROLE'] = 'planning'
    run('write_to_file', target, 'deny')  # missing canonical lock
    lock = {'pid':os.getpid(), 'host':socket.gethostname(), 'created_at':dt.datetime.now(dt.timezone.utc).isoformat()}
    lockpath = locks / 'planning.lock'
    lockpath.write_text(json.dumps(lock))
    run('write_to_file', target, 'allow')
    env['NOGG_SESSION_ROLE'] = 'lead'
    run('write_to_file', target, 'deny')  # another planner cannot authorize execution
    env['NOGG_SESSION_ROLE'] = 'planning'
    sentinel = locks / 'openspec.readonly'
    sentinel.symlink_to(locks / 'missing')
    run('write_to_file', target, 'deny')
    sentinel.unlink()
    for contents in ('{', '{}', json.dumps(dict(lock, pid='bad')), json.dumps(dict(lock, created_at=(dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=1)).isoformat())), json.dumps(dict(lock, created_at=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=1)).isoformat()))):
        lockpath.write_text(contents)
        run('write_to_file', target, 'deny')
    lockpath.write_text(json.dumps(lock))
    local = linked / '.nogging/locks/openspec.readonly'
    local.parent.mkdir(parents=True)
    local.symlink_to(local.parent / 'missing')
    run('write_to_file', target, 'deny')
    local.unlink()
    for bad in ('{', '{"planning_lock_ttl_seconds":false}', '{"planning_lock_ttl_seconds":-1}'):
        (main / '.nogging/config.json').write_text(bad)
        run('write_to_file', target, 'deny')
    (main / '.nogging/config.json').write_text('{}')
    lockpath.write_text(json.dumps(dict(lock, session_name='foreign')))
    run('write_to_file', target, 'deny')
    env['NOGG_SESSION_WORKING_DIR'] = tmp
    run('view_file', {}, 'deny')  # unresolved repository
    hooks = json.loads((root / 'templates/antigravity/hooks.json').read_text())
    assert hooks['nogging-guard']['PreToolUse'][0]['matcher'] == '*'
print('all agy guard checks passed (both authority levels, canonical linked-worktree boundary)')
PY
