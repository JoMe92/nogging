"""Tests for Claude and Codex usage adapters, durable checkpoints, and ingestion."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from token_usage_store import Store, StoreError, fact
from token_usage_adapters import (
    ClaudeAdapter, CodexAdapter, CheckpointManager, SpoolManager,
    Ingester, read_source_lines
)

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader('nogg_adapter_test', str(ROOT / 'scripts/nogg'))
spec = importlib.util.spec_from_loader(loader.name, loader)
nogg = importlib.util.module_from_spec(spec)
import sys
sys.modules[loader.name] = nogg
loader.exec_module(nogg)


class ClaudeAdapterTests(unittest.TestCase):
    def setUp(self):
        self.adapter = ClaudeAdapter()

    def test_inclusive_cache_and_breakdowns(self):
        record = {
            'type': 'assistant',
            'sessionId': 'sess-claude-1',
            'timestamp': '2026-10-11T12:00:00Z',
            'message': {
                'id': 'msg-1',
                'role': 'assistant',
                'model': 'claude-sonnet-5-5',
                'usage': {
                    'input_tokens': 10,
                    'cache_read_input_tokens': 20,
                    'cache_creation_input_tokens': 5,
                    'output_tokens': 8,
                    'output_tokens_details': {'thinking_tokens': 3},
                    'iterations': [{'input_tokens': 10, 'output_tokens': 8}],
                    'cache_creation': {'ephemeral_1h_input_tokens': 5, 'ephemeral_5m_input_tokens': 0},
                }
            }
        }
        res = self.adapter.parse_record(record)
        self.assertIsNotNone(res)
        table, data = res
        self.assertEqual(table, 'usage_events')
        # Inclusive input = 10 (uncached) + 20 (read) + 5 (write) = 35
        self.assertEqual(data['input_tokens'], 35)
        self.assertEqual(data['cache_read_tokens'], 20)
        self.assertEqual(data['cache_write_tokens'], 5)
        self.assertEqual(data['output_tokens'], 8)
        self.assertEqual(data['thinking_tokens'], 3)
        self.assertIn('cache_summed_input', data['semantics'])
        self.assertIn('cache_read', data['semantics'])
        self.assertIn('cache_write', data['semantics'])
        self.assertIn('thinking', data['semantics'])
        self.assertEqual(data['completeness'], 'complete')

        # Allowlisted fact validation
        identity, content, valid_data = fact('usage_events', data)
        self.assertEqual(valid_data['input_tokens'], 35)

    def test_missing_cache_write_and_inconsistent_total(self):
        record = {
            'type': 'assistant',
            'sessionId': 'sess-claude-2',
            'timestamp': '2026-10-11T12:00:00Z',
            'message': {
                'id': 'msg-missing',
                'role': 'assistant',
                'model': 'claude-sonnet-5-5',
                'usage': {
                    'input_tokens': 15,
                    'cache_read_input_tokens': 5,
                    'output_tokens': 10,
                    'total_tokens': 999,  # Inconsistent with 20 + 10 = 30
                }
            }
        }
        res = self.adapter.parse_record(record)
        self.assertIsNotNone(res)
        table, data = res
        self.assertIsNone(data['cache_write_tokens'])
        self.assertEqual(data['input_tokens'], 20)
        self.assertEqual(data['provider_total_tokens'], 999)
        self.assertIn('missing_cache_write', data['semantics'])
        self.assertIn('inconsistent_provider_total', data['semantics'])
        self.assertEqual(data['completeness'], 'inconsistent')

    def test_repeated_and_revised_streaming_snapshots(self):
        base = {
            'type': 'assistant',
            'sessionId': 'sess-stream',
            'timestamp': '2026-10-11T12:00:00Z',
            'message': {
                'id': 'msg-stream-1',
                'role': 'assistant',
                'model': 'claude-sonnet-5-5',
                'usage': {
                    'input_tokens': 10,
                    'cache_read_input_tokens': 0,
                    'cache_creation_input_tokens': 0,
                    'output_tokens': 5,
                }
            }
        }
        # First snapshot
        r1 = self.adapter.parse_record(base)
        self.assertIsNotNone(r1)
        self.assertEqual(r1[1]['source_ordinal'], 0)
        self.assertEqual(r1[1]['output_tokens'], 5)

        # Repeated identical snapshot: skipped
        r2 = self.adapter.parse_record(base)
        self.assertIsNone(r2)

        # Revised streaming snapshot (output grew from 5 to 25)
        revised = json.loads(json.dumps(base))
        revised['message']['usage']['output_tokens'] = 25
        r3 = self.adapter.parse_record(revised)
        self.assertIsNotNone(r3)
        self.assertEqual(r3[1]['source_ordinal'], 1)
        self.assertEqual(r3[1]['output_tokens'], 25)

        # Incompatible revision: output dropped from 25 to 2
        corrupt = json.loads(json.dumps(base))
        corrupt['message']['usage']['output_tokens'] = 2
        r4 = self.adapter.parse_record(corrupt)
        self.assertIsNone(r4)
        self.assertTrue(any(d['type'] == 'incompatible_revision' for d in self.adapter.diagnostics))


class CodexAdapterTests(unittest.TestCase):
    def setUp(self):
        self.adapter = CodexAdapter()

    def test_context_and_token_usage_record(self):
        # 1. Session meta provides provider
        meta = {'type': 'session_meta', 'payload': {'model_provider': 'openai', 'session_id': 'sess-codex-1'}}
        self.assertIsNone(self.adapter.parse_record(meta))
        self.assertEqual(self.adapter.current_provider, 'openai')

        # 2. Turn context provides model and effort
        turn = {'type': 'turn_context', 'payload': {'model': 'gpt-6.1-sol', 'effort': 'low'}}
        self.assertIsNone(self.adapter.parse_record(turn))
        self.assertEqual(self.adapter.current_model, 'gpt-6.1-sol')
        self.assertEqual(self.adapter.current_effort, 'low')

        # 3. Token usage record
        rec = {
            'type': 'token_usage_record',
            'timestamp': '2026-10-11T12:00:00Z',
            'payload': {
                'response_id': 'resp-1',
                'session_id': 'sess-codex-1',
                'usage': {
                    'input_tokens': 100,  # Observed input already includes cache
                    'cached_input_tokens': 40,
                    'cache_write_input_tokens': 10,
                    'output_tokens': 50,
                    'reasoning_output_tokens': 15,
                    'total_tokens': 150,
                },
                'turn_token_usage': {'input_tokens': 100, 'output_tokens': 50, 'total_tokens': 150},
                'thread_token_usage': {'input_tokens': 100, 'output_tokens': 50, 'total_tokens': 150},
            }
        }
        res = self.adapter.parse_record(rec)
        self.assertIsNotNone(res)
        table, data = res
        self.assertEqual(data['input_tokens'], 100)
        self.assertEqual(data['cache_read_tokens'], 40)
        self.assertEqual(data['cache_write_tokens'], 10)
        self.assertEqual(data['output_tokens'], 50)
        self.assertEqual(data['thinking_tokens'], 15)
        self.assertEqual(data['provider_total_tokens'], 150)
        self.assertEqual(data['model'], 'gpt-6.1-sol')
        self.assertEqual(data['effort'], 'low')
        self.assertEqual(data['provider'], 'openai')
        self.assertIn('cache_inclusive_input', data['semantics'])
        self.assertEqual(data['completeness'], 'complete')

        # 4. Overlapping summary event_msg is ignored
        event_msg = {
            'type': 'event_msg',
            'payload': {'type': 'token_count', 'info': {'total_token_usage': {'input_tokens': 100}}}
        }
        self.assertIsNone(self.adapter.parse_record(event_msg))

    def test_overlapping_summaries_across_turns_not_double_charged(self):
        # Two responses in different turns with increasing turn/thread summaries
        r1 = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'resp-turn-1',
                'session_id': 'sess-turns',
                'usage': {'input_tokens': 100, 'output_tokens': 50, 'total_tokens': 150},
                'turn_token_usage': {'input_tokens': 100, 'output_tokens': 50, 'total_tokens': 150},
                'thread_token_usage': {'input_tokens': 100, 'output_tokens': 50, 'total_tokens': 150},
            }
        }
        r2 = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'resp-turn-2',
                'session_id': 'sess-turns',
                'usage': {'input_tokens': 120, 'output_tokens': 30, 'total_tokens': 150},
                'turn_token_usage': {'input_tokens': 220, 'output_tokens': 80, 'total_tokens': 300},
                'thread_token_usage': {'input_tokens': 220, 'output_tokens': 80, 'total_tokens': 300},
            }
        }
        summary = {
            'type': 'event_msg',
            'payload': {'type': 'token_count', 'info': {'total_token_usage': {'input_tokens': 220, 'output_tokens': 80}}}
        }
        facts = [self.adapter.parse_record(x) for x in (r1, summary, r2)]
        valid_facts = [f for f in facts if f is not None]
        self.assertEqual(len(valid_facts), 2)
        total_in = sum(f[1]['input_tokens'] for f in valid_facts)
        total_out = sum(f[1]['output_tokens'] for f in valid_facts)
        # Should be 100 + 120 = 220 input, and 50 + 30 = 80 output (not 220 + 220 + ... = double charged)
        self.assertEqual(total_in, 220)
        self.assertEqual(total_out, 80)

    def test_inconsistent_total(self):
        rec = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'resp-bad-total',
                'session_id': 'sess-codex-2',
                'usage': {
                    'input_tokens': 100,
                    'output_tokens': 50,
                    'total_tokens': 200,  # Inconsistent with 100 + 50 = 150
                }
            }
        }
        res = self.adapter.parse_record(rec)
        self.assertIsNotNone(res)
        table, data = res
        self.assertEqual(data['provider_total_tokens'], 200)
        self.assertIn('inconsistent_provider_total', data['semantics'])
        self.assertEqual(data['completeness'], 'inconsistent')


class CheckpointAndIngestionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nogg-ingest-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state_root = self.root / 'state'
        self.state_root.mkdir()

    def test_partial_lines_retry(self):
        source = self.root / 'claude.jsonl'
        record1 = {
            'type': 'assistant',
            'sessionId': 'sess-partial',
            'message': {
                'id': 'msg-1',
                'role': 'assistant',
                'model': 'claude-sonnet-5-5',
                'usage': {'input_tokens': 10, 'output_tokens': 5}
            }
        }
        # Write 1 complete line and 1 partial line without trailing newline
        source.write_text(json.dumps(record1) + '\n{"type": "assistant", "sessionId": "sess-part')

        ingester = Ingester(state_root=self.state_root)
        res = ingester.ingest_file(source, runtime='claude')
        self.assertEqual(res['records'], 1)
        self.assertTrue(res['has_partial_tail'])
        offset1 = res['new_offset']

        # Complete the partial line
        record2 = {
            'type': 'assistant',
            'sessionId': 'sess-partial',
            'message': {
                'id': 'msg-2',
                'role': 'assistant',
                'model': 'claude-sonnet-5-5',
                'usage': {'input_tokens': 20, 'output_tokens': 10}
            }
        }
        source.write_text(json.dumps(record1) + '\n' + json.dumps(record2) + '\n')

        res2 = ingester.ingest_file(source, runtime='claude')
        self.assertEqual(res2['records'], 1)
        self.assertFalse(res2['has_partial_tail'])
        self.assertGreater(res2['new_offset'], offset1)

    def test_rotation_and_truncation(self):
        source = self.root / 'codex.jsonl'
        rec1 = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'resp-rot-1',
                'session_id': 'sess-rot',
                'usage': {'input_tokens': 50, 'output_tokens': 20, 'total_tokens': 70}
            }
        }
        source.write_text(json.dumps(rec1) + '\n')

        ingester = Ingester(state_root=self.state_root)
        res1 = ingester.ingest_file(source, runtime='codex')
        self.assertEqual(res1['records'], 1)

        # Truncate source file (shorter than recorded checkpoint offset)
        rec2 = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'r2',
                'session_id': 's',
                'usage': {'input_tokens': 1, 'output_tokens': 1}
            }
        }
        source.write_text(json.dumps(rec2) + '\n')
        self.assertLess(source.stat().st_size, res1['new_offset'])

        res2 = ingester.ingest_file(source, runtime='codex')
        self.assertEqual(res2['records'], 1)
        self.assertEqual(res2['status'], 'success')

    def test_inode_rotation(self):
        source = self.root / 'rotated.jsonl'
        rec1 = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'resp-1',
                'session_id': 'sess-inode',
                'usage': {'input_tokens': 10, 'output_tokens': 5}
            }
        }
        source.write_text(json.dumps(rec1) + '\n')
        ingester = Ingester(state_root=self.state_root)
        res1 = ingester.ingest_file(source, runtime='codex')
        self.assertEqual(res1['records'], 1)

        # Rename old file to keep its inode occupied, then create new file at original path
        temp_old = self.root / 'old_rotated.jsonl'
        source.rename(temp_old)
        rec2 = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'resp-2',
                'session_id': 'sess-inode',
                'usage': {'input_tokens': 20, 'output_tokens': 10}
            }
        }
        source.write_text(json.dumps(rec2) + '\n')
        self.assertNotEqual(temp_old.stat().st_ino, source.stat().st_ino)

        res2 = ingester.ingest_file(source, runtime='codex')
        self.assertEqual(res2['records'], 1)
        self.assertEqual(res2['status'], 'success')


@unittest.skipUnless(shutil.which('dolt'), 'embedded Dolt not installed')
class StoreIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nogg-store-ingest-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'main'
        self.repo.mkdir()
        subprocess.run(['git', '-C', str(self.repo), 'init', '-b', 'develop'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.org',
                        'commit', '--allow-empty', '-m', 'init'], check=True, capture_output=True)
        self.store = Store(self.repo, nogg.canonical_repository_state)
        self.store.initialize()
        self.device = self.store.device()

    def test_dolt_append_replay_and_spool_drain(self):
        source = self.root / 'rollout.jsonl'
        rec = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'resp-store-1',
                'session_id': 'sess-store-1',
                'usage': {'input_tokens': 100, 'output_tokens': 25, 'total_tokens': 125}
            }
        }
        source.write_text(json.dumps(rec) + '\n')

        ingester = Ingester(store=self.store, device_id=self.device)
        res1 = ingester.ingest_file(source, runtime='codex')
        self.assertEqual(res1['status'], 'success')
        self.assertEqual(res1['records'], 1)
        rows = self.store.query('SELECT input_tokens, output_tokens FROM current_usage_events')
        self.assertEqual(rows, [{'input_tokens': 100, 'output_tokens': 25}])

        # Crash simulation: reset checkpoint offset to 0 and re-ingest
        ingester.checkpoints.save(source, 0, source.stat().st_ino, source.stat().st_size, source.stat().st_mtime_ns)
        # Re-create adapter to test replay from fresh ingestion pass
        ingester.codex_adapter = CodexAdapter()
        res_replay = ingester.ingest_file(source, runtime='codex')
        self.assertEqual(res_replay['status'], 'success')
        self.assertEqual(self.store.query('SELECT COUNT(*) AS n FROM usage_events'), [{'n': 1}])

        # Spool test: simulate Dolt unavailability
        rec2 = {
            'type': 'token_usage_record',
            'payload': {
                'response_id': 'resp-store-2',
                'session_id': 'sess-store-1',
                'usage': {'input_tokens': 50, 'output_tokens': 10, 'total_tokens': 60}
            }
        }
        source.write_text(json.dumps(rec) + '\n' + json.dumps(rec2) + '\n')

        original_append = self.store.append
        def fail_append(*_, **__):
            raise StoreError('simulated dolt store failure')
        self.store.append = fail_append

        res_spool = ingester.ingest_file(source, runtime='codex')
        self.assertEqual(res_spool['status'], 'spooled')
        self.assertEqual(len(ingester.spool.pending_batches()), 1)

        # Restore Dolt and drain spool
        self.store.append = original_append
        drained = ingester.spool.drain(self.store)
        self.assertEqual(drained, 1)
        self.assertEqual(len(ingester.spool.pending_batches()), 0)
        self.assertEqual(self.store.query('SELECT COUNT(*) AS n FROM current_usage_events'), [{'n': 2}])

    def test_claude_dolt_streaming_and_incompatible_revisions(self):
        source = self.root / 'claude_stream.jsonl'
        base = {
            'type': 'assistant',
            'sessionId': 'sess-claude-dolt',
            'message': {
                'id': 'msg-dolt-1',
                'role': 'assistant',
                'model': 'claude-sonnet-5-5',
                'usage': {
                    'input_tokens': 10,
                    'cache_read_input_tokens': 20,
                    'cache_creation_input_tokens': 5,
                    'output_tokens': 4,
                }
            }
        }
        # Snapshot 1
        source.write_text(json.dumps(base) + '\n')
        ingester = Ingester(store=self.store, device_id=self.device)
        res1 = ingester.ingest_file(source, runtime='claude')
        self.assertEqual(res1['records'], 1)
        rows1 = self.store.query('SELECT output_tokens FROM current_usage_events WHERE event_id="msg-dolt-1"')
        self.assertEqual(rows1, [{'output_tokens': 4}])

        # Snapshot 2: identical repeat (skipped)
        with source.open('a') as f:
            f.write(json.dumps(base) + '\n')
        res2 = ingester.ingest_file(source, runtime='claude')
        self.assertEqual(res2['records'], 0)

        # Snapshot 3: valid streaming revision (output grew to 30)
        revised = json.loads(json.dumps(base))
        revised['message']['usage']['output_tokens'] = 30
        with source.open('a') as f:
            f.write(json.dumps(revised) + '\n')
        res3 = ingester.ingest_file(source, runtime='claude')
        self.assertEqual(res3['records'], 1)
        rows3 = self.store.query('SELECT output_tokens FROM current_usage_events WHERE event_id="msg-dolt-1"')
        self.assertEqual(rows3, [{'output_tokens': 30}])

        # Snapshot 4: incompatible revision (output drops to 2)
        corrupt = json.loads(json.dumps(base))
        corrupt['message']['usage']['output_tokens'] = 2
        with source.open('a') as f:
            f.write(json.dumps(corrupt) + '\n')
        res4 = ingester.ingest_file(source, runtime='claude')
        self.assertEqual(res4['records'], 0)
        self.assertTrue(any(d['type'] == 'incompatible_revision' for d in res4['diagnostics']))
        # In Dolt, current_usage_events still reflects the valid revision of 30 output tokens!
        rows4 = self.store.query('SELECT output_tokens FROM current_usage_events WHERE event_id="msg-dolt-1"')
        self.assertEqual(rows4, [{'output_tokens': 30}])


if __name__ == '__main__':
    unittest.main()
