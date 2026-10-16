#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
python3 - "$root" <<'PY'
import json
import os
from pathlib import Path
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

    env = {k: v for k, v in os.environ.items() if not k.startswith(('NOGG_', 'NOGGING_'))}
    env['NOGG_SESSION_WORKING_DIR'] = str(linked)

    def run_guard(payload_str):
        result = subprocess.run(['python3', str(guard)], input=payload_str, text=True, capture_output=True, env=env, check=True)
        return json.loads(result.stdout)

    def check_call(name, args, expected_decision, expected_reason_substr=None):
        payload = json.dumps({'toolCall': {'name': name, 'args': args}})
        res = run_guard(payload)
        got_decision = res['decision']
        assert got_decision == expected_decision, (name, args, expected_decision, got_decision, res)
        if expected_reason_substr is not None:
            got_reason = res.get('reason', '')
            assert expected_reason_substr in got_reason, (name, args, expected_reason_substr, got_reason)

    # 1. Authority levels and roles (lead, planning)
    for authority in ('restricted', 'trusted'):
        env['NOGG_SESSION_AUTHORITY'] = authority
        expected_success = 'allow' if authority == 'trusted' else 'force_ask'

        for role in ('lead', 'planning'):
            env['NOGG_SESSION_ROLE'] = role

            # Fixture replayed
            fixture_json = (root / 'scripts/fixtures/antigravity/1.4.0/search_web.json').read_text()
            fixture_payload = json.loads(fixture_json)['payload']
            res = run_guard(json.dumps(fixture_payload))
            assert res['decision'] == expected_success, (authority, role, res)

            # Valid query strings
            check_call('search_web', {'query': 'valid search query'}, expected_success)
            check_call('search_web', {'query': '  leading and trailing whitespace trimmed  '}, expected_success)

            # Denied queries: empty, whitespace, non-string, NUL, missing query
            check_call('search_web', {'query': ''}, 'deny', 'Nogging: invalid search query')
            check_call('search_web', {'query': '   '}, 'deny', 'Nogging: invalid search query')
            check_call('search_web', {'query': 123}, 'deny', 'Nogging: invalid search query')
            check_call('search_web', {'query': None}, 'deny', 'Nogging: invalid search query')
            check_call('search_web', {'query': ['list', 'query']}, 'deny', 'Nogging: invalid search query')
            check_call('search_web', {'query': 'query with \x00 null'}, 'deny', 'Nogging: invalid search query')
            check_call('search_web', {}, 'deny', 'Nogging: invalid search query')

            # Wrong case: Query instead of query
            check_call('search_web', {'Query': 'capitalized'}, 'deny', 'Nogging: invalid search query')

            # Unknown tool contracts naming the tool
            check_call('custom_tool_name', {'some': 'arg'}, 'deny', 'Nogging: unsupported tool contract: custom_tool_name')
            check_call('tool.with-dots_and_dashes', {}, 'deny', 'Nogging: unsupported tool contract: tool.with-dots_and_dashes')

            # Hostile or invalid tool names sanitized to <invalid>
            check_call('tool with spaces', {}, 'deny', 'Nogging: unsupported tool contract: <invalid>')
            check_call('tool/with/slashes', {}, 'deny', 'Nogging: unsupported tool contract: <invalid>')
            check_call('tool;reboot', {}, 'deny', 'Nogging: unsupported tool contract: <invalid>')
            check_call('tool"quote', {}, 'deny', 'Nogging: unsupported tool contract: <invalid>')
            check_call('a' * 65, {}, 'deny', 'Nogging: unsupported tool contract: <invalid>')

            # Floor command: reason names command floor and NEVER repeats or contains the command
            floor_cmd = 'sudo reboot'
            floor_payload = json.dumps({'toolCall': {'name': 'run_command', 'args': {'CommandLine': floor_cmd, 'Cwd': str(linked)}}})
            res_floor = run_guard(floor_payload)
            assert res_floor['decision'] == 'deny'
            assert res_floor['reason'] == 'Nogging: Nogging command floor'
            assert 'sudo' not in res_floor['reason']
            assert 'reboot' not in res_floor['reason']

            # Malformed JSON payload
            for malformed in ('{', 'null', '[]', 'not json at all', '{"toolCall": "not a dict"}'):
                res_malformed = run_guard(malformed)
                assert res_malformed['decision'] == 'deny'
                assert res_malformed['reason'] == 'Nogging: malformed tool payload'

print('all agy guard search_web and named denial checks passed')
PY
