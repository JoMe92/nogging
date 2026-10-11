#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import copy, pathlib, sys
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
m=SourceFileLoader('followup_completion',str(pathlib.Path(sys.argv[1])/'scripts/nogg')).load_module()
tasks={'TASK-PROOF-001':dict(change='proof',file=None), 'TASK-PROOF-002':dict(change='proof',file=None)}
def mapped(bid, task, status='closed', dependencies=None):
    return dict(id=bid,status=status,labels=['openspec:change:proof','openspec:task:'+task],dependencies=dependencies or [])
base=[mapped('SPEC-one','TASK-PROOF-001'),mapped('SPEC-two','TASK-PROOF-002')]
followup=dict(id='SPEC-follow',status='blocked',labels=['openspec:change:proof','openspec:followup'])
def complete(issues):return m.change_completion('proof',tasks,issues)
assert complete(base).complete
assert complete(base+[followup]).complete, 'unlinked followup blocked mapped completion'
plans,quarantined=m.reconciliation_plan(tasks,base+[followup],[])
assert plans=={'proof':base} and not quarantined, 'followup entered checkbox mirror'
assert m.archive_ready_changes(tasks,base+[followup])==['proof']
assert not complete(base[:1]).complete, 'unmaterialized approved task completed'
assert not complete(base+[base[0]]).complete, 'duplicate identity completed'
assert not complete(base+[mapped('SPEC-duplicate','TASK-PROOF-001')]).complete
assert not complete(base+[dict(id='SPEC-bad',status='closed',labels=['openspec:change:proof'])]).complete
for status in ['open','blocked','in_progress']:
    rows=copy.deepcopy(base);rows[0]['status']=status
    assert not complete(rows).complete
rows=copy.deepcopy(base)+[copy.deepcopy(followup)]
rows[0]['dependencies']=[dict(issue_id='SPEC-one',depends_on_id='SPEC-follow',type='blocks')]
assert complete(rows).blocking_ids==('SPEC-follow',) and not complete(rows).complete
assert m.archive_ready_changes(tasks,rows)==[]
rows[-1]['status']='closed'
assert complete(rows).complete
# A nonblocking traceability edge never becomes an invented blocker.
rows[-1]['status']='open';rows[0]['dependencies'][0]['type']='relates-to'
assert complete(rows).complete
# Closed external prerequisites can still have unresolved transitive blockers.
rows[0]['dependencies'][0]['type']='blocks';rows[-1]['status']='closed'
rows[-1]['dependencies']=[dict(type='blocks',depends_on_id='SPEC-external')]
rows.append(dict(id='SPEC-external',status='open',labels=[]))
assert complete(rows).blocking_ids==('SPEC-external',)
rows[-1]['status']='closed';assert complete(rows).complete
for dependencies in [None, {}, ['invalid'], [dict(depends_on_id='SPEC-follow')],
                     [dict(type='blocks',issue_id='SPEC-wrong',depends_on_id='SPEC-follow')]]:
    invalid=copy.deepcopy(base);invalid[0]['dependencies']=dependencies
    assert not complete(invalid).complete
invalid=copy.deepcopy(base);invalid[0]['dependency_count']=1
assert not complete(invalid).complete
missing=copy.deepcopy(base);missing[0]['dependencies']=[dict(type='blocks',depends_on_id='SPEC-missing')]
assert not complete(missing).complete and complete(missing).blocking_ids==('SPEC-missing',)
# Sweep uses the same approved-task/edge proof and preserves PR semantics.
with patch.object(m,'bead_change',return_value='proof'),patch.object(m,'task_map',return_value=(tasks,[])),patch.object(m,'beads',return_value=base+[followup]),patch.object(m,'_session_worktree_branch',return_value='feature/proof'),patch.object(m,'_pr_state_for_branch',return_value='MERGED'):
    assert m._sweep_state({'bead_id':'SPEC-one'})=='change-complete'
    with patch.object(m,'_pr_state_for_branch',return_value='OPEN'):
        assert m._sweep_state({'bead_id':'SPEC-one'})=='active'
    with patch.object(m,'beads',return_value=missing):
        assert m._sweep_state({'bead_id':'SPEC-one'})=='bead-blocked (SPEC-missing)'
print('Followups/completion: approved mapped tasks, explicit/transitive blocking edges, unknown state, archive readiness and sweep passed')
PY
