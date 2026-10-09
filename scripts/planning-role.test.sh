#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
from pathlib import Path
import contextlib, io, json, os, shutil, subprocess, sys, tempfile
source=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='nogg planning role ') as td:
    root=Path(td)/'main';root.mkdir()
    shutil.copytree(source/'.pi/extensions',root/'.pi/extensions')
    shutil.copytree(source/'.codex/rules',root/'.codex/rules')
    shutil.copytree(source/'.nogging/launch-profiles',root/'.nogging/launch-profiles')
    shutil.copytree(source/'.nogging/launch-prompts',root/'.nogging/launch-prompts')
    shutil.copy2(source/'.nogging/config.json',root/'.nogging/config.json')
    (root/'scripts').mkdir()
    for name in ['session-launch','session-log-writer','nogg']:
        shutil.copy2(source/'scripts'/name,root/'scripts'/name)
    (root/'.gitignore').write_text('.nogging/state/\n.nogging/locks/\n')
    subprocess.run(['git','init','-q',str(root)],check=True)
    subprocess.run(['git','-C',str(root),'add','.'],check=True)
    subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','seed'],check=True)
    origin=root.parent/'origin.git'
    subprocess.run(['git','init','-q','--bare',str(origin)],check=True)
    subprocess.run(['git','-C',str(root),'remote','add','origin',str(origin)],check=True)
    subprocess.run(['git','-C',str(root),'push','-q','origin','HEAD:develop'],check=True)
    os.environ['NOGGING_ROOT']=str(root)
    m=SourceFileLoader('planning_role',str(source/'scripts/nogg')).load_module()
    assert m.normalize_role('planning')==('planning','planning')
    try:m.normalize_role('planner')
    except RuntimeError:pass
    else:raise AssertionError('planner alias was accepted')
    calls=[]
    with patch.object(m,'tmux',side_effect=lambda *args,**kwargs:calls.append(args)),patch.object(m,'tmux_sessions',return_value=set()),patch.object(m,'tmux_has_session',return_value=False),patch.object(m,'bead_exists',return_value=True) as lookup,patch.object(m,'unmet_dependencies',side_effect=AssertionError('planning consulted execution blockers')):
        for agent in ['claude','codex','pi']:
            pid='planning-'+agent;description='scope-test';workdir=root.parent/pid
            subprocess.run(['git','-C',str(root),'worktree','add','-q','-b',f'plan/{pid}/{description}',str(workdir)],check=True)
            record_path=m.worktree_record_path('plan',pid,description)
            m.write_worktree_record(record_path,dict(kind='planning',planning_id=pid,description=description,branch=f'plan/{pid}/{description}',path=str(workdir),state='allocated'))
            with contextlib.redirect_stdout(io.StringIO()) as output:
                m.session_launch('planning',None,str(workdir),False,None,agent=agent,planning_id=pid,description=description)
            records=[r for _,r in m.session_records() if r.get('planning_id')==pid]
            assert len(records)==1
            record=records[0]
            assert record['role']=='planning' and record['bead_id'] is None
            assert record['description']==description and record['working_dir']==str(workdir)
            assert pid in record['name'] and '--bead' not in record['command']
            assert record['state']=='running' and 'session kickoff' in output.getvalue()
        for agent in ['claude','codex','pi']:
            pid='auto-'+agent
            with contextlib.redirect_stdout(io.StringIO()):
                m.session_launch('planning',None,None,False,None,agent=agent,planning_id=pid,description='fresh-scope')
            record=next(r for _,r in m.session_records() if r.get('planning_id')==pid)
            assert record['bead_id'] is None and record['role']=='planning'
            assert Path(record['working_dir'])!=root and Path(record['working_dir']).is_dir()
            assert Path(record['working_dir']).joinpath('.git').is_file()
            assert any('.nogging/launch-prompts/planning.md' in str(arg) for arg in record['command'])
            assert m.worktree_record_path('plan',pid,'fresh-scope').exists()
        assert lookup.call_count==0, 'Bead-optional launch queried a placeholder task'
        assert not (root/'.nogging/locks/planning.lock').exists(), 'bare launch acquired a lock'
        assert all(call[0]!='send-keys' for call in calls), 'bare launch sent a kickoff'
        assert all('NOGG_SESSION_ROLE=planning' in call for call in calls if call[0]=='new-session')
        # Optional association remains a real lookup, without execution claims
        # or dependency authority; it is preserved as supplied in metadata.
        workdir=root.parent/'planning-claude'
        with contextlib.redirect_stdout(io.StringIO()):
            m.session_launch('planning','SPEC-associated',str(workdir),False,None,planning_id='planning-claude',description='scope-test')
        assert lookup.call_count==1
        assert any(r.get('bead_id')=='SPEC-associated' for _,r in m.session_records())
    def refused(**kwargs):
        before=list(m.session_records())
        try:m.session_launch(**kwargs)
        except RuntimeError:pass
        else:raise AssertionError('invalid planning scope accepted')
        assert list(m.session_records())==before
    base=dict(role='planning',bead=None,cwd=str(workdir),read_only=False,owner=None,planning_id='planning-claude',description='scope-test')
    for field,value in [('planning_id',None),('planning_id','bad id'),('description','Bad_Description'),('cwd',str(root)),('cwd',str(workdir/'nested'))]:
        refused(**{**base,field:value})
    refused(**{**base,'role':'lead','bead':'SPEC-associated'})
    refused(**{**base,'cwd':None})
    refused(**{**base,'planning_id':'bad-profile-scope','cwd':None,'profile':'missing-profile'})
    assert not m.worktree_record_path('plan','bad-profile-scope','scope-test').exists()
    assert not (root.parent/f'{root.name}-plan-bad-profile-scope-scope-test').exists()
    refused(role='lead',bead=None,cwd=None,read_only=False,owner=None)
    with patch.object(m,'bead_exists',return_value=False):
        refused(**{**base,'bead':'SPEC-missing'})
    # CLI parser accepts the canonical scope flags for every runtime. Validation
    # fails on the intentionally malformed identifier before any launch.
    for agent in ['claude','codex','pi']:
        cli=subprocess.run([str(source/'scripts/nogg'),'session','launch','--role','planning','--planning-id','bad id','--description','scope-test','--agent',agent],text=True,capture_output=True)
        assert cli.returncode==1 and 'planning ID must' in cli.stderr
print('Planning role: Claude/Codex/Pi scopes, honest optional Bead metadata, bare launch idle, parser and unsafe-scope rejection passed')
PY
