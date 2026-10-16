#!/usr/bin/env bash
# Reservation ledger schema decoding, validation and opaque-entry preservation (TASK-ULT-001).
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
from contextlib import redirect_stderr

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import nogg_usage as u

cfg = u.gate_config(None)

def report(account='account-a', group='shared'):
    return dict(provider='codex', account=account, model_group=group,
                windows=[dict(bucket=b, status='known', reason=None,
                              used_percent=50, resets_at=r)
                         for b, r in [('short', '2030-01-01T00:00:00Z'),
                                      ('weekly', '2030-01-07T00:00:00Z')]])

scope_shared = u.reservation_scope(report())

# ---------------------------------------------------------------------------
# Test 1: Tolerant decoding of legacy shapes and version 1 entries
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)

    # Fake probe helper: touches a log and exits 0 (alive)
    probe_script = Path(temp) / 'probe.sh'
    probe_log = Path(temp) / 'probe.log'
    probe_script.write_text(f'#!/bin/sh\necho "$@" >>"{probe_log}"\nexit 0\n')
    probe_script.chmod(0o700)

    # Fake session record: state running
    session_file = Path(temp) / 'session.json'
    session_file.write_text(json.dumps({'state': 'running'}))

    # Owner file for pending entry
    pending_owner = root / 'pending.owner'
    pfd = os.open(pending_owner, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(pfd, fcntl.LOCK_EX | fcntl.LOCK_NB)

    ledger_content = {
        # Shape 1: Legacy tmux entry (no schema_version)
        'tok-legacy-tmux': {
            'scope': scope_shared,
            'estimate': 5,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'legacy-tmux.owner',
            'session': {
                'path': str(session_file),
                'name': 'legacy-tmux-sess',
                'tmux': str(probe_script),
                'socket': 'legacy-sock'
            }
        },
        # Shape 2: Legacy probe entry (no schema_version)
        'tok-legacy-probe': {
            'scope': scope_shared,
            'estimate': 4,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'legacy-probe.owner',
            'session': {
                'path': str(session_file),
                'name': 'legacy-probe-sess',
                'probe': {'backend': 'custom', 'argv': [str(probe_script), 'check', 'legacy-probe']}
            }
        },
        # Shape 3: Version 1 pending entry
        'tok-v1-pending': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 3,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'pending.owner'
        },
        # Shape 4: Version 1 bound entry
        'tok-v1-bound': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 2,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'v1-bound.owner',
            'session': {
                'path': str(session_file),
                'name': 'v1-bound-sess',
                'probe': {'backend': 'tmux', 'argv': [str(probe_script), 'check', 'v1-bound']}
            }
        }
    }

    (root / 'ledger.json').write_text(json.dumps(ledger_content))
    ledger = u.Reservations(root)

    totals = ledger.totals(report())
    assert totals == {'short': 14, 'weekly': 14}, f"expected 14, got {totals}"
    os.close(pfd)

# ---------------------------------------------------------------------------
# Test 2: Opaque entries: future versions, invalid explicit versions,
#         malformed session metadata; probe isolation and preservation.
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)

    # Canary probe script: MUST NOT BE CALLED for opaque entries!
    canary_log = Path(temp) / 'canary_probe_called.log'
    canary_script = Path(temp) / 'failing_probe.sh'
    canary_script.write_text(f'#!/bin/sh\necho "FORBIDDEN PROBE CALLED" >>"{canary_log}"\nexit 1\n')
    canary_script.chmod(0o700)

    # Terminal-looking session record (state: stopped): MUST NOT REAP opaque entries!
    terminal_session = Path(temp) / 'terminal_session.json'
    terminal_session.write_text(json.dumps({'state': 'stopped'}))

    # Valid session for understood baseline
    live_session = Path(temp) / 'live_session.json'
    live_session.write_text(json.dumps({'state': 'running'}))
    good_probe = Path(temp) / 'good_probe.sh'
    good_probe.write_text('#!/bin/sh\nexit 0\n')
    good_probe.chmod(0o700)

    opaque_ledger = {
        'understood-baseline': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 5,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'baseline.owner',
            'session': {
                'path': str(live_session),
                'name': 'sess-base',
                'probe': {'backend': 'tmux', 'argv': [str(good_probe), 'check']}
            }
        },
        # Future schema version 2 with terminal session and canary probe
        'opaque-future-v2': {
            'schema_version': 2,
            'scope': scope_shared,
            'estimate': 10,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'future-v2.owner',
            'session': {
                'path': str(terminal_session),
                'name': 'future-sess',
                'probe': {'backend': 'future', 'argv': [str(canary_script)]}
            },
            'unknown_meta': {'version_detail': 'future spec', 'tags': ['x', 'y']}
        },
        # Future schema version 99
        'opaque-future-v99': {
            'schema_version': 99,
            'scope': scope_shared,
            'estimate': 7,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'future-v99.owner',
            'extension_blob': [1, 2, 3]
        },
        # Invalid explicit version: 0
        'opaque-invalid-ver-0': {
            'schema_version': 0,
            'scope': scope_shared,
            'estimate': 1,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'inv0.owner'
        },
        # Invalid explicit version: string "1"
        'opaque-invalid-ver-str': {
            'schema_version': '1',
            'scope': scope_shared,
            'estimate': 1,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'invstr.owner'
        },
        # Invalid explicit version: boolean True
        'opaque-invalid-ver-bool': {
            'schema_version': True,
            'scope': scope_shared,
            'estimate': 1,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'invbool.owner'
        },
        # Malformed session: session is not a dict
        'opaque-malformed-session-type': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 2,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'maltype.owner',
            'session': 'invalid-session-string'
        },
        # Malformed session: session has invalid probe argv
        'opaque-malformed-probe-argv': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 3,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'malprobe.owner',
            'session': {
                'path': str(terminal_session),
                'name': 'mal-sess',
                'probe': {'backend': 'tmux', 'argv': []}
            }
        }
    }

    (root / 'ledger.json').write_text(json.dumps(opaque_ledger))
    ledger = u.Reservations(root)

    # Assert helper method identifies opaque vs understood
    assert ledger.is_opaque(opaque_ledger['opaque-future-v2'])
    assert ledger.is_opaque(opaque_ledger['opaque-future-v99'])
    assert ledger.is_opaque(opaque_ledger['opaque-invalid-ver-0'])
    assert ledger.is_opaque(opaque_ledger['opaque-invalid-ver-str'])
    assert ledger.is_opaque(opaque_ledger['opaque-invalid-ver-bool'])
    assert ledger.is_opaque(opaque_ledger['opaque-malformed-session-type'])
    assert ledger.is_opaque(opaque_ledger['opaque-malformed-probe-argv'])
    assert not ledger.is_opaque(opaque_ledger['understood-baseline'])

    # Totals inspection emits concise warning to stderr and counts all opaque entries
    err_stream = io.StringIO()
    with redirect_stderr(err_stream):
        totals = ledger.totals(report())
    warn_text = err_stream.getvalue()

    # Total should be: 5 (baseline) + 10 (v2) + 7 (v99) + 1 (v0) + 1 (vstr) + 1 (vbool) + 2 (maltype) + 3 (malprobe) = 30
    assert totals == {'short': 30, 'weekly': 30}, f"expected 30, got {totals}"

    # Verify canary probe was never called
    assert not canary_log.exists(), "canary probe was invoked for an opaque entry!"

    # Verify concise diagnostics in stderr
    for key in ['opaque-future-v2', 'opaque-future-v99', 'opaque-invalid-ver-0',
                'opaque-invalid-ver-str', 'opaque-invalid-ver-bool',
                'opaque-malformed-session-type', 'opaque-malformed-probe-argv']:
        assert f"warning: reservation {key}:" in warn_text, f"missing warning for {key}"

    # Verify unrelated admission preserves complete opaque entries including unknown fields
    gate = ledger.admit(report(), cfg, 5)
    assert gate['decision'] == 'admitted', gate
    new_token = gate['reservation_id']

    disk_data = json.loads((root / 'ledger.json').read_text())
    assert disk_data['opaque-future-v2']['unknown_meta'] == {'version_detail': 'future spec', 'tags': ['x', 'y']}
    assert disk_data['opaque-future-v99']['extension_blob'] == [1, 2, 3]
    assert 'opaque-future-v2' in disk_data
    assert 'opaque-malformed-session-type' in disk_data
    assert new_token in disk_data

    # Verify release of unrelated token preserves opaque entries
    ledger.release(new_token)
    disk_after_release = json.loads((root / 'ledger.json').read_text())
    assert new_token not in disk_after_release
    assert 'opaque-future-v2' in disk_after_release
    assert disk_after_release['opaque-future-v2']['unknown_meta'] == {'version_detail': 'future spec', 'tags': ['x', 'y']}

# ---------------------------------------------------------------------------
# Test 3: Accounting core validation: unusable accounting fails safely
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)
    ledger = u.Reservations(root)

    bad_payloads = [
        # Non-JSON
        ('broken-json', 'not valid json {{{'),
        # Top-level not a dict
        ('top-level-list', json.dumps([1, 2, 3])),
        ('top-level-string', json.dumps('invalid-ledger')),
        ('empty-token', json.dumps({'': {'scope': 's', 'estimate': 5, 'windows': {}, 'owner': 'a.owner'}})),
        ('whitespace-token', json.dumps({'   ': {'scope': 's', 'estimate': 5, 'windows': {}, 'owner': 'a.owner'}})),
        # Missing or empty scope
        ('missing-scope', json.dumps({'tok': {'estimate': 5, 'windows': {}, 'owner': 'a.owner'}})),
        ('empty-scope', json.dumps({'tok': {'scope': '', 'estimate': 5, 'windows': {}, 'owner': 'a.owner'}})),
        ('whitespace-scope', json.dumps({'tok': {'scope': '   ', 'estimate': 5, 'windows': {}, 'owner': 'a.owner'}})),
        ('non-string-scope', json.dumps({'tok': {'scope': 123, 'estimate': 5, 'windows': {}, 'owner': 'a.owner'}})),
        # Invalid estimate: negative, boolean, non-finite, non-numeric
        ('negative-estimate', json.dumps({'tok': {'scope': 's', 'estimate': -1, 'windows': {}, 'owner': 'a.owner'}})),
        ('boolean-estimate', json.dumps({'tok': {'scope': 's', 'estimate': True, 'windows': {}, 'owner': 'a.owner'}})),
        ('string-estimate', json.dumps({'tok': {'scope': 's', 'estimate': '5', 'windows': {}, 'owner': 'a.owner'}})),
        ('nan-estimate', '{"tok": {"scope": "s", "estimate": NaN, "windows": {}, "owner": "a.owner"}}'),
        ('inf-estimate', '{"tok": {"scope": "s", "estimate": Infinity, "windows": {}, "owner": "a.owner"}}'),
        # Invalid windows mapping
        ('non-dict-windows', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': [1, 2], 'owner': 'a.owner'}})),
        ('invalid-window-reset', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': {'short': 'not-a-timestamp'}, 'owner': 'a.owner'}})),
        ('invalid-window-reset-no-tz', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': {'short': '2030-01-01T00:00:00'}, 'owner': 'a.owner'}})),
        # Missing or unsafe owner
        ('missing-owner', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': {}, 'owner': ''}})),
        ('traversal-owner', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': {}, 'owner': '../../etc/passwd'}})),
        ('subpath-owner', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': {}, 'owner': 'sub/owner.file'}})),
        ('dot-owner', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': {}, 'owner': '.'}})),
        ('dotdot-owner', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': {}, 'owner': '..'}})),
        ('backslash-owner', json.dumps({'tok': {'scope': 's', 'estimate': 5, 'windows': {}, 'owner': 'a\\b.owner'}})),
    ]

    for label, payload in bad_payloads:
        (root / 'ledger.json').write_text(payload)
        before_bytes = (root / 'ledger.json').read_bytes()

        # totals() must refuse with RuntimeError
        try:
            ledger.totals(report())
        except RuntimeError as exc:
            assert 'usage reservation ledger is malformed' in str(exc)
        else:
            raise AssertionError(f"case {label}: totals() did not fail on corrupt ledger")

        # admit() must refuse with RuntimeError
        try:
            ledger.admit(report(), cfg, 5)
        except RuntimeError as exc:
            assert 'usage reservation ledger is malformed' in str(exc)
        else:
            raise AssertionError(f"case {label}: admit() did not fail on corrupt ledger")

        # Storage must remain untouched
        after_bytes = (root / 'ledger.json').read_bytes()
        assert before_bytes == after_bytes, f"case {label}: ledger bytes were modified on failure!"

# ---------------------------------------------------------------------------
# Test 4: Inspection preserves storage (absent ledger and mixed ledger)
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'absent_ledger'
    ledger = u.Reservations(root)

    # Calling totals on absent ledger must NOT create ledger.json or ledger.lock or root dir
    totals = ledger.totals(report())
    assert totals == {'short': 0, 'weekly': 0}
    assert not (root / 'ledger.json').exists(), "absent ledger was created by totals()"
    assert not (root / 'ledger.lock').exists(), "absent ledger.lock was created by totals()"

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'mixed_ledger'
    root.mkdir(parents=True, mode=0o700)
    fd1 = os.open(root / 'v1.owner', os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd1, fcntl.LOCK_EX | fcntl.LOCK_NB)

    initial_content = json.dumps({
        'v1': {'schema_version': 1, 'scope': scope_shared, 'estimate': 5,
               'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
               'owner': 'v1.owner'},
        'v2': {'schema_version': 2, 'scope': scope_shared, 'estimate': 5,
               'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
               'owner': 'v2.owner'}
    }, indent=2)
    (root / 'ledger.json').write_text(initial_content)
    raw_bytes = (root / 'ledger.json').read_bytes()

    ledger = u.Reservations(root)
    totals = ledger.totals(report())
    assert totals == {'short': 10, 'weekly': 10}
    assert (root / 'ledger.json').read_bytes() == raw_bytes, "inspection modified ledger.json bytes!"
    os.close(fd1)

# ---------------------------------------------------------------------------
# Test 5: Reset-window and null-window matching
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    root.mkdir(parents=True, mode=0o700)
    fd_fixed = os.open(root / 'fixed.owner', os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd_fixed, fcntl.LOCK_EX | fcntl.LOCK_NB)
    fd_null = os.open(root / 'null.owner', os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd_null, fcntl.LOCK_EX | fcntl.LOCK_NB)

    ledger_data = {
        'with-fixed-resets': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 5,
            'windows': {'short': '2030-01-01T00:00:00Z', 'weekly': '2030-01-07T00:00:00Z'},
            'owner': 'fixed.owner'
        },
        'with-null-resets': {
            'schema_version': 1,
            'scope': scope_shared,
            'estimate': 3,
            'windows': {'short': None, 'weekly': None},
            'owner': 'null.owner'
        }
    }
    (root / 'ledger.json').write_text(json.dumps(ledger_data))
    ledger = u.Reservations(root)

    # Initial report: matches fixed reset timestamps
    totals1 = ledger.totals(report())
    assert totals1 == {'short': 8, 'weekly': 8}

    # Short window rolled to next day: fixed-reset entry rolls off short bucket,
    # but null-reset entry matches both!
    rolled_rep = report()
    rolled_rep['windows'][0]['resets_at'] = '2030-01-02T00:00:00Z'
    totals2 = ledger.totals(rolled_rep)
    assert totals2 == {'short': 3, 'weekly': 8}
    os.close(fd_fixed)
    os.close(fd_null)

print('ok - tolerant ledger decoding, accounting validation and opaque-entry preservation')
PY
