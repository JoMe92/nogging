#!/usr/bin/env bash
# Reservation ledger mixed readers/writers, v2.2.0 negative fixture,
# and compatibility verification (TASK-ULT-006).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/lib/test-env.sh"
python3 - "$here" <<'PY'
import datetime as dt
import fcntl
import io
import json
import math
import multiprocessing as mp
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import redirect_stderr

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import nogg_usage as u

cfg = u.gate_config(None)

def report(account='account-compat', group='shared', short_reset='2030-01-01T00:00:00Z', weekly_reset='2030-01-07T00:00:00Z'):
    return dict(provider='codex', account=account, model_group=group,
                windows=[dict(bucket=b, status='known', reason=None,
                              used_percent=50, resets_at=r)
                         for b, r in [('short', short_reset),
                                      ('weekly', weekly_reset)]])

scope_shared = u.reservation_scope(report())


# ===========================================================================
# Labelled v2.2.0 negative fixture: historical reader reproduction
# Source attribution: v2.2.0 scripts/nogg_usage.py Reservations._alive
# ===========================================================================
class V220ReservationsNegativeFixture:
    """Historical v2.2.0 Reservations implementation for negative compatibility testing.

    Directly extracted from release tag v2.2.0 (scripts/nogg_usage.py lines 1025-1070).
    In v2.2.0, _alive assumed owner['tmux'] and owner['socket'] were unconditionally
    present in every entry's session dictionary, raising KeyError: 'tmux' on
    backend-neutral probe structures ({'backend': ..., 'argv': ...}) introduced
    in subsequent releases.
    """
    def __init__(self, root):
        self.root = Path(root)

    def _pending_alive(self, owner):
        try:
            descriptor = os.open(self.root / owner, os.O_RDONLY)
        except FileNotFoundError:
            return False
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False
            except BlockingIOError:
                return True
        finally:
            os.close(descriptor)

    def _alive(self, entry):
        owner = entry.get('session')
        if owner:
            try:
                record = json.loads(Path(owner['path']).read_text())
            except (OSError, ValueError):
                record = None
            if record and record.get('state') in ('stopped', 'failed', 'retired'):
                return False
            try:
                # Historical flaw in v2.2.0: assumes owner['tmux'] and owner['socket'] exist!
                result = subprocess.run([owner['tmux'], '-L', owner['socket'],
                                         'has-session', '-t', owner['name']],
                                        capture_output=True, timeout=5)
                if result.returncode == 0:
                    return True
            except (OSError, subprocess.TimeoutExpired):
                return True
        return self._pending_alive(entry['owner'])

    def totals(self, rep):
        ledger_path = self.root / 'ledger.json'
        if not ledger_path.exists():
            return {w['bucket']: 0 for w in rep['windows']}
        lock_fd = os.open(self.root / 'ledger.lock', os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(lock_fd, 'r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
            entries = json.loads(ledger_path.read_text())
            # Replicates v2.2.0 _totals filtering with _alive check
            alive_entries = {k: v for k, v in entries.items() if self._alive(v)}
            scope = u.reservation_scope(rep)
            return {window['bucket']: sum(entry['estimate'] for entry in alive_entries.values()
                                         if entry['scope'] == scope and
                                         entry['windows'].get(window['bucket']) in (None, window['resets_at']))
                    for window in rep['windows']}


# ---------------------------------------------------------------------------
# Test 1: v2.2.0 Negative Fixture demonstrates KeyError on backend-neutral entry
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)

    session_file = Path(temp) / 'session.json'
    session_file.write_text(json.dumps({'state': 'running'}))

    # Backend-neutral entry written by newer release (or ULT-002)
    ledger_data = {
        'tok-backend-neutral': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 5,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'neutral.owner',
            'session': {
                'path': str(session_file),
                'name': 'sess-neutral',
                'probe': {'backend': 'tmux', 'argv': ['true']}
            }
        }
    }
    (root / 'ledger.json').write_text(json.dumps(ledger_data))

    # 1. Historical v2.2.0 reader raises KeyError: 'tmux'
    old_reader = V220ReservationsNegativeFixture(root)
    raised_key_error = False
    try:
        old_reader.totals(report())
    except KeyError as exc:
        if 'tmux' in str(exc):
            raised_key_error = True
    assert raised_key_error, "v2.2.0 negative fixture did not raise expected KeyError: 'tmux'"

    # 2. Tolerant reader in this release reads the exact same entry without error
    current_reader = u.Reservations(root)
    stderr_buf = io.StringIO()
    with redirect_stderr(stderr_buf):
        totals = current_reader.totals(report())
    assert totals == {'short': 5, 'weekly': 5}, f"tolerant reader failed to read backend-neutral entry: {totals}"


# ---------------------------------------------------------------------------
# Test 2: Mixed entries: unversioned tmux, unversioned probe, v1 pending/bound,
#         future version, malformed session shape, and probe isolation
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)

    # Canary probe: must never be executed for opaque/future/malformed entries
    canary_log = Path(temp) / 'canary.log'
    canary_script = Path(temp) / 'canary_probe.sh'
    canary_script.write_text(f'#!/bin/sh\necho "CANARY CALLED" >>"{canary_log}"\nexit 1\n')
    canary_script.chmod(0o700)

    # Live probe for understood entries
    good_log = Path(temp) / 'good.log'
    good_script = Path(temp) / 'good_probe.sh'
    good_script.write_text(f'#!/bin/sh\necho "$@" >>"{good_log}"\nexit 0\n')
    good_script.chmod(0o700)

    # Session files
    running_session = Path(temp) / 'running_session.json'
    running_session.write_text(json.dumps({'state': 'running'}))

    terminal_session = Path(temp) / 'terminal_session.json'
    terminal_session.write_text(json.dumps({'state': 'stopped'}))

    # Locked pending owner file for pending entry
    pending_owner = root / 'v1-pending.owner'
    pfd = os.open(pending_owner, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(pfd, fcntl.LOCK_EX | fcntl.LOCK_NB)

    mixed_ledger = {
        # 1. Unversioned legacy tmux entry
        'tok-legacy-tmux': {
            'scope': scope_shared,
            'estimate': 2,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'legacy-tmux.owner',
            'session': {
                'path': str(running_session),
                'name': 'sess-leg-tmux',
                'tmux': str(good_script),
                'socket': 'leg-sock'
            }
        },
        # 2. Unversioned backend-neutral probe entry
        'tok-legacy-probe': {
            'scope': scope_shared,
            'estimate': 3,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'legacy-probe.owner',
            'session': {
                'path': str(running_session),
                'name': 'sess-leg-probe',
                'probe': {'backend': 'custom', 'argv': [str(good_script), 'check', 'leg-probe']}
            }
        },
        # 3. Version 1 pending entry (active lock held)
        'tok-v1-pending': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 4,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'v1-pending.owner'
        },
        # 4. Version 1 bound entry
        'tok-v1-bound': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 5,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'v1-bound.owner',
            'session': {
                'path': str(running_session),
                'name': 'sess-v1-bound',
                'probe': {'backend': 'tmux', 'argv': [str(good_script), 'check', 'v1-bound']}
            }
        },
        # 5. Future version entry (v2) with terminal-looking session and canary probe
        'tok-future-v2': {
            'schema_version': 2,
            'scope': scope_shared,
            'estimate': 6,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'future-v2.owner',
            'session': {
                'path': str(terminal_session),
                'name': 'sess-future-v2',
                'probe': {'backend': 'future', 'argv': [str(canary_script), 'future-probe']}
            },
            'future_fields': {'extended_capability': True, 'priority': 'high'}
        },
        # 6. Malformed session shape entry with valid accounting core
        'tok-malformed-session': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 7,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'malformed.owner',
            'session': 'not-a-dict'
        }
    }

    (root / 'ledger.json').write_text(json.dumps(mixed_ledger))
    ledger = u.Reservations(root)

    # Verify totals across all 6 entries: 2 + 3 + 4 + 5 + 6 + 7 = 27
    stderr_buf = io.StringIO()
    with redirect_stderr(stderr_buf):
        totals = ledger.totals(report())
    assert totals == {'short': 27, 'weekly': 27}, f"expected 27, got {totals}"

    # Canary check: canary_probe MUST NOT have been executed
    assert not canary_log.exists(), "canary probe was executed for opaque entry during totals!"

    # Scope filtering check: different scope yields 0
    diff_scope_report = report(account='other-account')
    with redirect_stderr(stderr_buf):
        diff_totals = ledger.totals(diff_scope_report)
    assert diff_totals == {'short': 0, 'weekly': 0}, f"expected 0 for different scope, got {diff_totals}"

    # Window reset filtering check: reset window in report does not match entry reset
    reset_report = report(short_reset='2035-01-01T00:00:00Z', weekly_reset='2030-01-07T00:00:00Z')
    with redirect_stderr(stderr_buf):
        reset_totals = ledger.totals(reset_report)
    # short window had reset, so entries with old reset are not owed: short=0, weekly=27
    assert reset_totals == {'short': 0, 'weekly': 27}, f"expected short=0, weekly=27, got {reset_totals}"

    # Verify read-only bytes: totals() must not modify ledger.json bytes
    initial_bytes = (root / 'ledger.json').read_bytes()
    with redirect_stderr(stderr_buf):
        ledger.totals(report())
    assert (root / 'ledger.json').read_bytes() == initial_bytes, "totals() modified ledger.json bytes!"

    os.close(pfd)


# ---------------------------------------------------------------------------
# Test 3: Opaque entry preservation across admit, bind, release, and mutation refusal
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)

    good_script = Path(temp) / 'good_probe.sh'
    good_script.write_text('#!/bin/sh\nexit 0\n')
    good_script.chmod(0o700)
    sess_file = Path(temp) / 'sess.json'
    sess_file.write_text(json.dumps({'state': 'running'}))

    # Seed ledger with future v2 and v99 entries carrying unknown fields
    seed_ledger = {
        'tok-opaque-v2': {
            'schema_version': 2,
            'scope': scope_shared,
            'estimate': 10,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'opaque-v2.owner',
            'session': {
                'path': str(sess_file),
                'name': 'sess-v2',
                'probe': {'backend': 'v2-backend', 'argv': ['/bin/true']}
            },
            'extra_payload': {'nested': [1, 2, 3], 'str_key': 'val'}
        },
        'tok-opaque-v99': {
            'schema_version': 99,
            'scope': scope_shared,
            'estimate': 8,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'opaque-v99.owner',
            'custom_tags': ['alpha', 'omega']
        }
    }
    (root / 'ledger.json').write_text(json.dumps(seed_ledger))
    ledger = u.Reservations(root)

    # 1. Admit a new token; verify opaque entries and unknown fields are preserved verbatim
    stderr_buf = io.StringIO()
    with redirect_stderr(stderr_buf):
        admit_gate = ledger.admit(report(), cfg, 5)
    assert admit_gate['decision'] == 'admitted', admit_gate
    new_tok = admit_gate['reservation_id']

    raw_admit = json.loads((root / 'ledger.json').read_text())
    assert new_tok in raw_admit
    assert raw_admit['tok-opaque-v2'] == seed_ledger['tok-opaque-v2']
    assert raw_admit['tok-opaque-v99'] == seed_ledger['tok-opaque-v99']

    # 2. Bind the new token; verify opaque entries remain preserved
    probe_spec = {'backend': 'custom', 'argv': [str(good_script), 'check']}
    with redirect_stderr(stderr_buf):
        ledger.bind(new_tok, sess_file, 'sess-new', probe_spec)
        ledger.finish(new_tok)

    raw_bound = json.loads((root / 'ledger.json').read_text())
    assert raw_bound['tok-opaque-v2'] == seed_ledger['tok-opaque-v2']
    assert raw_bound['tok-opaque-v99'] == seed_ledger['tok-opaque-v99']

    # 3. Attempt to bind an opaque target: MUST BE REFUSED with diagnostic
    bind_refused = False
    try:
        with redirect_stderr(stderr_buf):
            ledger.bind('tok-opaque-v2', sess_file, 'sess-tamper', probe_spec)
    except RuntimeError as exc:
        if 'cannot bind opaque reservation tok-opaque-v2' in str(exc):
            bind_refused = True
    assert bind_refused, "binding opaque target was not refused with expected diagnostic"

    # 4. Attempt to release an opaque target: MUST BE REFUSED with diagnostic
    release_refused = False
    try:
        with redirect_stderr(stderr_buf):
            ledger.release('tok-opaque-v2')
    except RuntimeError as exc:
        if 'cannot release opaque reservation tok-opaque-v2' in str(exc):
            release_refused = True
    assert release_refused, "releasing opaque target was not refused with expected diagnostic"

    # 5. Normal release of new_tok preserves opaque entries
    with redirect_stderr(stderr_buf):
        ledger.release(new_tok)
    raw_released = json.loads((root / 'ledger.json').read_text())
    assert new_tok not in raw_released
    assert raw_released['tok-opaque-v2'] == seed_ledger['tok-opaque-v2']
    assert raw_released['tok-opaque-v99'] == seed_ledger['tok-opaque-v99']


# ---------------------------------------------------------------------------
# Test 4: Invalid accounting core rejection before side effects
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)

    invalid_cases = [
        # Missing scope
        {'estimate': 5, 'windows': {'short': '2030-01-01T00:00:00Z'}, 'owner': 'a.owner'},
        # Non-numeric estimate (boolean)
        {'scope': scope_shared, 'estimate': True, 'windows': {'short': '2030-01-01T00:00:00Z'}, 'owner': 'a.owner'},
        # Negative estimate
        {'scope': scope_shared, 'estimate': -1, 'windows': {'short': '2030-01-01T00:00:00Z'}, 'owner': 'a.owner'},
        # Invalid timestamp
        {'scope': scope_shared, 'estimate': 5, 'windows': {'short': 'invalid-time'}, 'owner': 'a.owner'},
        # Unsafe owner (path traversal)
        {'scope': scope_shared, 'estimate': 5, 'windows': {'short': '2030-01-01T00:00:00Z'}, 'owner': '../unsafe.owner'},
        # Entry not a dict
        "not-a-dict"
    ]

    for idx, bad_entry in enumerate(invalid_cases):
        bad_ledger = {f'tok-bad-{idx}': bad_entry}
        (root / 'ledger.json').write_text(json.dumps(bad_ledger))
        ledger = u.Reservations(root)

        # 1. totals() must raise RuntimeError indicating malformed ledger
        raised_totals = False
        try:
            ledger.totals(report())
        except RuntimeError as exc:
            if 'usage reservation ledger is malformed' in str(exc):
                raised_totals = True
        assert raised_totals, f"totals() did not reject invalid accounting case {idx}: {bad_entry}"

        # 2. admit() must raise RuntimeError without creating owner file or mutating ledger
        raised_admit = False
        try:
            ledger.admit(report(), cfg, 5)
        except RuntimeError as exc:
            if 'usage reservation ledger is malformed' in str(exc):
                raised_admit = True
        assert raised_admit, f"admit() did not reject invalid accounting case {idx}: {bad_entry}"


# ---------------------------------------------------------------------------
# Test 5: Atomic concurrent final-slot admission under common lock
# ---------------------------------------------------------------------------
def worker_admit(ledger_root, rep_dict, config_dict, est, result_queue, stop_event):
    try:
        sys.dont_write_bytecode = True
        res_ledger = u.Reservations(Path(ledger_root))
        gate = res_ledger.admit(rep_dict, config_dict, est)
        result_queue.put((os.getpid(), gate['decision'], gate.get('reservation_id')))
        # Keep process alive and holding the pending lock until parent signals completion
        stop_event.wait(timeout=5)
    except Exception as exc:
        result_queue.put((os.getpid(), 'error', str(exc)))

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)

    # Initial headroom: cap=92%, used=82%, existing reservation=5% -> total=87%.
    # Headroom remaining is 92 - 87 = 5%.
    # Competing processes request 5% each. Exactly ONE must be admitted, the other denied.
    pre_ledger = {
        'tok-existing': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 5,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'existing.owner',
            'session': {
                'path': str(Path(temp) / 'dummy.json'),
                'name': 'dummy-sess',
                'probe': {'backend': 'tmux', 'argv': ['/bin/true']}
            }
        }
    }
    (Path(temp) / 'dummy.json').write_text(json.dumps({'state': 'running'}))
    (root / 'ledger.json').write_text(json.dumps(pre_ledger))

    comp_report = dict(provider='codex', account='account-compat', model_group='shared',
                       windows=[dict(bucket='short', status='known', reason=None,
                                     used_percent=82, resets_at='2030-01-01T00:00:00Z'),
                                dict(bucket='weekly', status='known', reason=None,
                                     used_percent=10, resets_at='2030-01-07T00:00:00Z')])

    queue = mp.Queue()
    stop_event = mp.Event()
    p1 = mp.Process(target=worker_admit, args=(str(root), comp_report, cfg, 5, queue, stop_event))
    p2 = mp.Process(target=worker_admit, args=(str(root), comp_report, cfg, 5, queue, stop_event))

    p1.start()
    p2.start()

    res1 = queue.get(timeout=5)
    res2 = queue.get(timeout=5)

    stop_event.set()
    p1.join(5)
    p2.join(5)

    decisions = sorted([res1[1], res2[1]])
    assert decisions == ['admitted', 'denied'], f"expected ['admitted', 'denied'], got {decisions} (details: {res1}, {res2})"

    # Verify ledger has exactly 2 entries (tok-existing + the winning admitted token)
    final_data = json.loads((root / 'ledger.json').read_text())
    assert len(final_data) == 2, f"expected 2 entries in ledger, got {len(final_data)}: {final_data}"

print("ok - usage ledger compatibility, negative v2.2.0 fixture, and atomic final slot verified")
PY
