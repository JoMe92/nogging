#!/usr/bin/env bash
# Reservation ledger versioned writer, extensions and opaque target mutation refusal (TASK-ULT-002).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/lib/test-env.sh"
python3 - "$here" <<'PY'
import datetime as dt
import fcntl
import io
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import nogg_usage as u

cfg = u.gate_config(None)

def report(account='account-writer', group='shared'):
    return dict(provider='codex', account=account, model_group=group,
                windows=[dict(bucket=b, status='known', reason=None,
                              used_percent=50, resets_at=r)
                         for b, r in [('short', '2030-01-01T00:00:00Z'),
                                      ('weekly', '2030-01-07T00:00:00Z')]])

scope_shared = u.reservation_scope(report())

# ---------------------------------------------------------------------------
# Test 1: Pending and bound entry lifecycle with schema_version 1
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    ledger = u.Reservations(root)

    # Fake probe helper
    probe_script = Path(temp) / 'probe.sh'
    probe_log = Path(temp) / 'probe.log'
    probe_script.write_text(f'#!/bin/sh\necho "$@" >>"{probe_log}"\nexit 0\n')
    probe_script.chmod(0o700)

    session_file = Path(temp) / 'session.json'
    session_file.write_text(json.dumps({'state': 'running'}))

    # 1. Admit creates pending entry stamped with schema_version: 1
    gate = ledger.admit(report(), cfg, 5)
    assert gate['decision'] == 'admitted', gate
    tok1 = gate['reservation_id']

    raw_ledger = json.loads((root / 'ledger.json').read_text())
    assert tok1 in raw_ledger
    entry1 = raw_ledger[tok1]
    assert entry1['schema_version'] == 1, f"expected schema_version 1, got {entry1.get('schema_version')}"
    assert type(entry1['schema_version']) is int
    assert entry1['estimate'] == 5
    assert entry1['scope'] == scope_shared
    assert 'session' not in entry1

    # Pending owner file is locked
    assert tok1 in ledger.pending
    owner1_path = root / entry1['owner']
    assert owner1_path.exists()

    # 2. Bind with backend-neutral probe preserves schema_version 1
    probe_payload = {'backend': 'custom', 'argv': [str(probe_script), 'check', 'sess1']}
    ledger.bind(tok1, session_file, 'sess1', probe_payload)
    ledger.finish(tok1)

    raw_ledger_after_bind = json.loads((root / 'ledger.json').read_text())
    bound_entry1 = raw_ledger_after_bind[tok1]
    assert bound_entry1['schema_version'] == 1
    assert type(bound_entry1['schema_version']) is int
    assert bound_entry1['session']['name'] == 'sess1'
    assert bound_entry1['session']['path'] == str(session_file.resolve())
    assert bound_entry1['session']['probe'] == probe_payload

    # Bound entry is alive and counted in totals
    totals = ledger.totals(report())
    assert totals == {'short': 5, 'weekly': 5}

    # 3. Bind with legacy tmux/socket arguments normalizes probe and preserves schema_version 1
    gate2 = ledger.admit(report(), cfg, 3)
    tok2 = gate2['reservation_id']
    ledger.bind(tok2, session_file, 'sess2', str(probe_script), socket='custom-sock')
    ledger.finish(tok2)

    raw_ledger2 = json.loads((root / 'ledger.json').read_text())
    bound_entry2 = raw_ledger2[tok2]
    assert bound_entry2['schema_version'] == 1
    assert bound_entry2['session']['probe'] == {
        'backend': 'tmux',
        'argv': [str(probe_script), '-L', 'custom-sock', 'has-session', '-t', 'sess2']
    }

    # 4. Bind on an unversioned legacy pending entry stamps it with schema_version 1
    legacy_tok = 'tok-legacy-pending'
    legacy_owner = 'legacy-pending.owner'
    lfd = os.open(root / legacy_owner, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    raw_ledger2[legacy_tok] = {
        'scope': scope_shared,
        'estimate': 2,
        'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
        'owner': legacy_owner
    }
    (root / 'ledger.json').write_text(json.dumps(raw_ledger2))

    ledger.bind(legacy_tok, session_file, 'sess-legacy', probe_payload)
    os.close(lfd)

    raw_ledger3 = json.loads((root / 'ledger.json').read_text())
    assert raw_ledger3[legacy_tok]['schema_version'] == 1

    # 5. Clean release removes understood entries and unlinks owner files
    assert (root / entry1['owner']).exists()
    ledger.release(tok1)
    raw_after_release = json.loads((root / 'ledger.json').read_text())
    assert tok1 not in raw_after_release
    assert not (root / entry1['owner']).exists(), "owner file was not unlinked on release"

# ---------------------------------------------------------------------------
# Test 2: Extension preservation across bind, admit and release
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    ledger = u.Reservations(root)

    probe_script = Path(temp) / 'probe.sh'
    probe_script.write_text('#!/bin/sh\nexit 0\n')
    probe_script.chmod(0o700)
    session_file = Path(temp) / 'session.json'
    session_file.write_text(json.dumps({'state': 'running'}))

    # Admit pending entry
    tok_ext = ledger.admit(report(), cfg, 5)['reservation_id']

    # Inject unknown extension fields into the pending entry in ledger.json
    disk_data = json.loads((root / 'ledger.json').read_text())
    disk_data[tok_ext]['custom_meta'] = {'tag': 'extended', 'priority': 10}
    disk_data[tok_ext]['feature_flags'] = ['alpha', 'beta']
    (root / 'ledger.json').write_text(json.dumps(disk_data))

    # Bind the extended entry
    probe_info = {'backend': 'custom', 'argv': [str(probe_script), 'check']}
    ledger.bind(tok_ext, session_file, 'sess-ext', probe_info)
    ledger.finish(tok_ext)

    # Verify extensions are preserved after binding
    bound_disk = json.loads((root / 'ledger.json').read_text())
    assert bound_disk[tok_ext]['schema_version'] == 1
    assert bound_disk[tok_ext]['custom_meta'] == {'tag': 'extended', 'priority': 10}
    assert bound_disk[tok_ext]['feature_flags'] == ['alpha', 'beta']
    assert bound_disk[tok_ext]['session']['name'] == 'sess-ext'

    # Unrelated admission preserves extensions on existing entry
    tok_other = ledger.admit(report(account='acc-2'), cfg, 4)['reservation_id']
    disk_after_admit = json.loads((root / 'ledger.json').read_text())
    assert disk_after_admit[tok_ext]['custom_meta'] == {'tag': 'extended', 'priority': 10}
    assert disk_after_admit[tok_ext]['feature_flags'] == ['alpha', 'beta']

    # Unrelated release preserves extensions on existing entry
    ledger.release(tok_other)
    disk_after_other_rel = json.loads((root / 'ledger.json').read_text())
    assert disk_after_other_rel[tok_ext]['custom_meta'] == {'tag': 'extended', 'priority': 10}
    assert disk_after_other_rel[tok_ext]['feature_flags'] == ['alpha', 'beta']

# ---------------------------------------------------------------------------
# Test 3: Refusal of opaque-target bind and release
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)
    ledger = u.Reservations(root)

    probe_script = Path(temp) / 'probe.sh'
    probe_script.write_text('#!/bin/sh\nexit 0\n')
    probe_script.chmod(0o700)
    session_file = Path(temp) / 'session.json'
    session_file.write_text(json.dumps({'state': 'running'}))

    # Define various opaque entries with valid accounting cores
    opaque_cases = {
        'opaque-future-v2': {
            'schema_version': 2,
            'scope': scope_shared,
            'estimate': 5,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'future-v2.owner',
            'unknown_field': 'hello'
        },
        'opaque-future-v99': {
            'schema_version': 99,
            'scope': scope_shared,
            'estimate': 4,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'future-v99.owner'
        },
        'opaque-ver-0': {
            'schema_version': 0,
            'scope': scope_shared,
            'estimate': 3,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'ver-0.owner'
        },
        'opaque-ver-str': {
            'schema_version': '1',
            'scope': scope_shared,
            'estimate': 3,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'ver-str.owner'
        },
        'opaque-ver-bool': {
            'schema_version': True,
            'scope': scope_shared,
            'estimate': 3,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'ver-bool.owner'
        },
        'opaque-malformed-sess': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 2,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'malformed-sess.owner',
            'session': 'not-a-dict'
        },
        'opaque-malformed-probe': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 2,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'malformed-probe.owner',
            'session': {
                'path': str(session_file),
                'name': 'sess-bad-probe',
                'probe': {'backend': 'custom', 'argv': [12345]}  # non-string argv
            }
        }
    }

    # Also include one understood entry to ensure mixed ledger operations work
    valid_owner = root / 'valid.owner'
    vfd = os.open(valid_owner, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(vfd, fcntl.LOCK_EX | fcntl.LOCK_NB)

    initial_ledger = dict(opaque_cases)
    initial_ledger['tok-valid-pending'] = {
        'schema_version': 1,
        'scope': scope_shared,
        'estimate': 5,
        'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
        'owner': 'valid.owner'
    }

    # Create dummy owner files for opaque entries to verify they are never unlinked
    for item in opaque_cases.values():
        (root / item['owner']).touch()

    (root / 'ledger.json').write_text(json.dumps(initial_ledger))
    bytes_before = (root / 'ledger.json').read_bytes()

    probe_arg = {'backend': 'custom', 'argv': [str(probe_script), 'test']}

    # 1. Bind on each opaque target MUST fail with RuntimeError and leave ledger untouched
    for opaque_token in opaque_cases:
        try:
            ledger.bind(opaque_token, session_file, 'test-sess', probe_arg)
        except RuntimeError as exc:
            assert f'cannot bind opaque reservation {opaque_token}' in str(exc), str(exc)
        else:
            raise AssertionError(f"bind() did not fail for opaque token {opaque_token}")

        # Ledger on disk must be identical
        assert (root / 'ledger.json').read_bytes() == bytes_before, f"ledger changed after bind on {opaque_token}"

    # 2. Release on each opaque target MUST fail with RuntimeError and leave ledger/owner untouched
    for opaque_token in opaque_cases:
        try:
            ledger.release(opaque_token)
        except RuntimeError as exc:
            assert f'cannot release opaque reservation {opaque_token}' in str(exc), str(exc)
        else:
            raise AssertionError(f"release() did not fail for opaque token {opaque_token}")

        # Ledger on disk must be identical
        assert (root / 'ledger.json').read_bytes() == bytes_before, f"ledger changed after release on {opaque_token}"
        # Owner file must still exist
        assert (root / opaque_cases[opaque_token]['owner']).exists()

    # 3. Bind on nonexistent token fails
    try:
        ledger.bind('nonexistent-token', session_file, 'test-sess', probe_arg)
    except RuntimeError as exc:
        assert 'disappeared before launch completed' in str(exc)
    else:
        raise AssertionError("bind on nonexistent token did not fail")

    # 4. Valid operations on understood tokens succeed in the presence of opaque entries
    ledger.bind('tok-valid-pending', session_file, 'valid-sess', probe_arg)
    disk_after_valid_bind = json.loads((root / 'ledger.json').read_text())
    assert disk_after_valid_bind['tok-valid-pending']['session']['name'] == 'valid-sess'
    # All opaque entries preserved
    for token in opaque_cases:
        assert token in disk_after_valid_bind

    ledger.release('tok-valid-pending')
    disk_after_valid_release = json.loads((root / 'ledger.json').read_text())
    assert 'tok-valid-pending' not in disk_after_valid_release
    for token in opaque_cases:
        assert token in disk_after_valid_release

    os.close(vfd)

# ---------------------------------------------------------------------------
# Test 4: Failure cleanup in admit and transaction failures
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    ledger = u.Reservations(root)

    # 1. Admit token 1 successfully
    tok1 = ledger.admit(report(), cfg, 5)['reservation_id']
    owner1_file = root / (tok1 + '.owner')
    assert tok1 in ledger.pending
    assert owner1_file.exists()

    # 2. Simulate failure during second admission's ledger write
    # When atomic replace fails, the newly allocated token must be cleaned up,
    # BUT tok1 must remain valid in ledger.pending and on disk!
    original_replace = os.replace
    def failing_replace(src, dst):
        if 'ledger.json' in str(dst):
            raise OSError('simulated disk failure on ledger commit')
        return original_replace(src, dst)

    with patch('os.replace', side_effect=failing_replace):
        try:
            ledger.admit(report(account='acc-fail'), cfg, 4)
        except OSError as exc:
            assert 'simulated disk failure' in str(exc)
        else:
            raise AssertionError("admit() did not fail during simulated OSError")

    # Tok1 is still in ledger.pending and its owner file still exists
    assert tok1 in ledger.pending
    assert owner1_file.exists()
    # No orphan owner files from the failed admission remain in the directory
    owner_files = [p.name for p in root.glob('*.owner')]
    assert owner_files == [tok1 + '.owner'], f"orphan owner files left behind: {owner_files}"

    # Verify tok1 can still be bound and released cleanly
    probe_script = Path(temp) / 'probe.sh'
    probe_script.write_text('#!/bin/sh\nexit 0\n')
    probe_script.chmod(0o700)
    session_file = Path(temp) / 'session.json'
    session_file.write_text(json.dumps({'state': 'running'}))

    ledger.bind(tok1, session_file, 'sess1', {'backend': 'custom', 'argv': [str(probe_script)]})
    ledger.finish(tok1)
    assert tok1 not in ledger.pending
    ledger.release(tok1)
    assert not owner1_file.exists()

# ---------------------------------------------------------------------------
# Test 5: Input validation failures in bind
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    ledger = u.Reservations(root)

    tok = ledger.admit(report(), cfg, 5)['reservation_id']
    bad_probes = [
        'not-a-dict',
        {},
        {'backend': ''},
        {'backend': 123, 'argv': ['cmd']},
        {'backend': 'b', 'argv': 'not-a-list'},
        {'backend': 'b', 'argv': []},
        {'backend': 'b', 'argv': [123]},
        {'backend': 'b', 'argv': ['cmd', '']},  # empty string in argv
    ]
    for bad_probe in bad_probes:
        try:
            ledger.bind(tok, '/path', 'name', bad_probe)
        except ValueError as exc:
            assert 'invalid session liveness probe' in str(exc)
        else:
            raise AssertionError(f"bind did not reject bad probe: {bad_probe!r}")

    # Entry is still pending and untouched
    raw = json.loads((root / 'ledger.json').read_text())
    assert raw[tok]['schema_version'] == 1
    assert 'session' not in raw[tok]
    ledger.release(tok)

print('ok - versioned writer, extensions and opaque target mutation refusal')
PY
