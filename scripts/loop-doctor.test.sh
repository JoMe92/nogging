#!/usr/bin/env bash
# TASK-SCL-006: doctor's scheduled-loop health, with a systemctl stub (design
# Decision 9). Advisory only: none of these lines is a FAIL.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch
import json, os, shutil, subprocess, sys, tempfile

source = Path(sys.argv[1]).resolve()
for key in [key for key in os.environ if key.startswith('NOGG_') or key == 'NOGGING_ROOT']:
    del os.environ[key]
UTC = timezone.utc

with tempfile.TemporaryDirectory(prefix='nogg loop doctor ') as td:
    scratch = Path(td)
    root = scratch / 'my-project'
    (root / '.nogging').mkdir(parents=True)
    (root / 'scripts').mkdir()
    shutil.copy2(source / 'scripts/nogg', root / 'scripts/nogg')
    shutil.copytree(source / 'scripts/lib', root / 'scripts/lib')
    subprocess.run(['bash', str(source / 'scripts/lib/test-fixture-config.sh'),
                    str(source / '.nogging/config.json'), str(root / '.nogging/config.json')], check=True)
    config = json.loads((root / '.nogging/config.json').read_text())
    config['loops_file'] = '.nogging/loops.json'
    (root / '.nogging/config.json').write_text(json.dumps(config, indent=2))
    (root / '.gitignore').write_text('.nogging/state/\n.nogging/locks/\n')
    subprocess.run(['git', 'init', '-q', '-b', 'develop', str(root)], check=True)
    subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-qm', 'seed'], check=True)

    tools = scratch / 'tools'
    tools.mkdir()
    answer, calls = scratch / 'answer', scratch / 'calls'
    systemctl = tools / 'systemctl'
    systemctl.write_text(f'''#!/bin/sh
printf '%s\\n' "$*" >> "{calls}"
state=$(cat "{answer}")
echo "$state"
[ "$state" = enabled ]
''')
    systemctl.chmod(0o755)
    base_path = os.environ['PATH']
    no_systemctl = os.pathsep.join(entry for entry in base_path.split(os.pathsep)
                                   if not (Path(entry) / 'systemctl').exists())
    os.environ['NOGGING_ROOT'] = str(root)
    os.chdir(root)
    m = SourceFileLoader('nogg_doctor_test', str(source / 'scripts/nogg')).load_module()
    sys.path.insert(0, str(source / 'scripts/lib'))
    import loop_config, loop_state

    defs = root / '.nogging/loops.json'
    now = datetime(2026, 6, 1, 12, 0, tzinfo=UTC)

    def iso(value):
        return value.isoformat().replace('+00:00', 'Z')

    def define(loops, approve=True):
        defs.write_text(json.dumps({'schema_version': 1, 'timezone': 'UTC', 'loops': loops}))
        loaded = loop_config.load(defs)
        for name in loops:
            prompt = root / f'.nogging/loops/{name}.md'
            prompt.parent.mkdir(parents=True, exist_ok=True)
            prompt.write_text('Report the queue.\n')
            if approve:
                loop_state.approve(root, defs, loaded, name, at=iso(now), user='operator')
            else:
                loop_state.remove_approval(root, name)

    def state(value):
        loop_state.write_state(root, {'schema_version': 1, 'loops': {}, **value})

    def health(timer, path=None):
        answer.write_text(timer)
        with patch.dict(os.environ, {'PATH': path or f'{tools}{os.pathsep}{base_path}'}):
            return m.loop_health_diagnostics(now=now)

    send = {'schedule': {'every': '30m', 'start': '00:00'}, 'run': {'mode': 'send', 'target': 'orchestrator'}}
    launch = {'schedule': {'every': '30m', 'start': '00:00'},
              'run': {'mode': 'launch', 'agent': 'claude', 'tier': 'routine', 'max_runtime': '10m'}}

    # No definitions and no timer: nothing to say.
    assert health('not-found') == ([], [])

    # --- the scheduler timer ----------------------------------------------
    define({'night-work': send})
    state({'last_tick': iso(now - timedelta(minutes=10))})
    warnings, notes = health('enabled')
    assert any('nogg-loops-my-project.timer' in w and '10m' in w for w in warnings), warnings
    assert notes == [], notes
    assert '--user is-enabled nogg-loops-my-project.timer' in calls.read_text()

    state({'last_tick': iso(now - timedelta(minutes=4))})
    assert health('enabled') == ([], [])

    state({'last_tick': iso(now - timedelta(minutes=6))})
    assert len(health('enabled')[0]) == 1

    state({})
    assert any('no tick' in w for w in health('enabled')[0])

    for timer in ('disabled', 'not-found', 'masked'):
        warnings, notes = health(timer)
        assert warnings == [], warnings
        assert len(notes) == 1 and 'will not run' in notes[0] and 'nogg loop tick' in notes[0], notes
        assert 'nogg-loops-my-project.timer' in notes[0]

    # An install made with --no-systemd on a host without systemd at all.
    warnings, notes = health('unused', no_systemctl)
    assert warnings == [] and 'will not run' in notes[0], (warnings, notes)

    # --- what makes the note disappear ------------------------------------
    define({'night-work': {**send, 'enabled': False}})
    assert health('disabled') == ([], [])
    define({'night-work': {**send, 'host': 'another-host'}})
    assert health('disabled') == ([], [])

    # --- per-loop warnings ------------------------------------------------
    define({'night-work': send}, approve=False)
    state({'last_tick': iso(now)})
    warnings, _ = health('enabled')
    assert len(warnings) == 1 and 'night-work' in warnings[0] and 'unapproved' in warnings[0], warnings

    define({'night-work': send})
    state({'last_tick': iso(now), 'loops': {'night-work': {'suspended': True, 'paused': True}}})
    warnings, _ = health('enabled')
    assert len(warnings) == 1 and 'suspended' in warnings[0] and 'nogg loop resume' in warnings[0], warnings

    define({'scan': launch})
    active = {'run_id': 'scan-1', 'mode': 'launch', 'event': 'started', 'session': 'sf-loop-scan-x',
              'slot': iso(now - timedelta(minutes=30)), 'trigger': 'scheduled'}
    state({'last_tick': iso(now), 'loops': {'scan': {'active_run': {
        **active, 'started_at': iso(now - timedelta(minutes=30))}}}})
    warnings, _ = health('enabled')
    assert len(warnings) == 1 and 'scan-1' in warnings[0] and 'max_runtime' in warnings[0], warnings

    state({'last_tick': iso(now), 'loops': {'scan': {'active_run': {
        **active, 'started_at': iso(now - timedelta(minutes=5))}}}})
    assert health('enabled') == ([], [])

    # A disabled loop's unapproved definition is not a problem to report.
    define({'night-work': {**send, 'enabled': False}}, approve=False)
    state({'last_tick': iso(now)})
    assert health('enabled') == ([], [])

    # --- unreadable state is reported, not raised -------------------------
    define({'night-work': send})
    loop_state.state_path(root).write_text('{broken')
    warnings, _ = health('enabled')
    assert any('loop health' in w for w in warnings), warnings

    # --- through doctor: advisory lines, never a FAIL ---------------------
    define({'night-work': send}, approve=False)
    state({'last_tick': iso(datetime.now(UTC) - timedelta(days=2))})
    answer.write_text('enabled')
    result = subprocess.run([str(root / 'scripts/nogg'), 'doctor'], cwd=root, text=True, capture_output=True,
                            env={**os.environ, 'PATH': f'{tools}{os.pathsep}{base_path}'})
    lines = result.stdout.splitlines()
    assert any(line.startswith('WARN  loop') and 'unapproved' in line for line in lines), result.stdout + result.stderr
    assert any(line.startswith('WARN  loop') and '2d' in line for line in lines), result.stdout
    assert not any(line.startswith('FAIL  loop') for line in lines), result.stdout
    answer.write_text('disabled')
    result = subprocess.run([str(root / 'scripts/nogg'), 'doctor'], cwd=root, text=True, capture_output=True,
                            env={**os.environ, 'PATH': f'{tools}{os.pathsep}{base_path}'})
    assert any(line.startswith('NOTE  loop') and 'will not run' in line for line in result.stdout.splitlines()), result.stdout
print('loop-doctor: ok')
PY
