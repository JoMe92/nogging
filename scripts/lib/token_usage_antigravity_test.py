"""Antigravity adapter tests against synthetic conversation databases.

Fixture counters mirror sanitized agy 1.3.3 observations (input 14427,
output 75, thinking 74; cache-read growth across generations).
"""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest

import token_usage_antigravity as agy
from token_usage_antigravity import AntigravitySourceError, read_conversation
from token_usage_store import Store, fact

CID = '25c92eaa-705f-4808-90e0-34c30ff6f78c'
SECRET = 'PROMPT TEXT MUST NOT LEAK'


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7f
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    if isinstance(value, str):
        value = value.encode()
    return varint(number << 3 | 2) + varint(len(value)) + value


def msg(*fields):
    return b''.join(field(n, v) for n, v in fields if v is not None)


def generation(steps=(), input=14427, output=75, thinking=74, response=1, cache_read=None,
               cache_write=None, model='gemini-3.8-flash-n', provider=24, response_id='resp',
               cascade=CID, root=None, usage=True, error=None):
    stats = msg((1, 1318), (2, input), (3, output), (4, cache_write), (5, cache_read),
                (6, provider), (7, 'msg'), (9, thinking), (10, response), (11, response_id))
    custom = [field(20, msg((1, 'cascade_id'), (2, cascade))),
              field(20, msg((1, 'root_cascade_id'), (2, root or cascade))),
              field(20, msg((1, 'request_id'), (2, SECRET)))]
    chat = msg((1, SECRET), (3, 1318), (4, stats if usage else None),
               (11, msg((1, 2), (2, 500000000))), (12, msg((1, 1), (2, 250000000))),
               (19, model)) + b''.join(custom)
    return msg((1, chat), (2, b''.join(varint(s) for s in steps)), (5, error))


def step(seconds, nanos=0):
    return msg((1, msg((1, seconds - 3))), (7, msg((1, seconds), (2, nanos))), (8, msg((1, seconds + 9))))


class Fixture:
    def __init__(self, root, cid=CID):
        (root / 'conversations').mkdir(parents=True, exist_ok=True)
        self.path = root / 'conversations' / f'{cid}.db'
        self.db = sqlite3.connect(self.path)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA wal_autocheckpoint=0')
        self.db.execute('CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer, metadata blob, step_payload blob)')
        self.db.execute('CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob, size integer)')
        self.db.commit()

    def add(self, idx, data, steps=()):
        for number, seconds in steps:
            self.db.execute('INSERT INTO steps VALUES (?, 0, ?, ?)', (number, step(seconds), SECRET.encode()))
        self.db.execute('INSERT INTO gen_metadata VALUES (?, ?, ?)', (idx, data, len(data)))
        self.db.commit()


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.fx = Fixture(self.root)
        self.addCleanup(self.fx.db.close)

    def read(self, **kwargs):
        return read_conversation(CID, root=self.root, **kwargs)

    def test_normalizes_inference_result_shape(self):
        self.fx.add(0, generation(steps=[1, 2]), steps=[(1, 1791660000), (2, 1791660005)])
        result = self.read()
        self.assertEqual(result.diagnostics, {})
        (table, row), = result.records
        fact(table, row)
        self.assertEqual((row['input_tokens'], row['output_tokens'], row['thinking_tokens']), (14427, 75, 74))
        self.assertEqual(row['input_tokens'] + row['output_tokens'], 14502)  # observed result total
        self.assertEqual((row['cache_read_tokens'], row['cache_write_tokens'], row['provider_total_tokens']), (0, None, None))
        self.assertEqual((row['model'], row['provider'], row['runtime']), ('gemini-3.8-flash-n', 'google-gemini', 'antigravity'))
        self.assertEqual(row['source_timestamp'], '2026-10-10T19:20:05.000000Z')  # latest finished step
        self.assertEqual(row['inference_duration_ms'], 3750)
        self.assertEqual((row['source_id'], row['event_id'], row['revision'], row['source_ordinal']),
                         (f'antigravity:{CID}', 'generation:0', 'resp', 0))
        self.assertIn('cache_write_unreported', row['semantics'])
        self.assertEqual(result.high_water, 0)

    def test_cache_read_is_added_once_and_reported_writes_kept(self):
        self.fx.add(0, generation(steps=[1], input=3779, cache_read=182855, cache_write=7), steps=[(1, 1791660000)])
        (_, row), = self.read().records
        self.assertEqual((row['input_tokens'], row['cache_read_tokens'], row['cache_write_tokens']), (186634, 182855, 7))
        self.assertEqual(row['raw_usage'], {'input_tokens': 3779, 'output_tokens': 75, 'cache_read_tokens': 182855,
                                            'thinking_tokens': 74, 'cache_write_tokens': 7})
        self.assertNotIn('cache_write_unreported', row['semantics'])

    def test_inconsistency_and_missing_evidence_stay_visible(self):
        self.fx.add(0, generation(output=80, model='', response_id=''))
        result = self.read()
        (_, row), = result.records
        self.assertEqual(row['output_tokens'], 80)  # never repaired
        for flag in ('inconsistent_output_breakdown', 'model_unobserved', 'completion_time_unknown'):
            self.assertIn(flag, row['semantics'])
            self.assertEqual(result.diagnostics[flag], 1)
        self.assertIsNone(row['model'])
        self.assertTrue(row['revision'].startswith('sha256:'))

    def test_errored_and_pending_generations(self):
        self.fx.add(0, generation(steps=[1]), steps=[(1, 1791660000)])
        self.fx.add(1, generation(usage=False, error='quota'))
        self.fx.add(2, generation(usage=False))  # in flight: revisit next pass
        self.fx.add(3, generation(steps=[4]), steps=[(4, 1791660100)])
        result = self.read()
        self.assertEqual([r['event_id'] for _, r in result.records], ['generation:0', 'generation:3'])
        self.assertEqual(result.diagnostics, {'generation_error_without_usage': 1, 'generation_pending': 1})
        self.assertEqual(result.high_water, 1)

    def test_resume_boundaries_never_recharge_history(self):
        segments = [('segment-a', '2026-10-10T19:00:00Z')]
        self.fx.add(0, generation(steps=[1]), steps=[(1, 1791660000)])
        first = self.read(segments=segments)
        self.assertEqual(first.records[0][1]['segment_id'], 'segment-a')
        # The conversation resumes in a new supervised segment and continues.
        segments.append(('segment-b', '2026-10-10T20:00:00Z'))
        self.fx.add(1, generation(steps=[2], cache_read=14500, response_id='resp-2'), steps=[(2, 1791664000)])
        increment = self.read(after_ordinal=first.high_water, segments=segments)
        self.assertEqual([(r['event_id'], r['segment_id']) for _, r in increment.records], [('generation:1', 'segment-b')])
        replay = self.read(segments=segments)
        self.assertEqual([fact(*r)[:2] for r in replay.records[:1]], [fact(*r)[:2] for r in first.records])
        self.assertEqual(replay.high_water, 1)

    def test_command_and_quota_data_are_not_conversation_usage(self):
        self.assertEqual(self.read().records, [])
        self.assertEqual(self.read().diagnostics, {'no_inference_evidence': 1})
        self.fx.add(0, generation(usage=False, error='command'))  # e.g. a zero-usage slash command
        self.assertEqual(self.read().records, [])
        self.assertNotIn('subprocess', vars(agy))  # never runs agy or `/usage`

    def test_child_and_foreign_generations(self):
        self.fx.add(0, generation(steps=[1], root='11d003e9-1bb3-469f-965c-27a451a61feb'), steps=[(1, 1791660000)])
        self.fx.add(1, generation(cascade='11d003e9-1bb3-469f-965c-27a451a61feb'))
        result = self.read()
        self.assertEqual(len(result.records), 1)
        self.assertIn('child_conversation', result.records[0][1]['semantics'])
        self.assertEqual(result.diagnostics, {'undecodable_generation': 1})
        self.assertEqual(result.high_water, 0)

    def test_no_text_reaches_facts(self):
        self.fx.add(0, generation(steps=[1]), steps=[(1, 1791660000)])
        self.assertNotIn(SECRET, json.dumps(self.read().records))

    def test_source_validation(self):
        with self.assertRaises(AntigravitySourceError):
            read_conversation('../escape', root=self.root)
        with self.assertRaises(AntigravitySourceError):
            read_conversation('11d003e9-1bb3-469f-965c-27a451a61feb', root=self.root)
        link = self.root / 'conversations' / '11d003e9-1bb3-469f-965c-27a451a61feb.db'
        os.symlink(self.fx.path, link)
        with self.assertRaises(AntigravitySourceError):
            read_conversation(link.stem, root=self.root)
        bad = Fixture(self.root / 'other')
        bad.db.execute('DROP TABLE gen_metadata')
        bad.db.close()
        with self.assertRaises(AntigravitySourceError):
            read_conversation(CID, root=self.root / 'other')

    @unittest.skipUnless(shutil.which('dolt'), 'dolt not installed')
    def test_store_replay_is_noop(self):
        self.fx.add(0, generation(steps=[1]), steps=[(1, 1791660000)])
        self.fx.add(1, generation(steps=[2], response_id='resp-2'), steps=[(2, 1791660010)])
        state = self.root / 'state'
        store = Store(self.root, lambda _: {'state_dir': str(state)})
        store.initialize()
        self.assertEqual(store.append(self.read().records), 2)
        self.assertEqual(store.append(self.read().records), 0)
        rows = store.query('SELECT SUM(input_tokens) AS i, SUM(output_tokens) AS o FROM current_usage_events')
        self.assertEqual((int(rows[0]['i']), int(rows[0]['o'])), (28854, 150))


if __name__ == '__main__':
    unittest.main()
