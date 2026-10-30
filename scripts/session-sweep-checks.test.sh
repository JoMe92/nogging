#!/usr/bin/env bash
# TASK-CSL-003: explicit `session sweep --checks`, cached fingerprints,
# `session checks-ack`, and doctor cache reuse without network calls.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import contextlib, io, json, pathlib, sys, tempfile, time
from importlib.machinery import SourceFileLoader
from types import SimpleNamespace
from unittest.mock import patch
m = SourceFileLoader('sweep_checks', str(pathlib.Path(sys.argv[1])/'scripts/nogg')).load_module()
def result(code=0, out=''): return SimpleNamespace(returncode=code, stdout=out)
HEAD = 'a'*40
def pr(*checks, head=HEAD, state='OPEN'):
    return [dict(number=7, url='https://example.invalid/pr/7', state=state,
                 headRefOid=head, statusCheckRollup=list(checks))]
def run_check(name, conclusion, run_id, status='COMPLETED'):
    return dict(name=name, workflowName='CI', status=status, conclusion=conclusion,
                detailsUrl=f'https://example.invalid/runs/{run_id}')
remote = {'rows': pr(run_check('test', 'SUCCESS', 1)), 'fail': False}
calls = []
def fake_run(*args, **kwargs):
    calls.append(args)
    if args[0] == 'gh':
        return result(1) if remote['fail'] else result(out=json.dumps(remote['rows']))
    if args[0] == 'git' and 'rev-parse' in args: return result(out=HEAD + '\n')
    return result(1)
with tempfile.TemporaryDirectory() as tmp:
    sdir = pathlib.Path(tmp)
    rec = dict(name='sf-lead-x', bead_id='B1', role='lead', working_dir=tmp)
    (sdir/'sf-lead-x.json').write_text(json.dumps(rec))
    patches = [patch.object(m, 'sessions_dir', return_value=sdir),
               patch.object(m, 'run', side_effect=fake_run),
               patch.object(m, '_session_worktree_branch', return_value='feature')]
    with contextlib.ExitStack() as stack:
        for p in patches: stack.enter_context(p)
        # The cache file is never mistaken for a session record.
        line = m.session_sweep_checks(rec)
        assert [r['name'] for _p, r in m.session_records()] == ['sf-lead-x']
        assert 'checks passing' in line and 'unchecked' in line, line
        # Read-only inspection: observing never acknowledges.
        m.session_sweep_checks(rec)
        assert 'ack' not in m._load_checks_cache('sf-lead-x')
        assert m._checks_summary(m._load_checks_cache('sf-lead-x'))[1], 'unacked needs attention'
        # An explicit ack clears the unchecked flag for that fingerprint.
        fp = m._load_checks_cache('sf-lead-x')['observation']['fingerprint']
        with contextlib.redirect_stdout(io.StringIO()):
            try: m.session_checks_ack('sf-lead-x', fingerprint='0'*16)
            except RuntimeError: pass
            else: raise AssertionError('mismatched fingerprint acknowledged')
            m.session_checks_ack('sf-lead-x', fingerprint=fp)
        text, attention = m._checks_summary(m._load_checks_cache('sf-lead-x'))
        assert 'acknowledged' in text and not attention, text
        # The observation carries what a pull request decision needs.
        remote['rows'] = [dict(pr(run_check('test', 'SUCCESS', 1))[0], mergeable='CONFLICTING', additions=12, deletions=3)]
        m.session_sweep_checks(rec)
        obs = m._load_checks_cache('sf-lead-x')['observation']
        assert (obs['mergeable'], obs['additions'], obs['deletions']) == ('CONFLICTING', 12, 3), obs
        # A new failing CI run (new run id) appears unchecked again.
        remote['rows'] = pr(run_check('test', 'FAILURE', 2))
        line = m.session_sweep_checks(rec)
        assert 'checks failing' in line and 'unchecked' in line and 'failed=test' in line, line
        # A re-run that fails again is a new run, hence a new fingerprint.
        fp_fail = m._load_checks_cache('sf-lead-x')['observation']['fingerprint']
        remote['rows'] = pr(run_check('test', 'FAILURE', 3))
        m.session_sweep_checks(rec)
        assert m._load_checks_cache('sf-lead-x')['observation']['fingerprint'] != fp_fail
        # The previous acknowledgement is preserved, but does not cover it.
        assert m._load_checks_cache('sf-lead-x')['ack']['fingerprint'] == fp
        # Pending and status-context entries are classified, never passing.
        remote['rows'] = pr(run_check('test', None, 4, status='IN_PROGRESS'), dict(context='legacy', state='PENDING'))
        assert 'checks pending' in m.session_sweep_checks(rec)
        remote['rows'] = pr(dict(context='legacy', state='ERROR'))
        assert 'checks failing' in m.session_sweep_checks(rec)
        # Network errors and undecodable output never imply success.
        remote['fail'] = True
        line = m.session_sweep_checks(rec)
        assert line.startswith('checks unknown') and 'passing' not in line, line
        with contextlib.redirect_stdout(io.StringIO()):
            try: m.session_checks_ack('sf-lead-x')
            except RuntimeError: pass
            else: raise AssertionError('unknown observation acknowledged')
        remote['fail'] = False
        for rows in ('broken', {}, [dict(state='OPEN', headRefOid=HEAD)], pr()+pr()):
            remote['rows'] = rows
            if rows == 'broken':
                with patch.object(m, 'run', side_effect=lambda *a, **k: result(out='not json') if a[0]=='gh' else fake_run(*a)):
                    assert m.session_sweep_checks(rec).startswith('checks unknown')
            else:
                assert m.session_sweep_checks(rec).startswith('checks unknown'), rows
        remote['rows'] = []
        assert m.session_sweep_checks(rec).startswith('checks no-pr')
        # Doctor reuse: cached summaries without any remote call.
        remote['rows'] = pr(run_check('test', 'FAILURE', 5))
        m.session_sweep_checks(rec)
        calls.clear()
        cache = m._load_checks_cache('sf-lead-x')
        text, attention = m._checks_summary(cache)
        assert 'checks failing' in text and attention and not calls
        stale = time.time() + m._checks_stale_seconds() + 120
        text, attention = m._checks_summary(cache, now_ts=stale)
        assert 'stale' in text and attention, text
        text, attention = m._checks_summary({})
        assert text.startswith('checks unknown') and attention
    # The doctor note path reads only the cache (no gh in its source).
    import inspect
    assert 'gh' not in inspect.getsource(m._checks_summary)
    src = inspect.getsource(m.doctor)
    assert '_checks_summary(_load_checks_cache(' in src and 'session_sweep_checks' not in src
print('Sweep checks fingerprint, acknowledgement, unknown and doctor cache regressions passed')
PY
