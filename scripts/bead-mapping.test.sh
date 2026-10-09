#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
from pathlib import Path
import sys
m = SourceFileLoader('bead_mapping', str(Path(sys.argv[1])/'scripts/nogg')).load_module()
change, other = 'openspec:change:alpha', 'openspec:change:beta'
task, task2, followup = 'openspec:task:TASK-A-001', 'openspec:task:TASK-A-002', 'openspec:followup'
def classify(labels):
    return m.classify_mapping({'id':'SPEC-proof', 'labels':labels})
for labels, kind, ch, tk in [([], 'unmapped', None, None), (['discovery'], 'unmapped', None, None),
                            ([change,task], 'mapped','alpha','TASK-A-001'),
                            ([followup,change], 'followup','alpha',None)]:
    got = classify(labels)
    assert (got.kind,got.change,got.task,got.diagnostics)==(kind,ch,tk,())
for labels, code, scope in [([change], 'incomplete-label-pair', ('alpha',)),
                            ([task], 'incomplete-label-pair', ()),
                            ([change,other,task], 'duplicate-change-labels', ('alpha','beta')),
                            ([change,task,task2], 'duplicate-task-labels', ('alpha',)),
                            ([change,change,task], 'duplicate-change-labels', ('alpha',)),
                            ([change,task,task], 'duplicate-task-labels', ('alpha',)),
                            ([change,followup,task], 'followup-with-task', ('alpha',)),
                            ([followup], 'followup-without-change', ()),
                            ([change,followup,followup], 'duplicate-followup-labels', ('alpha',)),
                            (['openspec:change:',task], 'empty-mapping-label', ())]:
    before = list(labels)
    got = classify(labels)
    assert got.kind == 'invalid'
    diagnostic = next(d for d in got.diagnostics if d.code==code)
    assert diagnostic.changes==scope and diagnostic.repository_wide==(not bool(scope))
    assert diagnostic.bead_ids==('SPEC-proof',)
    assert m.mapping({'id':'SPEC-proof','labels':labels})==(None,None)
    assert labels==before, 'classifier changed input'
for labels in [{}, '', False, {'malformed':'labels'}, [True], ['discovery',None]]:
    got=classify(labels)
    assert got.kind=='invalid' and got.diagnostics[0].repository_wide
# Validation accepts a real non-task follow-up and still rejects every malformed
# association, preserving strict audit behavior without inventing a task.
issues=[{'id':'SPEC-follow','labels':[change,followup]}, {'id':'SPEC-bad','labels':[change]}]
with patch.object(m,'task_map',return_value=({},[])), patch.object(m,'beads',return_value=issues), patch.object(m,'limbo_warnings',return_value=[]):
    tasks,returned,problems,warnings=m.validate()
    assert returned==issues and problems==['SPEC-bad has incomplete OpenSpec labels']
print('Bead mapping: mapped/followup/unmapped, inherited duplicates, illegal combinations and typed scoped diagnostics passed')
PY
