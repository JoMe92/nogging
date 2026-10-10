#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
root = Path(sys.argv[1])
m = SourceFileLoader('nogg_agr_test', str(root / 'scripts/nogg')).load_module()
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    main, linked, home = tmp/'main', tmp/'linked', tmp/'home'
    home.mkdir()
    subprocess.run(['git','init','-q',str(main)],check=True)
    subprocess.run(['git','-C',str(main),'-c','user.name=Test','-c','user.email=test@example.com','commit','--allow-empty','-qm','fixture'],check=True)
    subprocess.run(['git','-C',str(main),'worktree','add','-qb','linked',str(linked)],check=True)
    (linked/'scripts/hooks').mkdir(parents=True)
    for rel in ('scripts/nogg','scripts/hooks/agy-guard'):
        shutil.copy2(root/rel,linked/rel)
    (linked/'.agents').mkdir()
    hooks = linked/'.agents/hooks.json'
    hooks.write_text((root/'templates/antigravity/hooks.json').read_text())
    settings = home/'.gemini/antigravity-cli/settings.json'
    settings.parent.mkdir(parents=True)
    original = {'trustedWorkspaces':['/keep'], 'toolPermission':'request-review', 'unrelated':{'a':[1,2]}}
    settings.write_text(json.dumps(original)); settings.chmod(0o400)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('NOGG_','NOGGING_'))}
    env['HOME'] = str(home)
    def refused(fn, match):
        try: fn()
        except RuntimeError as e: assert match in str(e), str(e)
        else: raise AssertionError('expected refusal: '+match)
    with patch.dict(os.environ,env,clear=True):
        assert m.resolve_agent('agy') == 'antigravity'
        assert m.resolve_agent('antigravity') == 'antigravity'
        with patch.dict(m.CFG, {'session_agent':'agy'}):
            assert m.resolve_agent(None) == 'antigravity'
        for level in ('restricted','trusted'):
            path, label, prompt = m.resolved_launch_pair(level,None,False,'antigravity')
            assert label == level and path.name == level+'.agy.toml'
            assert m.load_antigravity_spec(path)['approval'] == ('ask' if level == 'restricted' else 'auto')
        for bad in ('x.json','x.codex.toml','x.pi.toml'):
            refused(lambda: m.resolve_antigravity_profile(bad,False), '.agy.toml')
        profile = tmp/'custom.agy.toml'
        profile.write_text('mode = "plan"\napproval = "ask"\nsandbox = "false"\nmodel = "test-model"\n')
        assert m.load_antigravity_spec(profile)['model'] == 'test-model'
        profile.write_text('sandbox = false # off\nmodel = "test#model" # keep hash\n')
        assert m.load_antigravity_spec(profile)['model'] == 'test#model'
        for text in ('mode = "wrong"','sandbox = "true"','approval = "never"','other = "x"','model = ""','mode = "plan"\nmode = "plan"'):
            profile.write_text(text)
            refused(lambda: m.load_antigravity_spec(profile),'Antigravity')
        m.prepare_antigravity_trust(linked,'ask')
        merged = json.loads(settings.read_text())
        assert merged == {**original,'trustedWorkspaces':['/keep',str(linked)]}
        assert settings.stat().st_mode & 0o777 == 0o400
        m.prepare_antigravity_trust(linked,'ask')
        assert json.loads(settings.read_text()) == merged
        settings.chmod(0o600)
        for permission in ('always-proceed','strict','unknown',None):
            settings.write_text(json.dumps({**original,'toolPermission':permission}))
            before = settings.read_bytes()
            refused(lambda: m.prepare_antigravity_trust(linked,'ask'),'request-review')
            assert settings.read_bytes() == before
        settings.write_text(json.dumps(original))
        with patch.object(m.os,'replace',side_effect=PermissionError('unwritable trust')):
            refused(lambda: m.prepare_antigravity_trust(linked,'ask'),'unwritable trust')
        assert json.loads(settings.read_text()) == original
        assert not list(settings.parent.glob('.nogging-settings-*'))
        # A real unwritable settings directory fails before replacement or start.
        settings.parent.chmod(0o500)
        try:
            refused(lambda: m.prepare_antigravity_trust(linked,'ask'),'trust preparation refused')
        finally:
            settings.parent.chmod(0o700)
        assert json.loads(settings.read_text()) == original
        destination = tmp/'settings-target.json'
        settings.rename(destination); settings.symlink_to(destination)
        refused(lambda: m.prepare_antigravity_trust(linked,'ask'),'symlink')
        settings.unlink(); destination.rename(settings)
        for text in ('{','[]','{"trustedWorkspaces":true}'):
            settings.write_text(text)
            refused(lambda: m.prepare_antigravity_trust(linked,'ask'),'trust preparation refused')
            assert settings.read_text() == text
        settings.write_text(json.dumps(original))
        for value in ({}, {'nogging-guard':{'enabled':False}}, {'nogging-guard':{'PreToolUse':[]}}):
            hooks.write_text(json.dumps(value))
            before = settings.read_bytes()
            refused(lambda: m.prepare_antigravity_trust(linked,'ask'),'guard')
            assert settings.read_bytes() == before
        hooks.write_text((root/'templates/antigravity/hooks.json').read_text())
        guard = linked/'scripts/hooks/agy-guard'
        guard.rename(guard.with_suffix('.saved'))
        refused(lambda: m.prepare_antigravity_trust(linked,'ask'),'guard')
        guard.with_suffix('.saved').rename(guard)
        # Independent concurrent merges must retain both explicitly selected roots.
        second = tmp/'second'
        subprocess.run(['git','-C',str(main),'worktree','add','-qb','second',str(second)],check=True)
        shutil.copytree(linked/'scripts',second/'scripts')
        shutil.copytree(linked/'.agents',second/'.agents')
        code = ('from importlib.machinery import SourceFileLoader; import sys; '
                'm=SourceFileLoader("trust_test",sys.argv[1]).load_module(); '
                'm.prepare_antigravity_trust(sys.argv[2],"ask")')
        settings.unlink()
        children = [subprocess.Popen([sys.executable,'-c',code,str(root/'scripts/nogg'),str(p)],env=env)
                    for p in (linked,second,linked,second)]
        assert all(child.wait() == 0 for child in children)
        assert set(json.loads(settings.read_text())['trustedWorkspaces']) == {str(linked),str(second)}
        assert settings.stat().st_mode & 0o777 == 0o600
        # End-to-end command construction and alias metadata, without tmux/Beads writes.
        calls = []
        m.CFG = {**m.CFG, 'session_state_dir':str(tmp/'sessions')}
        def tmux(*args,**kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args,0,'','')
        with patch.object(m,'bead_exists',return_value=True), patch.object(m,'unmet_dependencies',return_value=[]), patch.object(m,'tmux',side_effect=tmux), patch.object(m,'tmux_sessions',return_value=set()), patch.object(m,'tmux_has_session',return_value=False):
            # Missing guard and failed trust must cause zero tmux interactions.
            hooks.unlink()
            refused(lambda: m.session_launch('lead','SPEC-test',str(linked),False,None,agent='agy'),'guard')
            assert calls == [] and not (tmp/'sessions').exists()
            hooks.write_text((root/'templates/antigravity/hooks.json').read_text())
            with patch.object(m.os,'replace',side_effect=PermissionError('unwritable trust')):
                refused(lambda: m.session_launch('lead','SPEC-test',str(linked),False,None,agent='agy'),'unwritable trust')
            assert calls == [] and not (tmp/'sessions').exists()
            restricted = tmp/'restricted.agy.toml'
            restricted.write_text('approval = "auto"\n')
            refused(lambda: m.session_launch('lead','SPEC-test',str(linked),False,None,profile=str(restricted),agent='agy'),'requires ask')
            assert calls == []
            profile.write_text('model = "test-model"\napproval = "auto"\n')
            m.session_launch('lead','SPEC-test',str(linked),True,None,profile=str(profile),agent='agy')
            record = json.loads(next((tmp/'sessions').glob('*.json')).read_text())
            assert record['agent'] == 'antigravity' and record['read_only']
            command = record['command']
            assert command[command.index('--model')+1] == 'test-model'
            assert '--read-only' in command
        # Execute real wrapper against a fake runtime; assert argv and guard context.
        bindir = tmp/'bin'; bindir.mkdir()
        fake = bindir/'agy'
        fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["ARGV_OUT"]).write_text(json.dumps({"args":sys.argv[1:],"authority":os.environ.get("NOGG_SESSION_AUTHORITY"),"cwd":os.environ.get("NOGG_SESSION_WORKING_DIR"),"update":os.environ.get("AGY_CLI_DISABLE_AUTO_UPDATE")}))\n')
        fake.chmod(0o755)
        out = tmp/'argv.json'
        runenv = {**env,'PATH':str(bindir)+os.pathsep+env['PATH'],'ARGV_OUT':str(out)}
        base = [str(root/'scripts/session-launch'),'--agent','agy','--cwd',str(linked),'--model','test-model']
        for approval,authority in [('ask','restricted'),('auto','trusted')]:
            subprocess.run(base+['--approval',approval,'--read-only'],env=runenv,check=True)
            actual = json.loads(out.read_text())
            assert actual['authority'] == authority and actual['cwd'] == str(linked)
            expected = ['--mode','plan']
            if approval == 'auto': expected += ['--dangerously-skip-permissions']
            assert actual['args'] == expected+['--model','test-model']
            assert actual['update'] == 'true'
            out.unlink()
        settings.write_text(json.dumps({**original,'toolPermission':'always-proceed'}))
        before = settings.read_bytes()
        result = subprocess.run(base+['--approval','ask'],env=runenv,capture_output=True,text=True)
        assert result.returncode != 0 and not out.exists() and 'request-review' in result.stderr
        assert settings.read_bytes() == before
        subprocess.run(base+['--approval','auto'],env=runenv,check=True)
        assert json.loads(settings.read_text())['toolPermission'] == 'always-proceed'
        out.unlink()
        hooks.unlink()
        result = subprocess.run(base,env=runenv,capture_output=True,text=True)
        assert result.returncode != 0 and not out.exists() and 'guard' in result.stderr
        contract = json.loads(subprocess.check_output([str(root/'scripts/session-launch'),'--contract']))
        assert 'antigravity' in contract['agents'] and contract['options']['--mode'] == 1
print('Antigravity profiles, trust refusals, alias metadata and wrapper forwarding passed')
PY
