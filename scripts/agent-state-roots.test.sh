#!/usr/bin/env bash
set -euo pipefail
python3 - "$(dirname "$0")/nogg" <<'PY'
import os, tempfile
from pathlib import Path
from unittest.mock import patch
from importlib.machinery import SourceFileLoader
m=SourceFileLoader('nogg_state_test', __import__('sys').argv[1]).load_module()
with tempfile.TemporaryDirectory() as tmp:
    home=Path(tmp); state=home/'state'; state.mkdir()
    outside=home/'escape'; outside.symlink_to('/etc', target_is_directory=True)
    with patch.dict(os.environ, {'HOME':tmp}, clear=False):
        m.CFG['agent_state_roots']={'antigravity':['~/state']}
        assert m.resolve_agent_state_roots()==[]
        grants=m.resolve_agent_state_roots([('antigravity','label')])
        assert m.resolve_agent_state_roots([('agy','option')])[0]['source']=='option'
        assert grants==[{'agent':'antigravity','source':'label','path':str(state)}]
        from types import SimpleNamespace
        reply=SimpleNamespace(stdout='[{"id":"SPEC-test","labels":["agent-state:agy"]}]',returncode=0)
        with patch.object(m, 'run', return_value=reply):
            assert m.session_state_grants('SPEC-test')[0]['source']=='label'
            assert m.session_state_grants('SPEC-test', ['codex'])[0]['agent']=='antigravity'
        # Exercise complete launch construction and metadata before any real tmux.
        m.CFG['session_state_dir']=str(home/'sessions')
        with patch.object(m,'bead_records',return_value=[{'id':'SPEC-test','labels':['agent-state:antigravity']}]), patch.object(m,'unmet_dependencies',return_value=[]), patch.object(m,'tmux_sessions',return_value=set()), patch.object(m,'tmux_has_session',return_value=False), patch.object(m,'tmux',return_value=SimpleNamespace(stdout='',returncode=0)), patch.object(m,'gen_session_name',return_value='state-labelled'):
            m.session_launch('lead','SPEC-test',str(m.ROOT),False,None,agent='codex',profile='restricted')
            record=m.json.loads((home/'sessions/state-labelled.json').read_text())
            assert record['agent_state_grants']==grants
            assert any(str(state) in arg for arg in record['command'])
        with patch.object(m,'bead_records',return_value=[{'id':'SPEC-test','labels':[]}]), patch.object(m,'unmet_dependencies',return_value=[]), patch.object(m,'tmux_sessions',return_value=set()), patch.object(m,'tmux_has_session',return_value=False), patch.object(m,'tmux',return_value=SimpleNamespace(stdout='',returncode=0)), patch.object(m,'gen_session_name',return_value='state-unrelated'):
            m.session_launch('lead','SPEC-test',str(m.ROOT),False,None,agent='codex',profile='restricted')
            record=m.json.loads((home/'sessions/state-unrelated.json').read_text())
            assert record['agent_state_grants']==[]
            assert all(str(state) not in arg for arg in record['command'])
        for bad in ['~/', '/etc', 'relative', '~unknown-agent-user/state', '~/missing', '~/escape']:
            m.CFG['agent_state_roots']={'antigravity':[bad]}
            with patch.object(m,'bead_records',return_value=[]), patch.object(m,'tmux') as tmux:
                try: m.session_launch('lead','SPEC-test',str(m.ROOT),False,None,agent_state=['antigravity'])
                except RuntimeError as exc: assert 'agent_state_roots' in str(exc)
                else: raise AssertionError('invalid grant reached launch')
                tmux.assert_not_called()
            try: m.resolve_agent_state_roots([('antigravity','option')])
            except RuntimeError: pass
            else: raise AssertionError(bad)
        for config in [[], {'unknown':[]}, {'agy':[]}, {'codex':'bad'}, {'codex':[2]}]:
            m.CFG['agent_state_roots']=config
            try: m.resolve_agent_state_roots()
            except RuntimeError: pass
            else: raise AssertionError(config)
        with patch.dict(os.environ, {'NOGG_CODEX_EXTRA_WRITABLE_ROOTS':tmp}):
            try: m.session_launch('lead','SPEC-test',None,False,None)
            except RuntimeError as exc: assert 'agent_state_roots' in str(exc)
            else: raise AssertionError('legacy environment accepted')
print('ok - state grants, unrelated sessions, malformed declarations and retired variable')
PY
