#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
import copy, io, json, os, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
root = Path(sys.argv[1])
m = SourceFileLoader('nogg_agr_lifecycle', str(root/'scripts/nogg')).load_module()
conversation = '00000000-0000-4000-8000-000000000001'
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    m.CFG = {**m.CFG, 'session_state_dir': str(tmp/'sessions'), 'session_stop_grace_seconds': 0}
    workdir = tmp/'worktree'; (workdir/'.agents').mkdir(parents=True)
    name = 'sf-lead-spec-test'
    path = m.sessions_dir()/f'{name}.json'
    initial = {'name':name, 'agent':'antigravity', 'working_dir':str(workdir),
               'role':'lead','bead_id':'SPEC-test', 'state':'running',
               'antigravity_initial_turn':True, 'antigravity_conversation_id':None}
    m.write_session(path, initial)
    fixture = json.loads((root/'scripts/fixtures/antigravity/1.3.2/stop.json').read_text())
    fixture['cwd'] = str(workdir/'.agents')
    fixture['payload']['workspacePaths'] = [str(workdir)]
    def refused(fn):
        try: fn()
        except (RuntimeError, ValueError, TypeError): pass
        else: raise AssertionError('expected refusal')
    for bad in ('', 'latest', '--continue', '../../other', None):
        refused(lambda: m.validate_antigravity_conversation_id(bad))
    for field, value in [('conversationId','latest'),('fullyIdle','true'),('executionNum',True),('workspacePaths',['/other'])]:
        bad = copy.deepcopy(fixture); bad['payload'][field] = value
        refused(lambda: m.antigravity_stop_event(name,bad))
    refused(lambda: m.antigravity_stop_event(name,{}))
    assert not m.session_events_path(name).exists()
    with patch.object(m,'tmux_sessions',return_value={name}), patch.object(m,'tmux_has_session',return_value=True):
        refused(lambda: m.await_antigravity_first_turn(name,timeout=0))
        busy = copy.deepcopy(fixture); busy['payload']['fullyIdle'] = False
        m.antigravity_stop_event(name,busy)
        refused(lambda: m.await_antigravity_first_turn(name,timeout=0))
        calls = []
        with patch.object(m,'tmux',side_effect=lambda *a,**kw: calls.append(a)), patch.object(m,'bead_change',return_value='support-antigravity-runtime'):
            with patch.dict(os.environ,{'NOGG_SESSION_NAME':name,'NOGG_SESSION_AGENT':'antigravity'}), patch.object(sys,'stdin',io.StringIO(json.dumps(fixture))):
                m.session_emit('turn_end')
            # Capture survives the launcher's older in-memory lifecycle record.
            m.transition(path,initial,'running')
            rec = json.loads(path.read_text())
            assert rec['antigravity_conversation_id'] == conversation and rec['antigravity_ready_at']
            m.antigravity_stop_event(name,fixture)
            assert len(m.session_events_path(name).read_text().splitlines()) == 3
            changed = copy.deepcopy(fixture); changed['payload']['conversationId'] = '00000000-0000-4000-8000-000000000002'
            refused(lambda: m.antigravity_stop_event(name,changed))
            with ThreadPoolExecutor(max_workers=2) as pool:
                list(pool.map(m.session_kickoff, [name, name]))
            m.session_kickoff(name)
            assert len([a for a in calls if '-l' in a]) == 1
            assert len([a for a in calls if a[-1] == 'Enter']) == 1
            assert json.loads(path.read_text())['kickoff_sent_at']
            m.session_send(name,'Follow-up')
            assert calls[-2:] == [('send-keys','-t',name,'-l','Follow-up'),('send-keys','-t',name,'Enter')]
            with patch.object(m.time,'sleep'):
                m.session_stop(name,'test complete')
            assert json.loads(path.read_text())['state'] == 'stopped'
            count = len(calls)
            refused(lambda: m.session_kickoff(name))
            assert len(calls) == count
    # Wrapper contract: real argv translation, exact resume and no bare continue.
    bindir=tmp/'bin'; bindir.mkdir()
    fake=bindir/'agy'
    fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["OUT"]).write_text(json.dumps([sys.argv[1:],os.environ.get("AGY_CLI_DISABLE_AUTO_UPDATE")]))\n')
    fake.chmod(0o755)
    # Trust validation uses a minimal real checkout and the installed template.
    subprocess.run(['git','init','-q',str(workdir)],check=True)
    (workdir/'scripts/hooks').mkdir(parents=True)
    import shutil
    for rel in ('scripts/nogg','scripts/hooks/agy-guard'):
        shutil.copy2(root/rel,workdir/rel)
    shutil.copy2(root/'templates/antigravity/hooks.json',workdir/'.agents/hooks.json')
    # Hooks execute in .agents, but session records belong to the launcher root.
    owner = tmp/'owner'; (owner/'.nogging').mkdir(parents=True)
    (owner/'.nogging/config.json').write_text(json.dumps(m.CFG))
    command = json.loads((workdir/'.agents/hooks.json').read_text())['nogging-observability']['Stop'][0]['hooks'][0]['command']
    hook_env = {**os.environ, 'NOGG_SESSION_NAME':name, 'NOGG_SESSION_AGENT':'antigravity',
                'NOGG_SESSION_ROOT':str(owner)}
    before = m.session_events_path(name).read_text()
    subprocess.run(['bash','-c',command],cwd=workdir/'.agents',env=hook_env,
                   input=json.dumps(fixture),text=True,check=True)
    assert m.session_events_path(name).read_text().startswith(before)
    assert len(m.session_events_path(name).read_text().splitlines()) == 4
    home=tmp/'home'; home.mkdir()
    out=tmp/'argv.json'; prompt=tmp/'prompt.md'; prompt.write_text('Session instructions')
    env={k:v for k,v in os.environ.items() if not k.startswith(('NOGG_','NOGGING_'))}
    env.update(HOME=str(home),PATH=str(bindir)+os.pathsep+env['PATH'],OUT=str(out))
    base=[str(root/'scripts/session-launch'),'--agent','agy','--cwd',str(workdir),'--prompt',str(prompt)]
    for extra in ([],['--resume',conversation]):
        subprocess.run(base+extra,env=env,check=True)
        args,update=json.loads(out.read_text())
        assert update == 'true' and '--continue' not in args
        first=args[args.index('--prompt-interactive')+1]
        assert 'Wait for a separate operator message' in first and 'Session instructions' in first
        if extra: assert args[args.index('--conversation')+1] == conversation
        else: assert '--conversation' not in args
        out.unlink()
    for extra in (['--continue'],['--resume',''],['--resume','latest'],['--session-id',conversation]):
        result=subprocess.run(base+extra,env=env,capture_output=True)
        assert result.returncode != 0 and not out.exists()
print('Antigravity exact resume, validated Stop append, startup ordering, single kickoff and send/stop passed')
PY
