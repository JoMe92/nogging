#!/usr/bin/env bash
# Atomic headroom and owner-lifecycle regression tests (TASK-GSU-003).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$here" <<'PY'
import datetime as dt
import json
import multiprocessing as mp
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
def report(account='account-a', group='shared'):
    return dict(provider='codex', account=account, model_group=group,
                windows=[dict(bucket=b, status='known', reason=None,
                              used_percent=87, resets_at=r)
                         for b, r in [('short', '2030-01-01T00:00:00Z'),
                                      ('weekly', '2030-01-07T00:00:00Z')]])

def compete(root, barrier, release, queue):
    ledger = u.Reservations(root)
    barrier.wait()
    gate = ledger.admit(report(), cfg, 5)
    queue.put(gate)
    release.wait(15)  # keep admitted pending owner alive until both decisions

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp) / 'ledger'
    barrier, release, queue = mp.Barrier(2), mp.Event(), mp.Queue()
    workers = [mp.Process(target=compete, args=(root, barrier, release, queue)) for _ in range(2)]
    for worker in workers: worker.start()
    gates = [queue.get(timeout=10) for _ in workers]
    assert sorted(g['decision'] for g in gates) == ['admitted', 'denied'], gates
    denied = next(g for g in gates if g['decision'] == 'denied')
    assert denied['reserved_percent'] == 5 and denied['retry_after'] == '2030-01-07T00:00:00Z'
    ledger = u.Reservations(root)
    assert ledger.admit(report('account-b'), cfg, 5)['decision'] == 'admitted'
    assert ledger.admit(report(group='other'), cfg, 5)['decision'] == 'admitted'
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    assert all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in root.iterdir())
    content = (root / 'ledger.json').read_text()
    assert 'account-a' not in content and 'account-b' not in content and 'shared' not in content
    release.set()
    for worker in workers:
        worker.join(10)
        assert worker.exitcode == 0
    # Dead pending owners are reclaimed without an age timeout.
    assert ledger.totals(report()) == {'short': 0, 'weekly': 0}
    gate = ledger.admit(report(), cfg, 5)
    token = gate['reservation_id']
    assert ledger.admit(report(), cfg, 5)['decision'] == 'denied'
    # A short reset releases only the short bucket, never the weekly bucket.
    rolled = report()
    rolled['windows'][0]['resets_at'] = '2030-01-02T00:00:00Z'
    assert ledger.totals(rolled) == {'short': 0, 'weekly': 5}
    ledger.release(token)
    assert ledger.admit(report(), cfg, 5)['decision'] == 'admitted'
    # A released kernel owner lock marks a pending reservation stale.
    entries = json.loads((root / 'ledger.json').read_text())
    for key in entries: ledger.finish(key)
    assert ledger.totals(report()) == {'short': 0, 'weekly': 0}
    # Session binding survives launcher death, terminal and vanished owners clear.
    tmux = Path(temp) / 'tmux'
    live = Path(temp) / 'live'
    tmux.write_text('#!/bin/sh\ntest -f "' + str(live) + '"\n')
    tmux.chmod(0o700)
    live.touch()
    path = Path(temp) / 'session.json'
    path.write_text(json.dumps({'state': 'running'}))
    token = ledger.admit(report(), cfg, 5)['reservation_id']
    ledger.bind(token, path, 'session', str(tmux), 'test')
    ledger.finish(token)
    assert ledger.totals(report()) == {'short': 5, 'weekly': 5}
    live.unlink()
    before = (root / 'ledger.json').read_bytes()
    assert ledger.totals(report()) == {'short': 0, 'weekly': 0}
    assert (root / 'ledger.json').read_bytes() == before
    token = ledger.admit(report(), cfg, 5)['reservation_id']
    live.touch()
    ledger.bind(token, path, 'session', str(tmux), 'test')
    path.write_text(json.dumps({'state': 'stopped'}))
    assert ledger.totals(report()) == {'short': 0, 'weekly': 0}
    # Unknown observations remain unknown; reservations cannot disappear when
    # a fresh observation arrives after an unknown-admitted launch.
    unknown = report()
    for w in unknown['windows']:
        w.update(status='unknown', reason='missing', used_percent=None, resets_at=None)
    gate = ledger.admit(unknown, cfg, 5)
    assert gate['decision'] == 'unknown-admitted' and gate['fits'] is None
    assert ledger.admit(report(), cfg, 5)['decision'] == 'denied'
    ledger.release(gate['reservation_id'])
    # Unknown accounts cannot gain independent headroom by changing source dirs.
    anonymous = report(account=None, group=None)
    with patch.dict(os.environ, {'CODEX_HOME': '/source-a'}):
        token = ledger.admit(anonymous, cfg, 5)['reservation_id']
    with patch.dict(os.environ, {'CODEX_HOME': '/source-b'}):
        assert ledger.admit(anonymous, cfg, 5)['decision'] == 'denied'
    ledger.release(token)
    # Corruption must refuse rather than erase live reservations.
    (root / 'ledger.json').write_text('broken')
    try: ledger.admit(report(), cfg, 5)
    except RuntimeError: pass
    else: raise AssertionError('corrupt ledger admitted launch')
print('ok - concurrent final slot, independent scopes, reset buckets, privacy, owner recovery and unknown usage')
PY
