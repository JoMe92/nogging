#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import copy, json, pathlib, subprocess, sys, tempfile
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
from types import SimpleNamespace
m = SourceFileLoader('sweep_scope', str(pathlib.Path(sys.argv[1])/'scripts/nogg')).load_module()
tasks = {f'TASK-SCOPE-{n}': {'change':'scope'} for n in ('001','002')}
def issue(bid, task, status='open', deps=()):
    return dict(id=bid, status=status, labels=['openspec:change:scope','openspec:task:'+task],
                dependencies=list(deps))
rows = [issue('B1','TASK-SCOPE-001'), issue('B2','TASK-SCOPE-002','blocked')]
rec = dict(bead_id='B1',role='lead')
with patch.object(m,'task_map',return_value=(tasks,[])), patch.object(m,'beads',side_effect=lambda:rows), patch.object(m,'_session_worktree_branch',return_value='feature'), patch.object(m,'_pr_state_for_branch',return_value='MERGED'):
    assert m._sweep_state(rec) == 'active', 'unrelated blocked sibling'
    assert m._sweep_state(dict(rec,authorized_change='scope')) == 'bead-blocked (B2)'
    assert m._sweep_state(dict(rec,role='specialist:backend-engineer',authorized_change='scope')) == 'active'
    rows[0]['dependencies']=[dict(type='blocks',depends_on_id='B2')]
    assert m._sweep_state(rec) == 'bead-blocked (B2)'
    rows[1]['status']='closed'
    rows[1]['dependencies']=[dict(type='blocks',depends_on_id='external')]
    rows.append(dict(id='external',status='blocked',labels=[],dependencies=[]))
    assert m._sweep_state(rec) == 'bead-blocked (external)', 'transitive external blocker'
    rows.pop(); rows[1]['dependencies']=[]; rows[1]['status']='blocked'
    rows[0]['dependencies']=[]; rows[0]['status']='closed'
    assert m._sweep_state(rec) == 'change-complete', 'assigned scope is complete despite sibling'
    for state, expected in [('OPEN','active'),('CLOSED','active'),('CHECKS_UNRESOLVED','active'),(None,'active (integration unknown)'),('ABSENT','active (integration unknown)')]:
        with patch.object(m,'_pr_state_for_branch',return_value=state):
            assert m._sweep_state(rec) == expected
    with patch.object(m,'_pr_state_for_branch',return_value='ABSENT'), patch.object(m,'_local_integration_verified',return_value=True):
        assert m._sweep_state(rec) == 'change-complete'
    rows[1]['status']='closed'
    assert m._sweep_state(dict(rec,authorized_change='scope')) == 'change-complete'
    rows.pop()
    assert 'unknown' in m._sweep_state(dict(rec,authorized_change='scope')), 'unmaterialized task'
    rows[0]['dependencies']=[dict(type='blocks',depends_on_id='missing')]
    assert m._sweep_state(rec) == 'bead-blocked (missing)'
    rows[0]['dependencies']=['invalid']
    assert 'unknown' in m._sweep_state(rec)
# PR queries distinguish no PR, network failure, open PR and unresolved checks.
def result(code=0, out=''):
    return SimpleNamespace(returncode=code,stdout=out)
merged=dict(state='MERGED',statusCheckRollup=[dict(conclusion='SUCCESS')],headRefOid='a'*40)
for data, expected in [([], 'ABSENT'),([merged],'MERGED'),([dict(merged,state='OPEN')],'OPEN'),
                        ([dict(merged,statusCheckRollup=[dict(conclusion='FAILURE')])],'CHECKS_UNRESOLVED'),
                        ([dict(merged,headRefOid='b'*40)],None),([merged,merged],None)]:
    def fake_run(*args, **kwargs):
        if args[0]=='git': return result(out='a'*40+'\n')
        assert '--state' in args and 'all' in args
        return result(out=json.dumps(data))
    with patch.object(m,'run',side_effect=fake_run):
        assert m._pr_state_for_branch('feature') == expected
for res in [result(1),result(out='broken'),result(out='{}')]:
    with patch.object(m,'run',return_value=res): assert m._pr_state_for_branch('feature') is None
# Local integration is a verified recorded commit, never absence of gh output.
with tempfile.TemporaryDirectory() as tmp:
    def git(*args):
        return subprocess.check_output(['git','-C',tmp,*args],text=True).strip()
    git('init','-q','-b','develop'); git('config','user.name','Test'); git('config','user.email','test@example.com')
    git('commit','-q','--allow-empty','-m','base')
    sha=git('rev-parse','HEAD')
    record=dict(working_dir=tmp,integration_evidence=dict(commit=sha,target_ref='refs/heads/develop'))
    assert m._local_integration_verified(record)
    assert not m._local_integration_verified(dict(working_dir=tmp))
    git('checkout','-q','-b','feature'); git('commit','-q','--allow-empty','-m','unintegrated')
    assert not m._local_integration_verified(record), 'stale evidence'
    record['integration_evidence']['commit']=git('rev-parse','HEAD')
    assert not m._local_integration_verified(record), 'not integrated'
    git('branch','-f','develop','HEAD')
    assert m._local_integration_verified(record)
    pathlib.Path(tmp,'dirty').write_text('pending')
    assert not m._local_integration_verified(record), 'dirty worktree'
# Explicit change kickoff persists scope; specialist kickoff never expands it.
with patch.object(m,'_require_running',return_value=(pathlib.Path('/unused'),rec)), patch.object(m,'bead_change',return_value='scope'), patch.object(m,'_session_kickoff') as send, patch.object(m,'load_session',return_value=(None,dict(rec))), patch.object(m,'write_session') as write:
    m.session_kickoff('session',change='scope')
    assert send.call_count == 1
    assert write.call_args.args[1]['authorized_change']=='scope'
with patch.object(m,'_require_running',return_value=(None,dict(rec,role='specialist:test-runner'))):
    try: m.session_kickoff('session',change='scope')
    except RuntimeError: pass
    else: raise AssertionError('specialist change authorization accepted')
print('Sweep scope, dependency, PR and local integration evidence regressions passed')
PY
