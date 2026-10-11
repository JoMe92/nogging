"""Host collector tests: resumes, transitions, crashes, outages, conflicts."""
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import token_usage_collect as tc
from token_usage_store import Store, StoreError, StoreUnavailable, fact

T0 = '2026-10-11T10:00:00+00:00'
T1 = '2026-10-11T11:00:00+00:00'
NOW = dt.datetime(2026, 10, 11, 12, 0, tzinfo=dt.timezone.utc)


class FakeStore:
    """Store append semantics in memory: replay no-op, collisions refuse."""

    def __init__(self, root):
        self.root = Path(root)
        self.rows = {}
        self.unavailable = False

    def initialize(self):
        if self.unavailable:
            raise StoreUnavailable('down')

    def device(self):
        return None

    def append(self, records, owners=None):
        if self.unavailable:
            raise StoreUnavailable('down')
        prepared = [(t, *fact(t, v)) for t, v in records]
        for table, identity, content, _ in prepared:
            if self.rows.get((table, identity), content) != content:
                raise StoreError('conflicting fact revision')
        added = 0
        for table, identity, content, data in prepared:
            if (table, identity) not in self.rows:
                self.rows[(table, identity)] = content
                self.rows.setdefault('data', []).append((table, data))
                added += 1
        return added

    def facts(self, table):
        return [d for t, d in self.rows.get('data', []) if t == table]


def claude_line(message_id, model, ts, output=10):
    return json.dumps({'type': 'assistant', 'sessionId': 'conv', 'timestamp': ts,
                       'message': {'id': message_id, 'role': 'assistant', 'model': model,
                                   'usage': {'input_tokens': 5, 'cache_read_input_tokens': 100,
                                             'cache_creation_input_tokens': 7, 'output_tokens': output}}})


def record(name, started, **extra):
    rec = {'name': name, 'started_at': started, 'agent': 'claude', 'state': 'running',
           'role': 'lead', 'bead_id': 'SPEC-x', 'usage_segment_id': f'seg-{name}',
           'usage_attribution': [{'at': started, 'task_id': 'TASK-1', 'bead_id': 'SPEC-x',
                                  'change_id': 'change-a', 'role': 'lead', 'complexity': 'standard',
                                  'complexity_source': 'launch', 'vocabulary_version': '1'}]}
    rec.update(extra)
    return rec


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.store = FakeStore(self.tmp / 'usage')
        self.collector = tc.Collector(self.store)
        self.transcript = self.tmp / 'conv.jsonl'
        self.source = {'runtime': 'claude', 'id': 'conv', 'path': str(self.transcript)}
        self.segments = [('seg-a', T0), ('seg-b', T1)]

    def write(self, *lines, partial=''):
        self.transcript.write_text(''.join(line + '\n' for line in lines) + partial)

    def collect(self, rec, live=True, **kwargs):
        return self.collector.collect([{'record': rec, 'live': live, 'source': self.source,
                                        'segments': self.segments}], now=kwargs.pop('now', NOW), **kwargs)

    def usage(self):
        return sorted((d['event_id'], d['segment_id'], d['model'], d['source_ordinal'])
                      for d in self.store.facts('usage_events'))

    def test_resume_and_model_transition_charge_each_event_once(self):
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'),
                   partial=claude_line('m2', 'claude-b', '2026-10-11T11:30:00.000Z')[:40])
        first = self.collect(record('a', T0))
        self.assertEqual(first['sessions']['a']['diagnostics'], {'partial_final_line': 1})
        self.assertEqual(self.usage(), [('m1', 'seg-a', 'claude-a', 0)])
        # The exact conversation resumes in a second supervised segment.
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'),
                   claude_line('m2', 'claude-b', '2026-10-11T11:30:00.000Z'))
        self.collect(record('b', T1))
        self.collect(record('b', T1))
        self.assertEqual(self.usage(), [('m1', 'seg-a', 'claude-a', 0), ('m2', 'seg-b', 'claude-b', 0)])
        inputs = [d['input_tokens'] for d in self.store.facts('usage_events')]
        self.assertEqual(inputs, [112, 112])  # cache read/write counted once inside input

    def test_streaming_revision_keeps_ordinals_across_passes(self):
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z', output=3))
        self.collect(record('a', T0))
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z', output=3),
                   claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z', output=9))
        self.collect(record('a', T0))
        self.assertEqual(self.usage(), [('m1', 'seg-a', 'claude-a', 0), ('m1', 'seg-a', 'claude-a', 1)])

    def test_codex_turn_context_survives_later_passes(self):
        rollout = self.tmp / 'rollout.jsonl'
        lines = [{'type': 'session_meta', 'payload': {'session_id': 'thread', 'model_provider': 'openai'}},
                 {'type': 'turn_context', 'payload': {'model': 'gpt-x', 'effort': 'high'}},
                 {'type': 'token_usage_record', 'timestamp': '2026-10-11T10:10:00Z',
                  'payload': {'response_id': 'r1', 'usage': {'input_tokens': 50, 'output_tokens': 5}}},
                 {'type': 'event_msg', 'payload': {'type': 'token_count'}}]
        rollout.write_text(''.join(json.dumps(l) + '\n' for l in lines))
        self.source = {'runtime': 'codex', 'id': 'thread', 'path': str(rollout)}
        rec = record('a', T0, agent='codex')
        self.collect(rec)
        lines.append({'type': 'token_usage_record', 'timestamp': '2026-10-11T10:20:00Z',
                      'payload': {'response_id': 'r2', 'usage': {'input_tokens': 60, 'output_tokens': 6}}})
        rollout.write_text(''.join(json.dumps(l) + '\n' for l in lines))
        self.collect(rec)
        self.assertEqual([(d['event_id'], d['model'], d['effort']) for d in self.store.facts('usage_events')],
                         [('r1', 'gpt-x', 'high'), ('r2', 'gpt-x', 'high')])

    def test_outage_spools_then_imports_exactly_once(self):
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'))
        self.store.unavailable = True
        report = self.collect(record('a', T0))
        self.assertIn('unavailable', report['error'])
        self.assertEqual((report['spooled_batches'], self.store.facts('usage_events')), (1, []))
        stopped = record('a', T0, state='stopped', ended_at=T1)
        again = self.collect(stopped, live=False)  # nothing new except the exit fact
        self.assertEqual(again['spooled_batches'], 2)
        status = json.loads((self.collector.root / 'status.json').read_text())
        self.assertIsNone(status.get('last_success_at'))
        self.store.unavailable = False
        recovered = self.collect(stopped, live=False)
        self.assertEqual((recovered['error'], recovered['spooled_batches']), (None, 0))
        self.assertEqual(len(self.store.facts('usage_events')), 1)
        self.collect(stopped, live=False)
        self.assertEqual(len(self.store.facts('usage_events')), 1)

    def test_crash_between_spool_and_ledger_replays_idempotently(self):
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'))
        real = tc.Collector._write
        def crash(path, value):
            if path.parent.name == 'ledger':
                raise OSError('crash before checkpoint')
            return real(path, value)
        self.store.unavailable = True
        stopped = record('a', T0, state='stopped', ended_at=T1)
        with mock.patch.object(tc.Collector, '_write', staticmethod(crash)):
            with self.assertRaises(OSError):
                self.collect(stopped, live=False)
        self.store.unavailable = False
        self.collect(stopped, live=False)
        self.assertEqual(len(self.store.facts('usage_events')), 1)
        self.assertEqual(len(self.store.facts('lifecycle_events')), 2)  # start + exit, once each

    def test_crash_after_import_before_spool_removal(self):
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'))
        with mock.patch.object(Path, 'unlink', side_effect=OSError('crash')):
            with self.assertRaises(OSError):
                self.collect(record('a', T0))
        self.collect(record('a', T0))
        self.assertEqual(len(self.store.facts('usage_events')), 1)

    def test_conflict_is_quarantined_without_blocking_later_facts(self):
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'),
                   claude_line('m2', 'claude-a', '2026-10-11T10:40:00.000Z'))
        facts, _ = tc.source_facts(self.source, self.segments)
        identity, _, _ = fact(*facts[0])
        self.store.rows[('usage_events', identity)] = 'different-content'
        report = self.collect(record('a', T0))
        self.assertEqual(report['quarantined_batches'], 1)
        self.assertEqual([d['event_id'] for d in self.store.facts('usage_events')], ['m2'])
        quarantined = json.loads(next((self.collector.root / 'quarantine').glob('*.json')).read_text())
        self.assertEqual(len(quarantined['rejected']), 1)

    def test_lifecycle_runtime_evidence(self):
        self.write()
        live = self.collect(record('a', T0))
        heartbeat = [d for d in self.store.facts('lifecycle_events') if d['kind'] == 'heartbeat']
        self.assertEqual(heartbeat[0]['source_timestamp'], '2026-10-11T12:00:00.000000Z')
        # Unobserved crash: bound by last liveness evidence, not collection time.
        crashed = record('a', T0, state='failed', exit_reason='tmux session vanished during a reap',
                         ended_at='2026-10-11T15:00:00+00:00')
        self.collect(crashed, live=False, now=NOW + dt.timedelta(hours=5))
        self.collect(crashed, live=False, now=NOW + dt.timedelta(hours=6))
        exits = [d for d in self.store.facts('lifecycle_events') if d['event_id'] == 'exit']
        self.assertEqual([(d['kind'], d['source_timestamp']) for d in exits],
                         [('exit_unobserved', '2026-10-11T12:00:00.000000Z')])
        self.assertIsNone(live['error'])

    def test_observed_stop_keeps_monotonic_only_on_same_boot(self):
        self.write()
        for name, end_boot, expected in (('same', 'boot-1', 900), ('other', 'boot-2', None)):
            rec = record(name, T0, state='stopped', ended_at=T1, usage_boot_id='boot-1',
                         usage_end_boot_id=end_boot, usage_monotonic_start_ms=100,
                         usage_monotonic_end_ms=900)
            self.collect(rec, live=False)
            exit_fact = [d for d in self.store.facts('lifecycle_events')
                         if d['event_id'] == 'exit' and d['segment_id'] == f'seg-{name}'][0]
            self.assertEqual((exit_fact['kind'], exit_fact['monotonic_ms'], exit_fact['source_timestamp']),
                             ('exit', expected, '2026-10-11T11:00:00.000000Z'))

    def test_attribution_boundaries_and_legacy_records(self):
        self.write()
        rec = record('a', T0)
        rec['usage_attribution'].append(dict(rec['usage_attribution'][0], at=T1, change_id='change-b',
                                             bead_id=None, task_id=None))
        legacy = {'name': 'old', 'started_at': T0, 'agent': 'claude', 'state': 'stopped',
                  'ended_at': T1, 'bead_id': 'SPEC-old', 'role': 'lead', 'requested_model': None}
        self.collector.collect([{'record': rec, 'live': True, 'source': self.source, 'segments': self.segments},
                                {'record': legacy, 'live': False, 'source': None}], now=NOW)
        rows = sorted((d['segment_id'], d['event_id'], d['change_id'], d['task_id'], d['complexity'],
                       d['complexity_source']) for d in self.store.facts('attribution_events'))
        legacy_seg = tc.segment_id(legacy)
        self.assertEqual(rows, sorted([
            ('seg-a', 'boundary:0', 'change-a', 'TASK-1', 'standard', 'launch'),
            ('seg-a', 'boundary:1', 'change-b', None, 'standard', 'launch'),
            (legacy_seg, 'boundary:0', None, None, 'unknown', 'legacy')]))
        self.assertEqual(tc.segment_id(legacy), legacy_seg)  # stable for replay

    def test_missing_and_unsupported_sources_are_diagnosed(self):
        report = self.collector.collect([
            {'record': record('a', T0), 'live': True, 'source': self.source, 'segments': []},
            {'record': record('p', T0, agent='pi'), 'live': True, 'source': {'runtime': 'pi', 'id': 'x'}},
            {'record': record('n', T0), 'live': True, 'source': None}], now=NOW)
        self.assertEqual({k: v['diagnostics'] for k, v in report['sessions'].items()},
                         {'a': {'source_missing': 1}, 'p': {'unsupported_runtime': 1},
                          'n': {'no_exact_source': 1}})
        self.assertEqual(len(self.store.facts('session_segments')), 3)

    def test_no_transcript_text_is_spooled(self):
        line = json.loads(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'))
        line['message']['content'] = [{'type': 'text', 'text': 'SECRET PROMPT'}]
        self.transcript.write_text(json.dumps(line) + '\n')
        self.store.unavailable = True
        self.collect(record('a', T0))
        spooled = ''.join(p.read_text() for p in (self.collector.root / 'spool').glob('*.json'))
        self.assertNotIn('SECRET PROMPT', spooled)
        self.assertEqual(oct((self.collector.root / 'spool').stat().st_mode & 0o777), '0o700')


    def test_active_record_missing_from_tmux_records_no_exit(self):
        self.write()
        self.collect(record('a', T0))
        report = self.collect(record('a', T0), live=False, now=NOW + dt.timedelta(minutes=1))
        self.assertEqual(report['sessions']['a']['diagnostics'], {'liveness_unconfirmed': 1})
        self.assertEqual([d for d in self.store.facts('lifecycle_events') if d['event_id'] == 'exit'], [])
        # The concurrent stop then records the observed exit, not a crash bound.
        stopped = record('a', T0, state='stopped', ended_at=T1, usage_boot_id='b', usage_end_boot_id='b',
                         usage_monotonic_end_ms=5)
        self.collect(stopped, live=False)
        retired = dict(stopped, state='retired')
        shutil.rmtree(self.collector.root / 'segments')   # lost local state recomputes the same exit
        self.collect(retired, live=False)
        exits = [(d['kind'], d['monotonic_ms']) for d in self.store.facts('lifecycle_events') if d['event_id'] == 'exit']
        self.assertEqual(exits, [('exit', 5)])
        self.assertEqual(self.pending_quarantine(), 0)

    def pending_quarantine(self):
        return self.collector.pending()['quarantined_batches']

    def test_busy_collector_times_out(self):
        self.write()
        with self.collector.locked(0):
            with self.assertRaises(tc.CollectorBusy):
                self.collect(record('a', T0), lock_timeout=0)

    def test_bad_fact_and_bad_source_stay_isolated(self):
        line = json.loads(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'))
        line['duration_ms'] = 1.5   # not an allowlisted integer counter
        self.transcript.write_text(json.dumps(line) + '\n' + claude_line('m2', 'claude-a', '2026-10-11T10:40:00.000Z') + '\n')
        locked = self.tmp / 'locked.jsonl'
        locked.write_text(claude_line('x', 'claude-a', '2026-10-11T10:30:00.000Z') + '\n')
        locked.chmod(0)
        report = self.collector.collect([
            {'record': record('bad', T0), 'live': True, 'segments': [],
             'source': {'runtime': 'claude', 'id': 'other', 'path': str(locked)}},
            {'record': record('a', T0), 'live': True, 'source': self.source, 'segments': self.segments}], now=NOW)
        if os.geteuid() != 0:
            self.assertEqual(report['sessions']['bad']['diagnostics'],
                             {'source_error': 1, 'source_error_type': 'PermissionError'})
        self.assertEqual(report['sessions']['a']['diagnostics'], {'invalid_fact': 1})
        self.assertEqual([d['event_id'] for d in self.store.facts('usage_events')], ['m2'])
        self.assertEqual(self.pending_quarantine(), 1)

    def test_corrupt_ledger_only_replays(self):
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'))
        self.collect(record('a', T0))
        for ledger in (self.collector.root / 'ledger').glob('*.json'):
            ledger.write_text('{corrupt')
        (self.collector.root / 'status.json').write_text('[]')
        self.collect(record('a', T0))
        self.assertEqual(len(self.store.facts('usage_events')), 1)

    def test_persistent_data_failure_is_quarantined_after_attempts(self):
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z'))
        real = self.store.append
        def append(records, owners=None):
            if any(t == 'usage_events' for t, _ in records):
                raise StoreUnavailable('dolt rejected this batch')
            return real(records, owners)
        self.store.append = append
        errors = [self.collect(record('a', T0), now=NOW + dt.timedelta(minutes=i))['error'] for i in range(3)]
        self.assertTrue(errors[0] and errors[1])
        self.assertEqual(self.pending_quarantine(), 1)
        self.assertEqual(self.collector.pending()['spooled_batches'], 0)

    def test_batches_split_and_drain_respects_budget(self):
        self.write(*[claude_line(f'm{i}', 'claude-a', '2026-10-11T10:30:00.000Z') for i in range(120)])
        report = self.collect(record('a', T0), budget_seconds=0)
        self.assertEqual((report['imported'], report['spooled_batches']), (0, 3))
        self.collect(record('a', T0))
        self.assertEqual(len(self.store.facts('usage_events')), 120)

    def test_subsecond_segment_start(self):
        self.segments = [('seg-a', T0), ('seg-b', '2026-10-11T10:30:00.500000+00:00')]
        self.write(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.200Z'),
                   claude_line('m2', 'claude-a', '2026-10-11T10:30:00.700Z'))
        self.collect(record('b', '2026-10-11T10:30:00+00:00', usage_started_at='2026-10-11T10:30:00.500000+00:00'))
        self.assertEqual([(d['event_id'], d['segment_id']) for d in self.store.facts('usage_events')],
                         [('m1', 'seg-a'), ('m2', 'seg-b')])
        start = [d for d in self.store.facts('lifecycle_events') if d['event_id'] == 'start'][0]
        self.assertEqual(start['source_timestamp'], '2026-10-11T10:30:00.500000Z')


@unittest.skipUnless(shutil.which('dolt'), 'dolt not installed')
class DoltCollectionTests(unittest.TestCase):
    def test_real_store_pass_and_replay(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        transcript = tmp / 'conv.jsonl'
        transcript.write_text(claude_line('m1', 'claude-a', '2026-10-11T10:30:00.000Z') + '\n')
        store = Store(tmp, lambda _: {'state_dir': str(tmp / 'state')})
        collector = tc.Collector(store)
        target = {'record': record('a', T0), 'live': True, 'segments': [('seg-a', T0)],
                  'source': {'runtime': 'claude', 'id': 'conv', 'path': str(transcript)}}
        first = collector.collect([target], now=NOW)
        self.assertEqual((first['error'], first['spooled_batches']), (None, 0))
        second = collector.collect([target], now=NOW + dt.timedelta(minutes=5))
        self.assertEqual(second['imported'], 1)  # only the new heartbeat revision
        rows = store.query('SELECT COUNT(*) AS n, SUM(input_tokens) AS i FROM current_usage_events')
        self.assertEqual((int(rows[0]['n']), int(rows[0]['i'])), (1, 112))
        beats = store.query("SELECT COUNT(*) AS n FROM current_lifecycle_events WHERE event_id='liveness'")
        self.assertEqual(int(beats[0]['n']), 1)


if __name__ == '__main__':
    unittest.main()
