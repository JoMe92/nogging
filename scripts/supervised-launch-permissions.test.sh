#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from pathlib import Path
import copy,json,os,shutil,subprocess,sys,tempfile
source=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='nogg scoped permissions ') as td:
    root=Path(td);(root/'.nogging').mkdir();(root/'.claude').mkdir()
    shutil.copy2(source/'.nogging/config.json',root/'.nogging/config.json')
    subprocess.run(['git','init','-q',str(root)],check=True)
    os.environ['NOGGING_ROOT']=str(root)
    os.environ['CLAUDE_CONFIG_DIR']=str(root/'user-claude')
    m=SourceFileLoader('scoped_permissions',str(source/'scripts/nogg')).load_module()
    original={'permissions':{'defaultMode':'auto','allow':['Read(src/**)','Bash(npm test)','Read(src/**)'],
                            'ask':['Bash(git push:*)'],'deny':['Bash(codex:*)']},
              'autoMode':{'classifyAllShell':True},'env':{'USER_SETTING':'preserve'},
              'hooks':{'Notification':[{'hooks':[{'type':'command','command':'echo user'}]}]}}
    snapshot=copy.deepcopy(original)
    expected=[f'Bash(./scripts/nogg session {cmd}:*)' for cmd in ['launch','send','kickoff','stop','list','log','watch']]
    for role in ['lead','orchestrator']:
        merged=m.merge_supervised_launch_permissions(original,role)
        assert original==snapshot and merged is not original
        assert merged['permissions']['allow']==original['permissions']['allow']+expected
        assert merged['permissions']['deny']==original['permissions']['deny']
        assert merged['permissions']['ask']==original['permissions']['ask']
        assert merged['permissions']['defaultMode']=='auto' and merged['autoMode']==original['autoMode']
        assert merged['hooks']==original['hooks'] and merged['env']==original['env']
        assert m.merge_supervised_launch_permissions(merged,role)==merged
    for role in ['planning','specialist:backend-engineer']:
        assert m.merge_supervised_launch_permissions(original,role)==original
    assert all('claude' not in rule and 'codex' not in rule and 'systemctl' not in rule for rule in expected)
    assert all(rule.startswith('Bash(./scripts/nogg session ') for rule in expected)
    settings=root/'.claude/settings.json';settings.write_text(json.dumps(original))
    notes=m.supervised_launch_permission_notes()
    assert any('external Claude parent lacks scoped' in n and expected[0] in n and 'deliberately' in n for n in notes)
    settings.write_text(json.dumps(m.merge_supervised_launch_permissions(original,'orchestrator')))
    assert not any('external Claude parent lacks' in n for n in m.supervised_launch_permission_notes())
    user=root/'user-claude/settings.json';user.parent.mkdir();user.write_text(json.dumps({'autoMode':{'classifyAllShell':True},'unrelated':'keep'}))
    before=user.read_bytes();notes=m.supervised_launch_permission_notes()
    assert any('classifyAllShell=true' in n and 'unsupported' in n and 'directly' in n for n in notes)
    assert user.read_bytes()==before
    sdir=m.sessions_dir();sdir.mkdir(parents=True,exist_ok=True)
    effective=sdir/'parent.settings.json';effective.write_text(json.dumps(original))
    record={'name':'parent','role':'lead','agent':'claude','state':'running','effective_settings_path':str(effective)}
    m.write_session(sdir/'parent.json',record)
    assert any('session parent: scoped child-control permissions missing' in n for n in m.supervised_launch_permission_notes())
    effective.write_text(json.dumps(m.merge_supervised_launch_permissions(original,'lead')))
    assert not any('session parent: scoped child-control permissions missing' in n for n in m.supervised_launch_permission_notes())
    # The installer merges named hooks, preserving the parent's chosen mode,
    # allow/ask/deny lists and classifier configuration on init and update.
    if shutil.which('node') is None:
        print('SKIP installer preservation: node not on PATH')
    for operation in (['init','update'] if shutil.which('node') else []):
        subprocess.run(['node',str(source/'bin/cli.js'),operation,'--no-beads','--no-systemd','--no-hooks'],cwd=root,check=True,stdout=subprocess.DEVNULL)
        actual=json.loads(settings.read_text())
        assert actual['permissions']==m.merge_supervised_launch_permissions(original,'orchestrator')['permissions']
        assert actual['autoMode']==original['autoMode']
        assert actual['env']==original['env']
    print('Scoped parent permissions: exact commands, role scope, preservation, idempotence, missing-rule/unsupported-auto notes, installer preservation passed')
PY
