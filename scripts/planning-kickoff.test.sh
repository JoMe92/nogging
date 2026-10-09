#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json,os,shutil,subprocess,sys,tempfile,threading
source=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='nogg planning kickoff ') as td:
    root=Path(td)/'main';root.mkdir();(root/'.nogging').mkdir()
    shutil.copy2(source/'.nogging/config.json',root/'.nogging/config.json')
    (root/'.gitignore').write_text('.nogging/state/\n.nogging/locks/\n')
    subprocess.run(['git','init','-q',str(root)],check=True)
    subprocess.run(['git','-C',str(root),'add','.'],check=True)
    subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','seed'],check=True)
    os.environ['NOGGING_ROOT']=str(root)
    m=SourceFileLoader('planning_kickoff',str(source/'scripts/nogg')).load_module()
    records=[]
    for suffix in ['first','second']:
        pid='plan-'+suffix;workdir=root.parent/pid;name='planning-session-'+suffix
        subprocess.run(['git','-C',str(root),'worktree','add','-q','-b',f'plan/{pid}/scope',str(workdir)],check=True)
        m.write_worktree_record(m.worktree_record_path('plan',pid,'scope'),dict(kind='planning',planning_id=pid,description='scope',branch=f'plan/{pid}/scope',path=str(workdir),state='allocated'))
        record=dict(name=name,role='planning',bead_id=None,planning_id=pid,description='scope',working_dir=str(workdir),state='running')
        m.write_session(m.sessions_dir()/(name+'.json'),record);records.append(record)
    sent=[]
    with patch.object(m,'tmux_sessions',return_value={r['name'] for r in records}),patch.object(m,'session_send',side_effect=lambda name,message:sent.append((name,message))):
        for record in records:m.session_kickoff(record['name'])
        assert len(sent)==2 and not (root/'.nogging/locks/planning.lock').exists()
        for record,delivery in zip(records,sent):
            message=delivery[1]
            assert record['planning_id'] in message and record['working_dir'] in message
            assert 'acquire ./scripts/nogg plan-begin yourself' in message and 'before any OpenSpec write' in message
            assert 'Do not select or claim execution Beads' in message
        m.session_kickoff(records[0]['name'],'operator supplied scope')
        assert sent[-1][1]=='operator supplied scope'
    # Simulated agent processes consume the role-specific kickoff and acquire
    # their own lock through the real CLI. Controller never pre-acquires it.
    gate=threading.Barrier(2)
    def acquire(record):
        env={**os.environ,'NOGGING_ROOT':record['working_dir'],'NOGG_SESSION_NAME':record['name'],'NOGG_SESSION_ROLE':'planning'}
        gate.wait()
        result=subprocess.run([str(source/'scripts/nogg'),'plan-begin'],env=env,text=True,capture_output=True)
        if result.returncode==0:
            path=Path(record['working_dir'])/'openspec/proof.md';path.parent.mkdir();path.write_text('only the lock winner writes\n')
        return record,result
    with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(acquire,records))
    assert sorted(result.returncode for _,result in results)==[0,1]
    winner=next(record for record,result in results if result.returncode==0)
    loser,refusal=next((record,result) for record,result in results if result.returncode!=0)
    assert 'planning lock held by' in refusal.stderr
    assert not (Path(loser['working_dir'])/'openspec').exists()
    assert (root/'.nogging/locks/planning.lock').exists()
    assert not (root/'.nogging/locks/openspec.readonly').exists()
    env={**os.environ,'NOGGING_ROOT':str(root),'NOGG_SESSION_NAME':winner['name'],'NOGG_SESSION_ROLE':'planning'}
    subprocess.run([str(source/'scripts/nogg'),'plan-end'],env=env,check=True,stdout=subprocess.DEVNULL)
    # Specialist default kickoff has one already-claimed task and no Main
    # Worker mutation authority, even if an associated change has siblings.
    claimed=dict(id='SPEC-delegated',status='in_progress',assignee='Nogging Lead')
    with patch.object(m,'_require_running',return_value=(None,dict(role='specialist:backend-engineer',bead_id='SPEC-delegated'))),patch.object(m,'run',return_value=subprocess.CompletedProcess([],0,json.dumps([claimed]),'')),patch.object(m,'session_send') as deliver:
        m.session_kickoff('specialist-session');message=deliver.call_args.args[1]
        assert 'already-claimed Bead SPEC-delegated' in message and 'Do not claim, re-status, close or commit' in message
        assert 'select sibling tasks' in message and 'edit openspec/' in message
    for invalid in [dict(claimed,status='open'),dict(claimed,assignee=''),{}]:
        with patch.object(m,'run',return_value=subprocess.CompletedProcess([],0,json.dumps([invalid]),'')):
            try:m.specialist_kickoff_message('SPEC-delegated')
            except RuntimeError:pass
            else:raise AssertionError('specialist kickoff accepted unclaimed/unknown task')
print('Planning kickoff: idle launch checkpoint, recorded scope, actual concurrent canonical acquisition, loser writes nothing, specialist authority passed')
PY
