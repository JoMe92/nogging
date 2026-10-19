#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/test-env.sh"
python3 - "$repo_root" <<'PY'
from pathlib import Path
import importlib.machinery, json, os, socket, subprocess, sys, tempfile, threading

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='nogg-rebase-broker-') as td:
    base = Path(td)
    main, remote, tree = base/'main', base/'origin.git', base/'lead'
    main.mkdir(); (main/'.nogging/state/worktrees').mkdir(parents=True)
    (main/'.nogging/state/sessions').mkdir()
    (main/'.nogging/config.json').write_text((source/'.nogging/config.json').read_text())
    subprocess.run(['git','init','-q','--bare',str(remote)],check=True)
    subprocess.run(['git','init','-q','-b','develop',str(main)],check=True)
    def git(cwd,*args,env=None):
        return subprocess.run(['git','-C',str(cwd),*args],check=True,capture_output=True,text=True,env=env)
    git(main,'config','user.name','Fixture'); git(main,'config','user.email','fixture@example.invalid')
    (main/'code.txt').write_text('base\n'); (main/'openspec/changes/demo').mkdir(parents=True)
    (main/'openspec/changes/demo/tasks.md').write_text('tick\n')
    git(main,'add','-A'); git(main,'commit','-qm','seed'); git(main,'remote','add','origin',str(remote)); git(main,'push','-q','-u','origin','develop')
    git(main,'worktree','add','-q','-b','chore/demo',str(tree),'origin/develop')
    (tree/'lead.txt').write_text('lead\n'); git(tree,'add','lead.txt'); git(tree,'commit','-qm','lead')
    (main/'code.txt').write_text('upstream\n'); git(main,'add','code.txt'); git(main,'commit','-qm','upstream'); git(main,'push','-q','origin','develop')
    (main/'.nogging/state/worktrees/implementation--demo.json').write_text(json.dumps({
        'path':str(tree),'branch':'chore/demo','kind':'implementation','state':'allocated'}))
    session='sf-lead-demo'
    (main/f'.nogging/state/sessions/{session}.json').write_text(json.dumps({
        'name':session,'state':'running','working_dir':str(tree)}))

    env={k:v for k,v in os.environ.items() if not k.startswith(('NOGG_','HERDR_')) and k not in ('TMUX','TMUX_TMPDIR')}
    shim=base/'bin'; shim.mkdir(); git_log=base/'git.log'
    real_git=subprocess.check_output(['which','git'],text=True).strip()
    git_shim=shim/'git'
    git_shim.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >>"{git_log}"\nexec "{real_git}" "$@"\n')
    git_shim.chmod(0o755)
    env['PATH']=str(shim)+os.pathsep+env['PATH']
    os.environ['PATH']=env['PATH']
    bridge=importlib.machinery.SourceFileLoader('nogg_rebase_broker_test',str(source/'scripts/nogg')).load_module()
    broker=importlib.machinery.SourceFileLoader('openspec_rebase_broker_test',str(source/'scripts/openspec-sandbox')).load_module()
    state=bridge.canonical_repository_state(main)
    assert broker.handle_rebase_request(bridge, {'action':'rebase','checkout':str(tree),'mode':'start','session':session},state)['status']=='done'
    assert git(tree,'merge-base','--is-ancestor','origin/develop','HEAD') is not None
    calls=git_log.read_text().splitlines()
    assert any('rebase origin/develop' in call for call in calls),calls

    # The fenced CLI sends one closed request; its process never invokes rebase.
    git_log.write_text('')
    sock_path=base/'broker.sock'
    server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); server.bind(str(sock_path)); server.listen(1)
    requests=[]
    def serve_one():
        with server.accept()[0] as conn:
            raw=b''
            while chunk:=conn.recv(4096): raw+=chunk
            request=json.loads(raw); requests.append(request)
            response=broker.handle_rebase_request(bridge,request,state)
            conn.sendall(json.dumps(response).encode())
    thread=threading.Thread(target=serve_one); thread.start()
    child_env={**env,'NOGGING_ROOT':str(tree),'NOGG_OPENSPEC_FENCED':'1',
               'NOGG_TASK_DONE_SOCKET':str(sock_path),'NOGG_SESSION_NAME':session}
    client=subprocess.run([str(source/'scripts/nogg'),'worktree','rebase'],cwd=tree,env=child_env,
                          text=True,capture_output=True,timeout=30)
    thread.join(timeout=30); server.close()
    assert not thread.is_alive(), 'broker request did not complete'
    assert client.returncode==0,(client.stdout,client.stderr)
    assert requests==[{'action':'rebase','checkout':str(tree),'mode':'start','session':session}],requests
    assert not any('rebase ' in call for call in git_log.read_text().splitlines()),git_log.read_text()

    for malformed in [
        {'action':'rebase','checkout':str(tree),'mode':'start','session':session,'command':'git'},
        {'action':'rebase','checkout':str(tree),'mode':'reset','session':session},
        {'action':'rebase','checkout':str(tree),'mode':['start'],'session':session},
        {'action':'rebase','checkout':str(base),'mode':'start','session':session},
        {'action':'rebase','checkout':str(tree),'mode':'start','session':'other'},
    ]:
        result=broker.handle_rebase_request(bridge,malformed,state)
        assert not result['ok'],(malformed,result)

    contract=json.loads(subprocess.check_output([str(source/'scripts/openspec-sandbox'),'--contract'],text=True,env=env))
    assert 'rebase-broker' in contract['features'],contract
    help_text=subprocess.check_output([str(source/'scripts/nogg'),'worktree','rebase','--help'],text=True,env=env)
    assert '--allow-live-session' in help_text,help_text
    print('worktree rebase broker: real host rebase, request validation, and contract passed')
PY
