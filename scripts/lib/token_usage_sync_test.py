"""Usage sync tests: two offline clones over a file:// Dolt remote."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import token_usage_collect as tc
import token_usage_report as tr
import token_usage_sync as ts
from token_usage_store import Store

DEVICE_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
DEVICE_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'


def usage(source, event, input=100, model='luna'):
    return ('usage_events', {'source_id': source, 'event_id': event, 'revision': 'v1', 'source_ordinal': 0,
                             'source_timestamp': '2026-10-11T10:00:00Z', 'segment_id': None, 'runtime': 'claude',
                             'model': model, 'input_tokens': input, 'output_tokens': 1})


class SyncTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which('dolt'):
            self.skipTest('dolt not installed')
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        env = mock.patch.dict(os.environ, {'DOLT_ROOT_PATH': str(self.tmp / 'dolt-home')})
        env.start()
        self.addCleanup(env.stop)
        (self.tmp / 'dolt-home').mkdir()
        self.remote = self.tmp / 'remote'
        self.remote.mkdir()
        self.a = self.device('a')
        self.a.initialize()
        subprocess.run(['dolt', 'remote', 'add', 'origin', f'file://{self.remote}'], cwd=self.a.database,
                       check=True, capture_output=True)
        self.a.append([usage('claude:a', 'a0')])
        self.assertEqual(self.sync(self.a)['state'], 'synchronized')
        self.b = self.device('b')
        self.b.root.mkdir(parents=True)
        subprocess.run(['dolt', 'clone', f'file://{self.remote}', str(self.b.database)], check=True,
                       capture_output=True)

    def device(self, name):
        return Store(self.tmp, lambda _: {'state_dir': str(self.tmp / name)})

    def sync(self, store, **kwargs):
        return ts.Sync(store, tc.Collector(store), **kwargs).run()

    def events(self, store):
        return sorted(r['event_id'] for r in store.query('SELECT event_id FROM current_usage_events'))

    def remote_events(self):
        probe = self.device('probe')
        if not probe.database.exists():
            probe.root.mkdir(parents=True, exist_ok=True)
            subprocess.run(['dolt', 'clone', f'file://{self.remote}', str(probe.database)], check=True,
                           capture_output=True)
        else:
            subprocess.run(['dolt', 'pull', 'origin', 'main'], cwd=probe.database, capture_output=True)
        return self.events(probe)

    def converge(self, order):
        self.a.append([usage('claude:a', 'a1')])
        self.b.append([usage('claude:b', 'b1', model='opus')])
        for store in order:
            self.assertEqual(self.sync(store)['state'], 'synchronized')
        for store in order[:1]:
            self.assertEqual(self.sync(store)['state'], 'synchronized')
        expected = ['a0', 'a1', 'b1']
        self.assertEqual((self.events(self.a), self.events(self.b), self.remote_events()), (expected,) * 3)
        meta_a, facts_a = tr.load_facts(self.a)
        meta_b, facts_b = tr.load_facts(self.b)
        self.assertEqual(meta_a['project_id'], meta_b['project_id'])
        window = tr.window('2026-10-11', '2026-10-12', tr.dt.datetime.now(tr.dt.timezone.utc))
        totals = lambda m, f: [(r['tokens']['input_tokens'], sorted(r['by_model'])) for r in
                               tr.report(f, m, *window, 'day', {}, window[0])['rows']]
        self.assertEqual(totals(meta_a, facts_a), totals(meta_b, facts_b))
        self.assertEqual(totals(meta_a, facts_a), [(300, ['luna', 'opus'])])

    def test_offline_clones_converge_a_then_b(self):
        self.converge([self.a, self.b])

    def test_offline_clones_converge_b_then_a(self):
        self.converge([self.b, self.a])

    def test_replay_is_noop(self):
        self.b.append([usage('claude:b', 'b1')])
        self.assertEqual(self.sync(self.b)['state'], 'synchronized')
        self.b.append([usage('claude:b', 'b1')])   # identical replay
        status = self.sync(self.b)
        self.assertEqual((status['state'], status['local_only']), ('synchronized', False))
        self.assertEqual(self.events(self.b), ['a0', 'b1'])

    def test_rejected_push_retries_then_succeeds(self):
        self.b.append([usage('claude:b', 'b1')])
        moved = []
        sync = ts.Sync(self.b, tc.Collector(self.b))
        real = sync._default_run
        def run(*args):
            if args[0] == 'push' and not moved:
                moved.append(True)   # another device updates the remote mid-sync
                self.a.append([usage('claude:a', 'a1')])
                self.assertEqual(self.sync(self.a)['state'], 'synchronized')
            return real(*args)
        sync._run = run
        status = sync.run()
        self.assertEqual((status['state'], status['attempts']), ('synchronized', 2))
        self.assertEqual(self.remote_events(), ['a0', 'a1', 'b1'])

    def test_rejections_are_bounded_and_keep_local_facts(self):
        self.b.append([usage('claude:b', 'b1')])
        sync = ts.Sync(self.b, tc.Collector(self.b))
        real = sync._default_run
        sync._run = lambda *args: ((1, '', '! [rejected] main -> main (non-fast-forward)')
                                   if args[0] == 'push' else real(*args))
        status = sync.run()
        self.assertEqual((status['state'], status['attempts']), ('pending', 3))
        self.assertIn('rejected 3 times', status['last_error'])
        self.assertEqual(self.events(self.b), ['a0', 'b1'])

    def test_outage_keeps_local_facts_and_recovers(self):
        self.b.append([usage('claude:b', 'b1')])
        self.remote.rename(self.tmp / 'offline')
        status = self.sync(self.b)
        self.assertEqual((status['state'], status['local_only']), ('pending', True))  # B never synced yet
        self.assertIn('unreachable', status['last_error'])
        self.b.append([usage('claude:b', 'b2')])   # local collection continues
        (self.tmp / 'offline').rename(self.remote)
        self.assertEqual(self.sync(self.b)['state'], 'synchronized')
        self.assertEqual(self.remote_events(), ['a0', 'b1', 'b2'])

    def test_newer_remote_schema_refused_before_merge(self):
        subprocess.run(['dolt', 'sql', '-q', 'UPDATE store_meta SET schema_version=2'], cwd=self.a.database,
                       check=True, capture_output=True)
        subprocess.run(['dolt', 'commit', '-a', '-m', 'future schema', '--author', 'T <t@x>'],
                       cwd=self.a.database, check=True, capture_output=True)
        subprocess.run(['dolt', 'push', 'origin', 'main'], cwd=self.a.database, check=True, capture_output=True)
        self.b.append([usage('claude:b', 'b1')])
        status = self.sync(self.b)
        self.assertEqual(status['state'], 'refused')
        self.assertIn('refusing before merge', status['last_error'])
        self.assertEqual(self.b.check_schema()['schema_version'], 1)
        self.assertEqual(self.events(self.b), ['a0', 'b1'])

    def assert_conflict(self):
        status = self.sync(self.b)
        self.assertEqual(status['state'], 'conflict')
        self.assertTrue(status['conflicts'])
        self.assertFalse(self.b.query('SELECT * FROM dolt_status'))   # merge aborted cleanly
        return status

    def test_identity_collision_retains_both_histories(self):
        self.a.append([usage('claude:shared', 'e', input=1)])
        self.assertEqual(self.sync(self.a)['state'], 'synchronized')
        self.b.append([usage('claude:shared', 'e', input=2)])
        self.assert_conflict()
        mine = self.b.query("SELECT input_tokens FROM current_usage_events WHERE event_id='e'")
        self.assertEqual(int(mine[0]['input_tokens']), 2)
        probe = self.remote_events()
        self.assertIn('e', probe)

    def test_competing_source_ownership_conflicts(self):
        self.a.append([usage('claude:owned', 'x')], owners={'claude:owned': DEVICE_A})
        self.assertEqual(self.sync(self.a)['state'], 'synchronized')
        self.b.append([usage('claude:owned', 'y')], owners={'claude:owned': DEVICE_B})
        status = self.assert_conflict()
        self.assertIn('source_owners', [c['table'] for c in status['conflicts']])

    def test_not_configured_and_pending_spool_drained_first(self):
        lonely = self.device('lonely')
        lonely.initialize()
        self.assertEqual(self.sync(lonely)['state'], 'not_configured')
        collector = tc.Collector(self.b)
        collector._write(collector._dir('spool') / '00000000000000000001-x.json',
                         {'records': [list(usage('claude:b', 'spooled'))], 'owners': {}})
        self.assertEqual(self.sync(self.b)['state'], 'synchronized')
        self.assertIn('spooled', self.remote_events())

    def test_unreadable_remote_metadata_refused_before_merge(self):
        other = self.tmp / 'not-usage'
        other.mkdir()
        subprocess.run(['dolt', 'init', '--name', 'T', '--email', 't@x'], cwd=other, check=True, capture_output=True)
        subprocess.run(['dolt', 'sql', '-q', 'CREATE TABLE notes (id INT PRIMARY KEY)'], cwd=other, check=True,
                       capture_output=True)
        subprocess.run(['dolt', 'commit', '-A', '-m', 'x', '--author', 'T <t@x>'], cwd=other, check=True, capture_output=True)
        subprocess.run(['dolt', 'remote', 'add', 'origin', f'file://{self.tmp / "foreign"}'], cwd=other, check=True,
                       capture_output=True)
        subprocess.run(['dolt', 'push', 'origin', 'main'], cwd=other, check=True, capture_output=True)
        subprocess.run(['dolt', 'remote', 'add', 'foreign', f'file://{self.tmp / "foreign"}'], cwd=self.b.database,
                       check=True, capture_output=True)
        self.b.append([usage('claude:b', 'b1')])
        status = self.sync(self.b, remote='foreign')
        self.assertEqual(status['state'], 'refused')
        self.assertIn('no readable usage store metadata', status['last_error'])
        self.assertEqual(self.events(self.b), ['a0', 'b1'])

    def test_status_file_and_redaction(self):
        status = json.loads((self.a.root / 'sync-status.json').read_text())
        self.assertEqual((status['state'], status['local_only']), ('synchronized', False))
        self.assertEqual(ts.redact_url('https://user:secret@host:8443/org/db?token=x'), 'https://host:8443/org/db')
        self.assertEqual(ts.redact_url('https://user:secret@host:notaport/db'), '<unparseable remote>')
        self.assertNotIn('secret', json.dumps(status))


if __name__ == '__main__':
    unittest.main()
