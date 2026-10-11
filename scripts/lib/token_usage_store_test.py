"""Storage contract tests; real embedded Dolt checks run when installed."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

from token_usage_store import Store, StoreError, fact

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader('nogg_storage_test', str(ROOT / 'scripts/nogg'))
spec = importlib.util.spec_from_loader(loader.name, loader)
nogg = importlib.util.module_from_spec(spec)
import sys
sys.modules[loader.name] = nogg
loader.exec_module(nogg)


def event(**changes):
    return dict(source_id='codex:conversation', event_id='response', revision='first',
                source_ordinal=0, input_tokens=12, output_tokens=3, **changes)


class IdentityTests(unittest.TestCase):
    def test_allowlist_and_unknowns(self):
        identity, content, data = fact('usage_events', event())
        self.assertIsNone(data['cache_write_tokens'])
        self.assertEqual(fact('usage_events', dict(reversed(list(event().items()))))[:2], (identity, content))
        for change in ({'transcript': 'private'}, {'path': '/copied'}, {'device_id': 'importer'},
                       {'input_tokens': True}, {'input_tokens': -1}, {'source_ordinal': None},
                       {'raw_usage': {'secret': 1}}):
            with self.assertRaises(StoreError):
                fact('usage_events', event() | change)
        self.assertEqual(fact('usage_events', event() | {'cache_read_tokens': 0})[2]['cache_read_tokens'], 0)


@unittest.skipUnless(shutil.which('dolt'), 'embedded Dolt not installed')
class DoltTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nogg-usage-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'main'
        self.repo.mkdir()
        self.git('init', '-b', 'develop')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.org', 'commit', '--allow-empty', '-m', 'init')
        self.store = Store(self.repo, nogg.canonical_repository_state)
        self.meta = self.store.initialize()

    def git(self, *args):
        subprocess.run(['git', '-C', str(self.repo), *args], check=True, capture_output=True)

    def test_worktrees_revisions_collisions_and_transactions(self):
        linked = self.root / 'linked'
        self.git('worktree', 'add', '-b', 'linked', str(linked))
        other = Store(linked, nogg.canonical_repository_state)
        self.assertEqual(other.database, self.store.database)
        device = self.store.device()
        self.assertEqual(device, other.device())
        self.assertEqual(self.store.append([('usage_events', event())], {'codex:conversation': device}), 2)
        before = self.store._dolt('log', '-n', '1')
        self.assertEqual(other.append([('usage_events', event())]), 0)
        self.assertEqual(before, self.store._dolt('log', '-n', '1'))
        revised = event() | {'revision': 'final', 'source_ordinal': 2, 'input_tokens': 20}
        older = event() | {'revision': 'intermediate', 'source_ordinal': 1, 'input_tokens': 15}
        self.store.append([('usage_events', revised), ('usage_events', older)])
        self.assertEqual(self.store.query('SELECT input_tokens FROM current_usage_events'), [{'input_tokens': 20}])
        for collision in (event() | {'input_tokens': 99}, event() | {'revision': 'different'}):
            with self.assertRaises(StoreError):
                self.store.append([('usage_events', event() | {'event_id': 'new'}), ('usage_events', collision)])
        self.assertEqual(self.store.query('SELECT count(*) AS n FROM usage_events'), [{'n': 3}])
        # Exercise embedded SQL rollback itself, beyond Python preflight.
        with self.assertRaises(StoreError):
            self.store._dolt('sql', sql="SET autocommit=0; START TRANSACTION; INSERT INTO devices VALUES ('rollback', 'test'); INSERT INTO absent_table VALUES (1); COMMIT;")
        self.assertEqual(self.store.query("SELECT * FROM devices WHERE device_id='rollback'"), [])
        self.assertEqual(os.stat(self.store.root).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.store.root / 'device-id').st_mode & 0o777, 0o600)

    def test_crash_replay_and_serialized_collectors(self):
        reached = threading.Event()
        finished = threading.Event()
        def collector():
            reached.set()
            with self.store.locked():
                finished.set()
        with self.store.locked():
            worker = threading.Thread(target=collector)
            worker.start()
            self.assertTrue(reached.wait(2))
            self.assertFalse(finished.wait(0.1))
        worker.join(2)
        self.assertTrue(finished.is_set())
        original = self.store._commit
        def crash(_):
            raise StoreError('simulated crash before history commit')
        self.store._commit = crash
        with self.assertRaises(StoreError):
            self.store.append([('usage_events', event())])
        self.store._commit = original
        self.assertTrue(self.store.query('SELECT * FROM dolt_status'))
        self.assertEqual(self.store.append([('usage_events', event())]), 0)
        self.assertEqual(self.store.query('SELECT * FROM dolt_status'), [])
        for table in ('session_segments', 'lifecycle_events', 'attribution_events'):
            self.store.append([(table, dict(source_id='runtime:session', event_id=table,
                revision='start', source_ordinal=0))])
            self.assertEqual(self.store.query(f'SELECT COUNT(*) AS n FROM current_{table}'), [{'n': 1}])

    def test_clone_dedup_distinct_devices_and_schema_refusal(self):
        self.store.append([('usage_events', event())])
        device = self.store.device()
        second = Store(self.repo, lambda _: {'state_dir': str(self.root / 'second/.nogging/state')})
        second.root.mkdir(parents=True)
        remote = self.root / 'remote'
        remote.mkdir()
        self.store._dolt('remote', 'add', 'test', remote.as_uri())
        self.store._dolt('push', 'test', 'main')
        subprocess.run(['dolt', 'clone', remote.as_uri(), str(second.database)], check=True, capture_output=True)
        self.assertEqual(second.initialize(), self.meta)
        second_device = second.device()
        self.assertNotEqual(device, second_device)
        self.assertEqual(second.append([('usage_events', event())]), 0)
        self.store.append([], {'stream': device})
        with self.assertRaises(StoreError):
            self.store.append([], {'stream': second_device})
        second.append([('usage_events', event() | {'event_id': 'independent'})])
        self.assertEqual(second.query('SELECT COUNT(*) AS n FROM current_usage_events'), [{'n': 2}])
        second._dolt('sql', sql='UPDATE store_meta SET schema_version=999;')
        before = second._dolt('diff')
        with self.assertRaises(StoreError):
            second.initialize()
        with self.assertRaises(StoreError):
            second.append([('usage_events', event())])
        self.assertEqual(before, second._dolt('diff'))


if __name__ == '__main__':
    unittest.main()
