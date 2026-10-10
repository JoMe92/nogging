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
        record=dict(name=name,role='planning',bead_id=None,planning_id=pid,description='scope',working_dir=str(workdir),state='running',session_pid=os.getpid(),session_pid_start=m.process_start(os.getpid()))
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
    lock_path=root/'.nogging/locks/planning.lock'
    held=json.loads(lock_path.read_text())
    assert held['session_name']==winner['name'] and held['pid']==os.getpid()
    assert held['pid_start']==m.process_start(os.getpid()) and held['session_root']==str(root)
    with patch.dict(os.environ,{'NOGG_SESSION_NAME':winner['name'],'NOGG_SESSION_ROLE':'planning','NOGG_SESSION_ROOT':str(root)}):
        assert m.openspec_tool_decision(winner['working_dir'],'openspec/proof.md')==(True,True)
        assert m.openspec_tool_decision(winner['working_dir'],str(Path(loser['working_dir'])/'openspec/proof.md'))==(True,False)
        with patch.dict(os.environ,{'NOGG_SESSION_NAME':loser['name']}):
            assert m.openspec_tool_decision(loser['working_dir'],'openspec/proof.md')==(True,False)
        with patch.dict(os.environ,{'NOGG_SESSION_ROLE':'lead'}):
            assert m.openspec_tool_decision(winner['working_dir'],'openspec/proof.md')==(True,False)
    original=lock_path.read_bytes()
    # An execution stop must be independent even of malformed planning state.
    lock_path.write_text('{broken')
    assert m.release_planning_lock(session_record=dict(role='lead',name='other')) is False
    assert lock_path.read_text()=='{broken'
    lock_path.write_bytes(original)
    assert m.release_planning_lock(session_record=loser) is False
    assert lock_path.read_bytes()==original
    assert not (root/'.nogging/locks/openspec.readonly').exists()
    foreign_env={**env,'NOGG_SESSION_NAME':loser['name']}
    forced=subprocess.run([str(source/'scripts/nogg'),'plan-end','--force'],env=foreign_env,text=True,capture_output=True)
    assert forced.returncode and 'another live owner cannot be released' in forced.stderr
    assert lock_path.read_bytes()==original
    # Terminal ownership closes the boundary immediately, retaining a live
    # owner record until liveness is proven false. Never unlink a reused PID.
    assert m.release_planning_lock(session_record=winner) is False
    assert lock_path.exists() and (root/'.nogging/locks/openspec.readonly').exists()
    assert not m.planning_lock_live(dict(held,pid_start='different-process-birth'))
    # An agent sandbox with a private PID namespace (Codex bwrap) cannot see the
    # host owner PID, so it cannot disprove it; the owner's namespace still can.
    own_ns=m.pid_namespace()
    assert own_ns and own_ns.startswith('pid:[')
    assert not m.planning_lock_live(dict(held,pid_start='different-process-birth',pid_ns=own_ns))
    assert m.planning_lock_live(dict(held,pid_start='different-process-birth',pid_ns='pid:[1]'))
    assert m.pid_namespace(2**22+1) is None

    subprocess.run([str(source/'scripts/nogg'),'plan-end'],env=env,check=True,stdout=subprocess.DEVNULL)
    # A failed owner closes the boundary but retains a still-live PID. A
    # later cleanup removes only that exact record once its birth token dies.
    lock_path.write_bytes(original)
    (root/'.nogging/locks/openspec.readonly').unlink()
    owner_path=m.sessions_dir()/(winner['name']+'.json')
    m.transition(owner_path,winner,'failed',exit_reason='fixture interrupted kickoff')
    assert lock_path.exists() and (root/'.nogging/locks/openspec.readonly').exists()
    dead=json.loads(original);dead['pid_start']='expired-owner-birth'
    lock_path.write_text(json.dumps(dead))
    with patch.object(m,'beads',return_value=[]),patch.object(m,'tmux_sessions',return_value={r['name'] for r in records}):
        sections,attention=m.recover_scan()
    locks_text='\n'.join(line for title,lines in sections if title=='Locks' for line in lines)
    assert winner['name'] in locks_text and winner['planning_id'] in locks_text and winner['working_dir'] in locks_text
    assert any('interrupted planning owner '+winner['name'] in item for item in attention)
    dead_session=dict(winner,session_pid_start='expired-owner-birth')
    assert m.release_planning_lock(session_record=dead_session) is True
    assert not lock_path.exists()

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
