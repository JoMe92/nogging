#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
source = pathlib.Path(sys.argv[1])
m = SourceFileLoader('scoped_mapping', str(source/'scripts/nogg')).load_module()
def bead(bid, change, task=None, status='closed'):
    labels = ['openspec:change:'+change] if change else []
    if task: labels.append('openspec:task:'+task)
    return dict(id=bid, labels=labels, status=status, closed_at='2026-01-01T00:00:00Z')
def audit(tasks, issues, duplicates=()):
    with patch.object(m,'task_map',return_value=(tasks,list(duplicates))), patch.object(m,'beads',return_value=issues), patch.object(m,'limbo_warnings',return_value=[]):
        return m.mapping_audit()
tasks = {'TASK-A-001':dict(change='alpha',file=None), 'TASK-B-001':dict(change='beta',file=None)}
# Task-only mappings are attributable when their approved definition is unique.
result = audit(tasks,[bead('SPEC-only',None,'TASK-A-001')])
assert result[2][0].changes==('alpha',) and not result[2][0].repository_wide
# A mislabeled task affects both its declared and approved change owner.
result = audit(tasks,[bead('SPEC-wrong','beta','TASK-A-001')])
assert result[2][0].changes==('alpha','beta')
result = audit(tasks,[bead('SPEC-a','alpha','TASK-A-001'),bead('SPEC-dup','beta','TASK-A-001')])
assert next(d for d in result[2] if d.code=='duplicate-mapped-beads').changes==('alpha','beta')
for issues,duplicates in [([bead('SPEC-unknown',None,'TASK-NONE')],()),
                           ([bead('SPEC-same','alpha','TASK-A-001'),bead('SPEC-same','beta','TASK-B-001')],()),
                           ([],('TASK-A-001',))]:
    result = audit(tasks,issues,duplicates)
    try: m.reconciliation_plan(*result[:3])
    except m.AuditError: pass
    else: raise AssertionError('repository-wide ambiguity allowed a plan')
with tempfile.TemporaryDirectory(prefix='nogg scoped mapping ') as td:
    root=pathlib.Path(td); config=root/'.nogging/config.json';config.parent.mkdir()
    config.write_bytes((source/'.nogging/config.json').read_bytes())
    subprocess.run(['git','init','-q',str(root)],check=True)
    (root/'.gitignore').write_text('.nogging/state/\n.nogging/locks/\nbin/\ntracker.json\n')
    files={}
    for change,lines in [('alpha','- [ ] TASK-A-001 Alpha\n'),('beta','- [ ] TASK-B-001 Beta\n- [ ] TASK-B-002 Beta next\n')]:
        path=root/'openspec/changes'/change/'tasks.md';path.parent.mkdir(parents=True);path.write_text(lines);files[change]=path
    subprocess.run(['git','-C',str(root),'add','.'],check=True)
    subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','seed'],check=True)
    tracker=root/'tracker.json'
    issues=[bead('SPEC-bad','alpha'),bead('SPEC-a','alpha','TASK-A-001'),bead('SPEC-b','beta','TASK-B-001')]
    tracker.write_text(json.dumps(issues))
    binaries=root/'bin';binaries.mkdir();stub=binaries/'bd'
    stub.write_text('''#!/usr/bin/env python3
import os,json,sys,pathlib
p=pathlib.Path(os.environ['TRACKER']);issues=json.loads(p.read_text())
if sys.argv[1]=='list':print(json.dumps(issues))
elif sys.argv[1]=='create':
 labels=sys.argv[sys.argv.index('--labels')+1].split(',')
 issues.append(dict(id='SPEC-created',labels=labels,status='open'));p.write_text(json.dumps(issues))
else:sys.exit(2)
''');stub.chmod(0o755)
    env={**os.environ,'NOGGING_ROOT':str(root),'TRACKER':str(tracker),'PATH':str(binaries)+os.pathsep+os.environ['PATH']}
    def nogg(*args):
        return subprocess.run([str(source/'scripts/nogg'),*args],env=env,text=True,capture_output=True)
    def head(): return subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True)
    def strict_problems():
        code = 'from importlib.machinery import SourceFileLoader; import json,sys; m=SourceFileLoader("audit",sys.argv[1]).load_module(); print(json.dumps(m.validate()[2]))'
        return json.loads(subprocess.check_output([sys.executable,'-c',code,str(source/'scripts/nogg')],env=env,text=True))
    assert nogg('materialize','alpha').returncode!=0
    before=len(json.loads(tracker.read_text()))
    assert nogg('materialize','beta').returncode==0
    assert len(json.loads(tracker.read_text()))==before+1
    assert nogg('materialize','beta').returncode==0
    assert len(json.loads(tracker.read_text()))==before+1
    assert strict_problems()==['SPEC-bad has incomplete OpenSpec labels']
    assert nogg('validate').returncode!=0, 'strict validation hid malformed alpha'
    state=root/'.nogging/state';state.mkdir(exist_ok=True)
    previous='{"at":"2020-01-01T00:00:00Z","branch":"master"}\n'
    (state/'last-success.json').write_text(previous)
    partial=nogg('sync','--now')
    assert partial.returncode==3 and 'quarantined alpha' in partial.stderr, partial.stderr
    health_path=state/'sync-mapping-health.json'
    health=json.loads(health_path.read_text())
    assert set(health['failures'])=={'alpha'}
    assert health['last_partial']['skipped_changes']==['alpha']
    assert health['last_partial']['processed_changes']==['beta']
    assert health['failures']['alpha']['diagnostics'][0]['bead_ids']==['SPEC-bad']
    assert not (state/'sync-failure.json').exists(), 'partial pass scheduled a global retry'
    diagnostic=nogg('doctor').stdout
    assert 'last complete sync: 2020-01-01T00:00:00Z' in diagnostic
    assert 'last partial sync:' in diagnostic
    assert 'mapping quarantine alpha: SPEC-bad;' in diagnostic and 'first seen' in diagnostic
    assert '[x] TASK-B-001' in files['beta'].read_text()
    assert '[ ] TASK-A-001' in files['alpha'].read_text()
    assert not (files['alpha'].parent/'execution-log.md').exists()
    assert (files['beta'].parent/'execution-log.md').read_text().count('<!-- nogg:SPEC-b:')==1
    assert (state/'last-success.json').read_text()==previous
    mirrored=head();assert nogg('sync','--now').returncode==3 and head()==mirrored
    assert json.loads(health_path.read_text())['failures']['alpha']['first_seen']==health['failures']['alpha']['first_seen']
    # Repair the fixture explicitly; no production code ever relabels it.
    issues=json.loads(tracker.read_text());issues[0]['labels'].append('openspec:followup');tracker.write_text(json.dumps(issues))
    assert nogg('sync','--now').returncode==0
    assert '[x] TASK-A-001' in files['alpha'].read_text()
    assert strict_problems()==[], 'strict mapping audit still reports repaired scope'
    repaired=json.loads(health_path.read_text())
    assert repaired['failures']=={} and repaired['last_partial']['skipped_changes']==['alpha']
    assert (state/'last-success.json').read_text()!=previous
    assert 'historical; no active scoped mapping failures' in nogg('doctor').stdout
    assert repaired['last_partial']['diagnostics'][0]['bead_ids']==['SPEC-bad']
    original_health=health_path.read_bytes();health_path.write_text('{broken health')
    frozen=head();assert nogg('sync','--now').returncode==1 and head()==frozen
    assert health_path.read_text()=='{broken health', 'sync overwrote corrupt health'
    health_path.write_bytes(original_health)
    assert 'nogg:SPEC-bad:' not in (files['alpha'].parent/'execution-log.md').read_text()
    assert len(json.loads(tracker.read_text()))==before+1, 'followup invented a mapped Bead'
    assert files['alpha'].read_text().count('TASK-')==1, 'followup invented a checkbox'
    # Conflicting tracker identities and unreadable tracker responses prevent
    # every reconciliation write, even to an otherwise valid change.
    for corrupted in [issues+[bead('SPEC-b','alpha','TASK-A-001')], {'issues':'unreadable'}]:
        tracker.write_text(json.dumps(corrupted));frozen=head()
        assert nogg('sync','--now').returncode!=0 and head()==frozen
        assert nogg('materialize','beta').returncode!=0
print('Scoped mappings: target-only materialize, whole-change quarantine, independent mirror/idempotency, strict audit, repair and global fail-closed passed')
PY
