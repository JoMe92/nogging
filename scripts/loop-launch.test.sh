#!/usr/bin/env bash
# TASK-SCL-006: launch-mode loop runs through real sessions, with stub agents on
# a private tmux socket and a test clock (design Decisions 4, 6 and 7).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v tmux >/dev/null; then
  printf 'SKIP: loop launch runs (tmux unavailable)\n'
  exit 0
fi
if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'SKIP: loop launch runs (host denies Linux user/mount namespaces)\n'
  exit 0
fi
python3 - "$root" <<'PY'
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch
import hashlib, json, os, shutil, subprocess, sys, tempfile, time, uuid

source = Path(sys.argv[1]).resolve()
for key in [key for key in os.environ if key.startswith('NOGG_') or key == 'NOGGING_ROOT']:
    del os.environ[key]
os.environ['NOGG_LAUNCH_SETTLE_SECONDS'] = '0.25'
UTC = timezone.utc
SOCKET = 'nogg-loop-' + uuid.uuid4().hex[:12]

with tempfile.TemporaryDirectory(prefix='nogg loop launch ') as td:
    scratch = Path(td)
    root = scratch / 'main'
    root.mkdir()
    for path in ('.pi/extensions', '.codex/rules', '.nogging/launch-profiles', '.nogging/launch-prompts'):
        shutil.copytree(source / path, root / path)
    shutil.copy2(source / '.nogging/model-selection.json', root / '.nogging/model-selection.json')
    (root / 'openspec').mkdir()
    (root / 'openspec/project.md').write_text('# fixture\n')
    subprocess.run(['bash', str(source / 'scripts/lib/test-fixture-config.sh'),
                    str(source / '.nogging/config.json'), str(root / '.nogging/config.json')], check=True)
    config = json.loads((root / '.nogging/config.json').read_text())
    config.update(session_tmux_socket=SOCKET, session_stop_grace_seconds=0.1,
                  session_startup_timeout_seconds=6, session_delivery_timeout_seconds=4,
                  usage_gate={'enabled': False}, loops_file='.nogging/loops.json')
    (root / '.nogging/config.json').write_text(json.dumps(config, indent=2))
    (root / 'scripts').mkdir()
    for name in ('session-launch', 'session-log-writer', 'openspec-sandbox', 'nogg'):
        shutil.copy2(source / 'scripts' / name, root / 'scripts' / name)
    (root / '.gitignore').write_text('.nogging/state/\n.nogging/locks/\n')
    subprocess.run(['git', 'init', '-q', '-b', 'develop', str(root)], check=True)
    subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-qm', 'seed'], check=True)

    # The stub runtime reads its behaviour from a file, so a test changes what a
    # running agent shows: `ready` paints the composer, `blind` never does,
    # `busy` shows a running turn and `exit` ends the agent.
    agents, plain = scratch / 'agents', scratch / 'no-agents'
    agents.mkdir(); plain.mkdir()
    behaviour = scratch / 'behaviour'
    runtime = agents / 'runtime.py'
    runtime.write_text(f'''#!/usr/bin/env python3
import os, pathlib, select, sys, termios, tty
if "--help" in sys.argv or "--version" in sys.argv:
    print("stub runtime"); sys.exit(0)
tty.setraw(0)
RULE = "─" * 60
draft, shown = "", None
def paint(mode):
    body = ""
    if mode == "ready":
        body = RULE + "\\r\\n❯ " + draft.rstrip("\\n").replace("\\n", "\\r\\n  ") + "\\r\\n" + RULE + "\\r\\n   ⏵⏵ bypass permissions on\\r\\n"
    elif mode == "busy":
        body = "✻ Working… (esc to interrupt)\\r\\n"
    sys.stdout.write("\\x1b[?2004h\\x1b[2J\\x1b[16;1H" + body)
    sys.stdout.flush()
while True:
    mode = pathlib.Path({str(behaviour)!r}).read_text().strip()
    if mode == "exit":
        sys.exit(0)
    if select.select([0], [], [], 0.05)[0]:
        data = os.read(0, 65536).decode(errors="replace")
        if data == "\\x03":
            sys.exit(0)
        if data == "\\r":
            draft = ""
        else:
            draft += data.replace("\\x1b[200~", "").replace("\\x1b[201~", "")
        shown = None
    if (mode, draft) != shown:
        shown = (mode, draft)
        paint(mode)
''')
    runtime.chmod(0o755)
    for agent in ('claude', 'codex', 'pi', 'agy'):
        stub = agents / agent
        stub.write_text(f'#!/bin/sh\nexec python3 "{runtime}" "$@"\n')
        stub.chmod(0o755)
    base_path = os.environ['PATH']
    with_agents = os.pathsep.join((str(agents), base_path))
    # A PATH that still has every tool but no agent binary.
    without_agents = os.pathsep.join(entry for entry in base_path.split(os.pathsep)
                                     if not (Path(entry) / 'claude').exists()
                                     and not (Path(entry) / 'codex').exists())
    os.environ['PATH'] = with_agents
    os.environ['NOGGING_ROOT'] = str(root)
    os.chdir(root)

    m = SourceFileLoader('nogg_under_test', str(source / 'scripts/nogg')).load_module()
    sys.path.insert(0, str(source / 'scripts/lib'))
    import loop_config, loop_runner, loop_state

    defs = root / '.nogging/loops.json'
    clock = [datetime(2026, 1, 1, 0, 6, tzinfo=UTC)]
    usage_calls = []

    def admit(agent, model, options):
        usage_calls.append((agent, model))
        return True, None, {'decision': 'admitted', 'windows': []}

    def define(loops, scheduler=None):
        raw = {'schema_version': 1, 'timezone': 'UTC', 'loops': loops}
        if scheduler:
            raw['scheduler'] = scheduler
        defs.write_text(json.dumps(raw))
        loaded = loop_config.load(defs)
        for name in loops:
            prompt = root / f'.nogging/loops/{name}.md'
            prompt.parent.mkdir(parents=True, exist_ok=True)
            prompt.write_text(f'Inspect the queue for {name}.\n')
            loop_state.approve(root, defs, loaded, name, at='2026-01-01T00:00:00Z', user='operator')
        runner = m.loop_runner_for_main()
        runner.usage = admit
        runner.now = lambda: clock[0]
        return runner

    def launch_loop(schedule=None, **run):
        return {'schedule': schedule or {'at': ['00:05'], 'grace': 1200},
                'run': {'mode': 'launch', 'agent': 'claude', 'tier': 'routine', **run}}

    def at(minute):
        clock[0] = datetime(2026, 1, 1, 0, 0, tzinfo=UTC) + timedelta(minutes=minute)

    def events(name=None):
        path = loop_runner.event_path(root)
        rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [row for row in rows if name is None or row['loop'] == name]

    def kinds(name):
        return [row['event'] for row in events(name)]

    def item(name):
        return loop_state.read_state(root)['loops'].get(name, {})

    def live():
        result = subprocess.run(['tmux', '-L', SOCKET, 'list-sessions', '-F', '#S'],
                                capture_output=True, text=True)
        return set(result.stdout.split()) if result.returncode == 0 else set()

    def records(run_prefix):
        return [rec for _, rec in m.session_records() if str(rec.get('loop_run_id', '')).startswith(run_prefix)]

    def reset():
        """Each case starts from no state, no sessions and a ready agent."""
        for _, rec in m.session_records():
            if rec.get('state') in m.SESSION_ACTIVE_STATES:
                m.session_stop(rec['name'], 'test reset')
            if rec.get('state') != 'retired':
                m.session_cleanup(rec['name'])
        shutil.rmtree(root / '.nogging/state/sessions', ignore_errors=True)
        shutil.rmtree(root / '.nogging/state/loops', ignore_errors=True)
        shutil.rmtree(root / '.nogging/loops', ignore_errors=True)
        usage_calls.clear()
        behaviour.write_text('ready')
        os.environ['PATH'] = with_agents

    def wait_ready(session):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            rec = m.load_session(session)[1]
            if m.classify_session(rec)[0] == 'idle':
                return
            time.sleep(0.05)
        raise AssertionError(f'{session} never became idle')

    try:
        # --- a run starts, completes after two idle ticks and is retired ------
        reset()
        runner = define({'scan': launch_loop()})
        at(6); runner.tick()
        assert kinds('scan') == ['starting', 'started'], events('scan')
        started = events('scan')[-1]
        session = started['session']
        assert session.startswith('sf-loop-scan-') and started['run_id'] == 'scan-20260101T000500Z', started
        assert started['agent'] == 'claude' and started['tier'] == 'routine', started
        rec = m.load_session(session)[1]
        assert rec['role'] == 'loop' and rec['loop_name'] == 'scan' and rec['loop_run_id'] == started['run_id']
        assert rec['profile'] == 'restricted' and rec['selection_tier'] == 'routine', rec
        assert rec['working_dir'] == str(root.resolve()) and rec['openspec_readonly'] is True
        assert '--ignore-usage-gate' not in rec['command']
        expected = f"[nogg loop scan run {started['run_id']}]\nInspect the queue for scan.\n"
        assert rec['kickoff_delivery']['status'] == 'submitted', rec['kickoff_delivery']
        assert rec['kickoff_delivery']['message_sha256'] == hashlib.sha256(expected.encode()).hexdigest()
        assert usage_calls == [('claude', rec['requested_model'])], usage_calls
        assert rec['requested_model'], 'the pre-launch observation must use the tier model'
        assert item('scan')['active_run']['session'] == session
        wait_ready(session)
        at(7); runner.tick()
        assert kinds('scan')[-1] == 'started' and session in live(), 'one idle tick must not complete a run'
        at(8); runner.tick()
        done = events('scan')[-1]
        assert done['event'] == 'completed' and done['session'] == session, done
        assert Path(done['log_path']).exists() and '.archived-' in done['log_path'], done
        assert session not in live() and m.load_session(session)[1]['state'] == 'retired'
        state = item('scan')
        assert state['active_run'] is None and state['last_outcome'] == 'completed'
        assert 'Inspect the queue' not in loop_runner.event_path(root).read_text(), 'a prompt reached the run log'

        # --- a refused kickoff leaves no session and is retried ---------------
        reset()
        runner = define({'scan': launch_loop()})
        behaviour.write_text('blind')
        at(6); runner.tick()
        assert kinds('scan') == ['starting', 'retry-scheduled'], kinds('scan')
        assert events('scan')[-1]['attempt'] == 1 and events('scan')[-1]['reason']
        attempt = records('scan-')
        assert len(attempt) == 1 and attempt[0]['state'] == 'retired', attempt
        assert not live(), 'a refused kickoff left a session'
        assert item('scan')['active_run'] is None
        behaviour.write_text('ready')
        at(7); runner.tick()
        assert kinds('scan')[-1] == 'retry-scheduled', 'a retry fired before its backoff'
        at(8); runner.tick()
        assert kinds('scan')[-1] == 'started' and events('scan')[-1]['attempt'] == 2, events('scan')[-1]
        assert events('scan')[-1]['run_id'] == 'scan-20260101T000500Z'

        # --- a missing binary is transient, and nothing is left behind --------
        reset()
        runner = define({'scan': launch_loop()})
        os.environ['PATH'] = without_agents
        at(6); runner.tick()
        assert kinds('scan') == ['starting', 'retry-scheduled'], kinds('scan')
        assert 'not found on PATH' in events('scan')[-1]['reason']
        assert not records('scan-') and not live()
        os.environ['PATH'] = with_agents
        at(8); runner.tick()
        assert kinds('scan')[-1] == 'started', kinds('scan')

        # --- a hang past max_runtime is stopped, retired and counted ----------
        reset()
        runner = define({'scan': launch_loop(max_runtime='5m')})
        at(6); runner.tick()
        session = events('scan')[-1]['session']
        behaviour.write_text('busy')
        deadline = time.monotonic() + 5
        while m.classify_session(m.load_session(session)[1])[0] != 'working' and time.monotonic() < deadline:
            time.sleep(0.05)
        at(10); runner.tick()
        assert kinds('scan')[-1] == 'started', 'a working run within max_runtime was touched'
        at(12); runner.tick()
        assert kinds('scan')[-2:] == ['stale', 'stopped-stale'], kinds('scan')
        assert session not in live() and m.load_session(session)[1]['state'] == 'retired'
        assert Path(events('scan')[-1]['log_path']).exists()
        state = item('scan')
        assert state['consecutive_failures'] == 1 and state['last_outcome'] == 'stopped-stale', state

        # --- a session that ends on its own is a failure ----------------------
        reset()
        runner = define({'scan': launch_loop()})
        at(6); runner.tick()
        session = events('scan')[-1]['session']
        behaviour.write_text('exit')
        deadline = time.monotonic() + 5
        while session in live() and time.monotonic() < deadline:
            time.sleep(0.05)
        at(7); runner.tick()
        assert kinds('scan')[-1] == 'failed', kinds('scan')
        assert events('scan')[-1]['session'] == session and 'ended' in events('scan')[-1]['reason']
        assert m.load_session(session)[1]['state'] == 'retired'
        assert item('scan')['consecutive_failures'] == 1

        # --- a gate denial is a hard skip: no retry, tier or agent change -----
        reset()
        runner = define({'scan': launch_loop()})
        runner.usage = lambda *_: (False, 'usage-gate: weekly 91% (loop cap 70%), resets soon',
                                   {'decision': 'denied', 'windows': []})
        at(6); runner.tick()
        assert kinds('scan') == ['skipped'] and 'weekly 91%' in events('scan')[-1]['reason']
        assert not records('scan-') and not item('scan').get('retry')

        # --- so is exit 75 from the normal launch admission -------------------
        reset()
        runner = define({'scan': launch_loop()})
        denial = m.UsageGateDenied('usage gate denied claude launch: weekly 95% exceeds cap 90%')
        with patch.object(m, 'usage_gate_admission', side_effect=denial) as gate:
            at(6); runner.tick()
        assert gate.call_args.args[0] == 'loop', gate.call_args
        assert kinds('scan') == ['starting', 'skipped'], kinds('scan')
        assert events('scan')[-1]['reason'] == 'usage-gate: weekly 95% exceeds cap 90%', events('scan')[-1]
        state = item('scan')
        assert state['active_run'] is None and not state.get('retry') and not state.get('consecutive_failures')
        at(8); runner.tick()
        assert kinds('scan') == ['starting', 'skipped'], 'a denied slot was retried'

        # --- two launch loops under a limit of one ----------------------------
        reset()
        runner = define({'alpha': launch_loop(), 'beta': launch_loop()},
                        scheduler={'max_active_launch_runs': 1})
        at(6); runner.tick()
        assert kinds('alpha')[-1] == 'started'
        assert kinds('beta') == ['deferred'] and events('beta')[-1]['reason'] == 'active-run-limit', events('beta')
        session = events('alpha')[-1]['session']
        wait_ready(session)
        at(7); runner.tick()
        assert kinds('beta') == ['deferred'], 'a deferral is logged once per reason'
        at(8); runner.tick()
        assert kinds('alpha')[-1] == 'completed' and kinds('beta')[-1] == 'started', (kinds('alpha'), kinds('beta'))
        assert events('beta')[-1]['run_id'] == 'beta-20260101T000500Z'

        # --- authority, model and effort reach the launch unchanged -----------
        reset()
        runner = define({'scan': launch_loop(agent='codex', authority='trusted', model='gpt-5.4', effort='low')})
        at(6); runner.tick()
        rec = records('scan-')[0]    # the stub shows no Codex composer; the launch is what matters
        assert (rec['agent'], rec['profile'], rec['requested_model'], rec['reasoning_effort']) == \
            ('codex', 'trusted', 'gpt-5.4', 'low'), rec
        assert usage_calls == [('codex', 'gpt-5.4')], usage_calls

        # --- a permanent refusal is not retried -------------------------------
        reset()
        runner = define({'scan': launch_loop(tier='no-such-tier')})
        at(6); runner.tick()
        assert kinds('scan') == ['failed'], kinds('scan')
        assert 'no-such-tier' in events('scan')[-1]['reason'] and not item('scan').get('retry')
        assert item('scan')['consecutive_failures'] == 1

        reset()
        runner = define({'scan': launch_loop(agent='pi', effort='low')})
        at(6); runner.tick()
        assert kinds('scan')[-1] == 'failed' and not item('scan').get('retry'), events('scan')

        # --- run-now takes one manual slot and shows a skip -------------------
        reset()
        runner = define({'scan': launch_loop()})
        at(1); runner.run_now('scan')
        assert kinds('scan') == ['starting', 'started'] and events('scan')[-1]['trigger'] == 'manual'
        assert 'last_tick' not in loop_state.read_state(root), 'run-now must not hide a stalled timer'
        at(2); runner.run_now('scan')
        assert kinds('scan')[-1] == 'skipped' and events('scan')[-1]['reason'] == 'previous-run-active'

        # --- an interrupted start is adopted by loop_run_id, or failed --------
        reset()
        runner = define({'scan': launch_loop(max_runtime='5m')})
        at(6); runner.tick()
        session = events('scan')[-1]['session']
        run_id = events('scan')[-1]['run_id']
        state = loop_state.read_state(root)
        state['loops']['scan']['active_run'].update(event='starting', session=None)
        loop_state.write_state(root, state)
        at(15); runner.tick()
        assert item('scan')['active_run']['event'] == 'starting', 'reconciled before ten minutes'
        at(17); runner.tick()
        assert kinds('scan')[-1] == 'started' and events('scan')[-1]['session'] == session, events('scan')[-1]
        assert item('scan')['active_run']['session'] == session and session in live()

        # A session that never took its kickoff would idle to a false `completed`.
        reset()
        runner = define({'scan': launch_loop()})
        at(6); runner.tick()
        session = events('scan')[-1]['session']
        path, rec = m.load_session(session)
        rec.pop('kickoff_delivery')
        rec.pop('kickoff_sent_at', None)
        m.write_session(path, rec)
        state = loop_state.read_state(root)
        state['loops']['scan']['active_run'].update(event='starting', session=None)
        loop_state.write_state(root, state)
        at(17); runner.tick()
        assert kinds('scan')[-1] == 'failed' and events('scan')[-1]['reason'] == 'start interrupted', events('scan')
        assert session not in live() and m.load_session(session)[1]['state'] == 'retired'

        reset()
        runner = define({'scan': launch_loop()})
        state = loop_state.read_state(root)
        state.setdefault('loops', {})['scan'] = {'last_evaluated': '2026-01-01T00:06:00Z', 'active_run': {
            'run_id': 'scan-20260101T000500Z', 'slot': '2026-01-01T00:05:00Z', 'trigger': 'scheduled',
            'started_at': '2026-01-01T00:06:00Z', 'mode': 'launch', 'event': 'starting',
            'attempt': 1, 'idle_ticks': 0, 'session': None}}
        loop_state.write_state(root, state)
        at(17); runner.tick()
        assert kinds('scan')[-1] == 'failed' and events('scan')[-1]['reason'] == 'start interrupted'

        # --- only the loop's own session is ever stopped ----------------------
        reset()
        runner = define({'scan': launch_loop()})
        at(6); runner.tick()
        session = events('scan')[-1]['session']
        path, rec = m.load_session(session)
        rec['role'] = 'lead'
        m.write_session(path, rec)
        wait_ready(session)
        at(7); runner.tick()
        at(8); runner.tick()
        assert session in live(), 'a session that is not this run was stopped'

        # --- an empty tmux listing does not prove a session gone ---------------
        reset()
        runner = define({'scan': launch_loop()})
        at(6); runner.tick()
        session = events('scan')[-1]['session']
        with patch.object(m, 'tmux_sessions', return_value=set()):
            assert m.loop_session_state(session) == 'unknown'
            at(7); runner.tick()
        assert kinds('scan')[-1] == 'started' and session in live(), 'a live run was failed'
        assert m.loop_session_gone(m.load_session(session)[1]) is False

        # --- only tmux's own words prove a session gone -------------------------
        from types import SimpleNamespace
        for text, gone in (("can't find session: x\n", True), ('no server running on /tmp/x\n', True),
                           ('error connecting to /tmp/x (No such file or directory)\n', True),
                           ('error connecting to /tmp/x (Too many open files)\n', False),
                           ('error connecting to /tmp/x (Permission denied)\n', False)):
            answer = SimpleNamespace(returncode=1, stderr=text)
            with patch.object(m, 'session_backend',
                              return_value=SimpleNamespace(command=lambda *a, **k: answer)):
                assert m.loop_session_gone({'name': 'x', 'backend': 'tmux'}) is gone, text

        # --- a session tmux cannot confirm is not retired blind -----------------
        session = events('scan')[-1]['session']
        run_id = events('scan')[-1]['run_id']
        with patch.object(m, 'tmux_has_session', return_value=False):
            try:
                m.retire_loop_run(run_id, 'test')
            except RuntimeError as exc:
                assert 'cannot confirm' in str(exc), exc
            else:
                raise AssertionError('a session with unproved liveness was retired')
        assert session in live() and m.load_session(session)[1]['state'] != 'retired'

        # --- a live session with no record is never reported as retired ---------
        try:
            m.retire_loop_run('no-such-run', 'test', session)
        except RuntimeError as exc:
            assert 'not recorded' in str(exc), exc
        else:
            raise AssertionError('a live unrecorded session counted as retired')
        with patch.dict(m.CFG, {'session_backend': 'herdr'}):
            try:
                m.retire_loop_run('no-such-run', 'test', 'sf-loop-gone')
            except RuntimeError as exc:
                assert 'not recorded' in str(exc), exc
            else:
                raise AssertionError('herdr liveness was assumed from the tmux server')
        assert m.retire_loop_run('no-such-run', 'test', 'sf-loop-gone') is None

        # --- a failed retirement keeps the run until it succeeds --------------
        reset()
        runner = define({'scan': launch_loop()})
        at(6); runner.tick()
        session = events('scan')[-1]['session']
        wait_ready(session)
        at(7); runner.tick()
        with patch.object(m, 'session_cleanup', side_effect=RuntimeError('cleanup refused: store busy')):
            at(8); runner.tick()
        assert kinds('scan')[-1] == 'started' and item('scan')['active_run']['session'] == session
        at(9); runner.tick()
        assert kinds('scan')[-1] == 'completed', 'a stopped session must not turn a finished run into a failure'
        assert kinds('scan').count('completed') == 1 and m.load_session(session)[1]['state'] == 'retired'

        # --- a kickoff failure that cannot retire stays tracked -----------------
        reset()
        runner = define({'scan': launch_loop()})
        behaviour.write_text('blind')
        with patch.object(m, 'session_cleanup', side_effect=RuntimeError('cleanup refused: store busy')):
            at(6); runner.tick()
        state = item('scan')
        assert state['active_run']['finishing']['event'] == 'failed' and not state.get('retry'), state
        assert 'failed' not in kinds('scan'), kinds('scan')
        at(7); runner.tick()
        assert kinds('scan')[-1] == 'failed' and item('scan')['active_run'] is None, events('scan')[-1]
        assert not [rec for rec in records('scan-') if rec['state'] != 'retired']

        # --- a removed loop's session is not orphaned -------------------------
        reset()
        runner = define({'scan': launch_loop(), 'other': launch_loop()})
        at(6); runner.tick()
        session = events('scan')[-1]['session']
        import loop_cli
        loop_cli.command(SimpleNamespace(loop_command='remove', name='scan'), main_checkout=root,
                         definitions_path=defs, session_record=None)
        assert item('scan')['active_run']['session'] == session
        at(7); runner.tick()
        assert kinds('scan')[-1] == 'failed' and events('scan')[-1]['reason'] == 'loop removed', events('scan')[-1]
        assert session not in live() and 'scan' not in loop_state.read_state(root)['loops']

        # --- repeated failures suspend the loop -------------------------------
        reset()
        runner = define({'scan': launch_loop(schedule={'every': '5m', 'start': '00:00'}, tier='no-such-tier')},
                        scheduler={'suspend_after_failures': 2})
        at(6); runner.tick()
        at(11); runner.tick()
        assert kinds('scan')[-2:] == ['failed', 'suspended'], kinds('scan')
        at(16); runner.tick()
        assert kinds('scan')[-1] == 'skipped' and events('scan')[-1]['reason'] == 'suspended'
    finally:
        subprocess.run(['tmux', '-L', SOCKET, 'kill-server'], capture_output=True)
print('loop-launch: ok')
PY
