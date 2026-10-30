#!/usr/bin/env bash
# TASK-SCL-004: the internal `loop` session role (design Decisions 1 and 4).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
from pathlib import Path
import contextlib, io, json, os, shutil, subprocess, sys, tempfile
source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='nogg loop role ') as td:
    root = Path(td) / 'main'; root.mkdir()
    for d in ('.pi/extensions', '.codex/rules', '.nogging/launch-profiles', '.nogging/launch-prompts'):
        shutil.copytree(source / d, root / d)
    subprocess.run(['bash', str(source / 'scripts/lib/test-fixture-config.sh'),
                    str(source / '.nogging/config.json'), str(root / '.nogging/config.json')], check=True)
    (root / 'scripts').mkdir()
    for name in ['session-launch', 'session-log-writer', 'openspec-sandbox', 'nogg']:
        shutil.copy2(source / 'scripts' / name, root / 'scripts' / name)
    (root / '.gitignore').write_text('.nogging/state/\n.nogging/locks/\n')
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-qm', 'seed'], check=True)
    os.environ['NOGGING_ROOT'] = str(root)
    m = SourceFileLoader('loop_role', str(source / 'scripts/nogg')).load_module()
    m.session_backend_module()
    from session_backend_tmux import TmuxBackend
    assert m.normalize_role('loop') == ('loop', 'loop')

    def loop(**extra):
        return {'name': 'nightly-scan', 'run_id': 'r-1', 'kickoff_message': '[nogg loop nightly-scan run r-1]\nlook', **extra}
    def records():
        return [r for _, r in m.session_records()]
    def launch(agent='claude', **kw):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            name = m.session_launch('loop', None, None, False, None, agent=agent, loop=kw.pop('loop_data', loop()), **kw)
        return name, buf.getvalue()
    def refused(match=None, **kw):
        before = records()
        try:
            m.session_launch(**kw)
        except RuntimeError as exc:
            if match: assert match in str(exc), str(exc)
        else:
            raise AssertionError(f'accepted: {kw}')
        assert records() == before, 'a refused loop launch left a session record'

    calls = []
    with patch.object(m, 'tmux', side_effect=lambda *a, **k: calls.append(a)), \
         patch.object(TmuxBackend, 'pid', return_value=os.getpid()), \
         patch.object(m, 'tmux_sessions', return_value=set()), \
         patch.object(m, 'tmux_has_session', return_value=False), \
         patch.object(m, 'bead_records', side_effect=AssertionError('loop consulted a Bead')), \
         patch.object(m, 'unmet_dependencies', side_effect=AssertionError('loop consulted blockers')):
        # --- record fields, floor and fence, per authority and agent ----------
        for agent in ('claude', 'codex', 'pi'):
            for authority in ('restricted', 'trusted'):
                data = loop(authority=authority)
                data['run_id'] = f'{agent}-{authority}'
                name, out = launch(agent, loop_data=data)
                rec = next(r for r in records() if r['name'] == name)
                assert rec['role'] == 'loop' and rec['bead_id'] is None, rec
                assert rec['loop_name'] == 'nightly-scan' and rec['loop_run_id'] == f'{agent}-{authority}'
                assert name.startswith('sf-loop-nightly-scan-'), name
                assert rec['working_dir'] == str(root.resolve()), rec['working_dir']
                assert rec['profile'] == authority and not rec['floor_lifted'] and rec['openspec_readonly'] is True
                assert '--bead' not in rec['command']
                assert any('.nogging/launch-prompts/loop.md' in str(a) for a in rec['command']), rec['command']
                assert m._role_display(rec) == 'loop:nightly-scan'
                if agent == 'claude':
                    eff = json.loads(Path(rec['effective_settings_path']).read_text())
                    deny = eff['permissions']['deny']
                    for entry in m.FLOOR_DENY + m.OPENSPEC_READONLY_DENY:
                        assert entry in deny, f'{authority}: missing {entry}'
                    for entry in m.LOOP_DENY:
                        assert entry in deny, f'{authority}: missing {entry}'
                    assert 'Bash(./scripts/nogg session launch:*)' in deny
                    allow = eff['permissions'].get('allow', [])
                    assert m.INBOX_RULE in allow, 'every session may read the inbox'
                    assert not any('nogg session' in a for a in allow if a != m.INBOX_RULE), 'loop gained child-control rules'
                else:
                    assert any('--readonly-root' in str(a) for a in rec['command']) or agent == 'pi'
        # default authority is restricted
        d = loop(); d.pop('authority', None); d['run_id'] = 'dflt'
        name, _ = launch(loop_data=d)
        assert next(r for r in records() if r['name'] == name)['profile'] == 'restricted'
        # two concurrent loop runs coexist (no per-bead duplicate guard)
        d = loop(); d['run_id'] = 'second'
        launch(loop_data=d)
        # a kickoff, when requested, carries the caller's message exactly
        sent = []
        with patch.object(m, 'session_kickoff', side_effect=lambda n, msg=None, change=None: sent.append((n, msg))):
            d = loop(); d['run_id'] = 'kick'
            name, _ = launch(loop_data=d, kickoff=True)
        assert sent == [(name, loop()['kickoff_message'])], sent
        # session list shows loop:<name>
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), patch.object(m, 'session_liveness', return_value=(set(), set())):
            m.session_list()
        assert 'loop:nightly-scan' in buf.getvalue()

        # --- refusals before any side effect ----------------------------------
        base = dict(role='loop', bead=None, cwd=None, read_only=False, owner=None, loop=loop())
        refused('nogg loop run-now', **{**base, 'loop': None})
        refused(**{**base, 'bead': 'SPEC-x'})
        refused(**{**base, 'cwd': str(root.parent)})
        refused(**{**base, 'profile': 'orchestrator'})
        refused(**{**base, 'profile': 'trusted'})
        refused(**{**base, 'prompt': 'orchestrator'})
        refused(**{**base, 'prompt': 'autonomous'})
        refused(**{**base, 'full_access': True})
        refused(**{**base, 'ignore_usage_gate': True})
        refused(**{**base, 'resume': 'abc'})
        refused(**{**base, 'agent_state': ['codex']})
        refused('authority', **{**base, 'loop': loop(authority='orchestrator')})
        refused('authority', **{**base, 'loop': loop(authority='full-access')})
        refused('unsupported key', **{**base, 'loop': loop(profile='orchestrator')})
        refused('unsupported key', **{**base, 'loop': loop(prompt='orchestrator')})
        refused('kickoff message', **{**base, 'loop': {**loop(), 'kickoff_message': ' '}})
        refused('loop name', **{**base, 'loop': loop(name='Bad Name')})
        refused('run_id', **{**base, 'loop': {**loop(), 'run_id': 'a b'}})
        refused('run_id', **{**base, 'loop': {**loop(), 'run_id': 'x' * 129}})
        refused('loop name', **{**base, 'loop': loop(name='a' * 41)})
        refused('loop name', **{**base, 'loop': loop(name=7)})
        refused('kickoff message', **{**base, 'loop': {**loop(), 'kickoff_message': 'a\0b'}})
        refused(**{**base, 'resume': ''})
        refused(**{**base, 'cwd': ''})
        refused('only with the internal loop role', **{**base, 'role': 'lead', 'bead': 'SPEC-x'})
        # no kickoff default exists for a loop run
        rec = next(r for r in records() if r['role'] == 'loop')
        try: m._kickoff_message(rec['name'], rec)
        except RuntimeError as exc: assert 'loop run' in str(exc)
        else: raise AssertionError('loop kickoff had a default message')

    # --- the public CLI refuses the role before any side effect ---------------
    env = {**os.environ, 'NOGGING_ROOT': str(root)}
    before = sorted(p.name for p in (root / '.nogging/state/sessions').iterdir())
    res = subprocess.run([str(root / 'scripts/nogg'), 'session', 'launch', '--role', 'loop', '--agent', 'claude'],
                         env=env, capture_output=True, text=True, cwd=root)
    assert res.returncode != 0 and 'nogg loop run-now' in res.stdout + res.stderr, (res.stdout, res.stderr)
    assert sorted(p.name for p in (root / '.nogging/state/sessions').iterdir()) == before

    # --- usage gate: loop is a gated role, allowed in exclude_roles -----------
    sys.path.insert(0, str(source / 'scripts'))
    import nogg_usage
    assert 'loop' in nogg_usage.GATE_ROLES
    assert 'loop' not in nogg_usage.gate_config({})['exclude_roles']
    assert nogg_usage.gate_config({'exclude_roles': ['planning', 'loop']})['exclude_roles'] == ['planning', 'loop']
    with patch.object(m, 'usage_module', return_value=nogg_usage):
        with patch.dict(m.CFG, {'usage_gate': {'exclude_roles': ['planning', 'loop']}}):
            assert m.usage_gate_admission('loop', 'claude', [], False)['decision'] == 'excluded'
        with patch.dict(m.CFG, {'usage_gate': {'enabled': True}}), \
             patch.object(nogg_usage, 'observe', side_effect=AssertionError('observed')) as obs:
            try: m.usage_gate_admission('loop', 'claude', [], False)
            except AssertionError as exc: assert 'observed' in str(exc)
            else: raise AssertionError('loop role skipped the gate by default')
print('session-loop-role: ok')
PY
