#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
from pathlib import Path
import json,sys,tempfile
m=SourceFileLoader('sync_health',str(Path(sys.argv[1])/'scripts/nogg')).load_module()
with tempfile.TemporaryDirectory(prefix='nogg sync health ') as td:
    state=Path(td);health_path=state/'sync-mapping-health.json'
    previous={'at':'2020-01-01T00:00:00Z','branch':'earlier'}
    (state/'last-success.json').write_text(json.dumps(previous))
    a=m.MappingDiagnostic('incomplete-label-pair','SPEC-a has incomplete OpenSpec labels',('SPEC-a',),('alpha',))
    b=m.MappingDiagnostic('missing-task','SPEC-b maps missing task TASK-B-404',('SPEC-b',),('beta',),('TASK-B-404',))
    with patch.object(m,'STATE',state),patch.object(m,'MAPPING_HEALTH',health_path),patch.object(m,'now',side_effect=['2026-01-01T00:00:00Z','2026-01-01T00:00:10Z','2026-01-01T00:00:20Z']):
        first=m.record_mapping_health('feature/proof',[a,b],{'gamma':[]})
        second=m.record_mapping_health('feature/proof',[b],{'alpha':[],'gamma':[]})
        assert set(second['failures'])=={'beta'}, 'repair erased unresolved scope or retained resolved scope'
        assert second['failures']['beta']['first_seen']==first['failures']['beta']['first_seen']
        assert second['failures']['beta']['last_seen']!=first['failures']['beta']['last_seen']
        assert second['last_partial']['skipped_changes']==['beta']
        assert m.read_last_success()==previous, 'partial pass changed complete success'
        lines='\n'.join(m.mapping_health_lines())
        assert 'last complete sync: 2020-01-01' in lines and 'last partial sync: 2026-01-01T00:00:10Z' in lines
        assert 'mapping quarantine beta: SPEC-b;' in lines and 'first seen' in lines and 'last seen' in lines
        complete=m.record_mapping_health('feature/proof',[],{'alpha':[],'beta':[],'gamma':[]})
        assert complete['failures']=={} and complete['last_partial']==second['last_partial']
        assert complete['last_partial']['diagnostics'][0]['bead_ids']==['SPEC-b']
        assert complete['last_partial']['diagnostics'][0]['reason']=='SPEC-b maps missing task TASK-B-404'
        assert 'historical; no active scoped mapping failures' in '\n'.join(m.mapping_health_lines())
    frozen=health_path.read_bytes()
    with patch.object(m.os,'replace',side_effect=OSError('simulated interruption')):
        try:m.atomic_json_state(health_path,{'uncommitted':'replacement'})
        except OSError:pass
        else:raise AssertionError('interruption was hidden')
    assert health_path.read_bytes()==frozen and not list(state.glob('*.tmp-*'))
    for damaged in ['{broken',json.dumps({'failures':{'beta':'not an entry'}}),json.dumps({'last_partial':{'at':True}})]:
        health_path.write_text(damaged)
        with patch.object(m,'MAPPING_HEALTH',health_path):
            try:m.read_mapping_health()
            except m.AuditError:pass
            else:raise AssertionError('damaged health was accepted')
        assert health_path.read_text()==damaged
print('Sync health: distinct complete/partial history, selective scope repair, ages/IDs, atomic interruption and corrupt-state refusal passed')
PY
