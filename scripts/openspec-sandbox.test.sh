#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import datetime,json,os,socket,subprocess,sys,tempfile
source=Path(sys.argv[1])
probe=subprocess.run(['unshare','--user','--map-root-user','--mount','true'],capture_output=True)
if probe.returncode:
    print('SKIP: host denies Linux user/mount namespaces; production execution must refuse')
    sys.exit(0)
with tempfile.TemporaryDirectory(prefix='nogg OS fence ') as td:
    root=Path(td)/'main';root.mkdir()
    (root/'.nogging').mkdir();(root/'openspec/changes/proof').mkdir(parents=True)
    tasks=root/'openspec/changes/proof/tasks.md';tasks.write_text('- [ ] TASK-PROOF-001 tick a closed task\n')
    bd=root/'bd-stub';bd.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps([dict(id=sys.argv[2],status="closed" if sys.argv[2]=="SPEC-proof" else "open",labels=["openspec:change:proof","openspec:task:TASK-PROOF-001"])]))\n');bd.chmod(0o755)
    (root/'.nogging/config.json').write_text(json.dumps({'beads_command':str(bd)}))
    (root/'.gitignore').write_text('.nogging/locks/\n.nogging/state/\n')
    def git(*args):return subprocess.run(['git','-C',str(root),*args],check=True,capture_output=True,text=True)
    git('init','-q');git('add','.');git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','seed')
    roots=[root]
    for suffix in ['execution','planner']:
        path=root.parent/suffix;git('worktree','add','-q','--detach',str(path));roots.append(path)
    locks=root/'.nogging/locks';locks.mkdir();(locks/'planning.lock').write_text(json.dumps({'pid':os.getpid(),'host':socket.gethostname(),'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    # This is an actual process in the same sandbox used by all three wrappers.
    verifier=root.parent/'verify.py'
    verifier.write_text('''from pathlib import Path
import errno,json,os,subprocess,sys
roots=json.loads(sys.argv[1]);helper=sys.argv[2]
assert os.environ.get('NOGGING_ROOT') == os.environ.get('NOGG_EXPECT_ORIGINAL_ROOT')
assert os.environ['NOGG_OPENSPEC_FENCED']=='1'
for root in roots:
    spec=Path(root)/'openspec';task=spec/'changes/proof/tasks.md'
    for action in [lambda:task.write_text('bad'),lambda:task.unlink(),lambda:(spec/'new.md').write_text('bad')]:
        try:action()
        except OSError as exc:assert exc.errno in [errno.EROFS,errno.EACCES,errno.EPERM],exc
        else:raise AssertionError('OpenSpec write escaped filesystem fence')
    attempt=subprocess.run(['mount','-o','remount,bind,rw',str(spec)],capture_output=True)
    assert attempt.returncode,'runtime retained remount capability'
    # A runtime's own nested sandbox (Codex bwrap) gains namespace root but the
    # inherited read-only mounts stay locked: no rw remount, unmount or bind around.
    escape=f"""mount -o remount,bind,rw {spec} && exit 10
umount {spec} && exit 11
umount -l {spec} && exit 12
mkdir -p {root}/.escape && mount --bind {root} {root}/.escape && exit 13
touch {spec}/escaped && exit 14
exit 0"""
    attempt=subprocess.run(['unshare','--user','--map-root-user','--mount','sh','-c',escape],capture_output=True,text=True)
    assert attempt.returncode not in range(10,15),('nested sandbox escaped locked OpenSpec mount',attempt)
    assert attempt.returncode==0,('runtime cannot build its own nested sandbox',attempt.stderr)
assert os.getuid()!=0,'runtime runs as namespace root; agents refuse unattended modes as root'
nested=subprocess.run(['unshare','--user','--map-root-user','--mount','--pid','--fork','true'],capture_output=True,text=True)
assert nested.returncode==0,('runtime cannot build its own nested sandbox',nested.stderr)
result=subprocess.run([helper,'task-done','SPEC-open'],text=True,capture_output=True)
assert result.returncode and 'not closed' in result.stderr,result
result=subprocess.run([helper,'task-done','SPEC-proof'],text=True,capture_output=True)
assert result.returncode==0 and 'ticked' in result.stdout,result
assert '- [x] TASK-PROOF-001' in (Path.cwd()/'openspec/changes/proof/tasks.md').read_text()
(Path.cwd()/'implementation.txt').write_text('execution remains writable')
print('OS fence: create/modify/delete denied across all worktrees; remount denied; non-root runtime nests its own sandbox without escaping; closed-only broker tick works')
''')
    result=subprocess.run([str(source/'scripts/openspec-sandbox'),sys.executable,str(verifier),json.dumps([str(p) for p in roots]),str(source/'scripts/nogg')],cwd=roots[1],text=True,capture_output=True,env={**os.environ,'NOGGING_ROOT':str(root),'NOGG_EXPECT_ORIGINAL_ROOT':str(root)})
    assert result.returncode==0,(result.stdout,result.stderr)
    print(result.stdout.strip())
    assert tasks.read_text().startswith('- [ ]') # broker wrote only execution worktree
    # Operator remains outside the namespace and may change OpenSpec via Git.
    git('switch','-qc','plan/proof');tasks.write_text('operator branch content\n');git('add',str(tasks));git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','plan')
    git('checkout','-q','master');assert tasks.read_text().startswith('- [ ]')
    git('merge','--ff-only','plan/proof');assert tasks.read_text()=='operator branch content\n'
    print('Operator switch/checkout/merge between different OpenSpec contents remain writable')
PY
