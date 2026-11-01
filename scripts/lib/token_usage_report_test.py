"""Report/session/export tests over synthetic current facts (plus real Dolt)."""
import datetime as dt
import json
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

import token_usage_report as tr
from token_usage_report import ReportError
from token_usage_adapters import ClaudeAdapter, CodexAdapter
from token_usage_store import FIELDS, Store, StoreTimeout, fact

UTC = dt.timezone.utc
NOW = dt.datetime(2026, 10, 11, 12, 0, tzinfo=UTC)
META = {'project_id': '11111111-1111-4111-8111-111111111111', 'schema_version': 1}


def at(hour, minute=0, day=11):
    return dt.datetime(2026, 10, day, hour, minute, tzinfo=UTC).isoformat().replace('+00:00', 'Z')


def row(table, **values):
    data = {k: values.get(k) for k in FIELDS[table]}
    data.setdefault('revision', 'v1')
    data['revision'] = data['revision'] or 'v1'
    data['source_ordinal'] = data['source_ordinal'] or 0
    identity, content, data = fact(table, data)
    return dict(data, fact_id=identity, content_hash=content)


class Facts:
    def __init__(self):
        self.tables = {t: [] for t in FIELDS}

    def segment(self, seg, name, runtime='claude', start=at(0), end=None, kind='exit', beat=None, device='dev-1'):
        src = f'nogg-session:{seg}'
        self.tables['session_segments'].append(row('session_segments', source_id=src, event_id='segment',
            source_timestamp=start, runtime=runtime, supervised_id=name, device_id=device))
        self.tables['lifecycle_events'].append(row('lifecycle_events', source_id=src, event_id='start',
            source_timestamp=start, segment_id=seg, kind='start'))
        if end:
            self.tables['lifecycle_events'].append(row('lifecycle_events', source_id=src, event_id='exit',
                source_timestamp=end, segment_id=seg, kind=kind))
        if beat:
            self.tables['lifecycle_events'].append(row('lifecycle_events', source_id=src, event_id='liveness',
                revision=beat, source_ordinal=1, source_timestamp=beat, segment_id=seg, kind='heartbeat'))
        return self

    def boundary(self, seg, index, when, task='TASK-1', complexity='standard', effort=None, bead='SPEC-1'):
        self.tables['attribution_events'].append(row('attribution_events', source_id=f'nogg-session:{seg}',
            event_id=f'boundary:{index}', source_timestamp=when, segment_id=seg, task_id=task, bead_id=bead,
            change_id='change', role='lead', complexity=complexity, complexity_source='launch',
            vocabulary_version='1', requested_model='requested-model', configured_effort=effort))
        return self

    def usage(self, seg, event, when, model='luna', input=100, output=10, cache_write=5, semantics=None,
              runtime='claude', duration=1000, cache_read=0, completeness='complete'):
        self.tables['usage_events'].append(row('usage_events', source_id=f'{runtime}:conv-{seg}', event_id=event,
            source_timestamp=when, segment_id=seg, runtime=runtime, provider='p', model=model,
            input_tokens=input, output_tokens=output, cache_read_tokens=cache_read, cache_write_tokens=cache_write,
            thinking_tokens=0, inference_duration_ms=duration, completeness=completeness,
            semantics=semantics or [], raw_usage={} if input is None else {'input_tokens': input}))
        return self


def report(facts, start, end, group_by='day', **filters):
    lo, hi = tr.window(start, end, NOW)
    return tr.report(facts.tables, META, lo, hi, group_by, filters, NOW)


class WindowTests(unittest.TestCase):
    def test_adjacent_windows_are_half_open(self):
        f = Facts().segment('s', 'sess').boundary('s', 0, at(0)).usage('s', 'e1', at(1))
        first = report(f, at(0), at(1), 'hour')
        second = report(f, at(1), at(2), 'hour')
        self.assertEqual((first['rows'], second['rows'][0]['events']), ([], 1))
        self.assertEqual(second['rows'][0]['bucket'], '2026-10-11T01:00:00Z')

    def test_default_window_and_refusals(self):
        self.assertEqual(tr.window(None, None, NOW),
                         (dt.datetime(2026, 10, 11, tzinfo=UTC), dt.datetime(2026, 10, 12, tzinfo=UTC)))
        self.assertEqual(tr.window('2026-10-10', '2026-10-11', NOW)[0], dt.datetime(2026, 10, 10, tzinfo=UTC))
        for args, text in ((('2026-10-11T00:00:00', '2026-10-12T00:00:00Z'), 'no UTC offset'),
                           ((at(2), at(1)), 'earlier than --to'), ((at(1), None), 'both --from and --to'),
                           (('yesterday', at(1)), 'not ISO-8601')):
            with self.assertRaises(ReportError) as ctx:
                tr.window(*args, NOW)
            self.assertIn(text, str(ctx.exception))
        for filters, text in (({'complexity': 'hard'}, '--complexity must be'), ({'runtime': 'gpt'}, '--runtime'),
                              ({'model': ' '}, 'non-empty')):
            with self.assertRaises(ReportError) as ctx:
                tr.validate_filters(filters)
            self.assertIn(text, str(ctx.exception))

    def test_hour_and_day_buckets_use_completion_time(self):
        f = Facts().segment('s', 'sess').boundary('s', 0, at(0))
        f.usage('s', 'a', at(1, 59)).usage('s', 'b', at(2, 0)).usage('s', 'c', at(3, 0, day=12))
        hours = report(f, '2026-10-11', '2026-10-13', 'hour')
        self.assertEqual([(r['bucket'], r['events']) for r in hours['rows'] if r['events']],
                         [('2026-10-11T01:00:00Z', 1), ('2026-10-11T02:00:00Z', 1), ('2026-10-12T03:00:00Z', 1)])
        days = report(f, '2026-10-11', '2026-10-13')
        self.assertEqual([(r['bucket'], r['events']) for r in days['rows'] if r['events']],
                         [('2026-10-11T00:00:00Z', 2), ('2026-10-12T00:00:00Z', 1)])


class AttributionTests(unittest.TestCase):
    def test_compare_models_by_task_complexity(self):
        f = Facts()
        f.segment('luna', 'sess-luna').boundary('luna', 0, at(0)).usage('luna', 'l1', at(1), model='gpt-6-luna', input=50)
        f.segment('opus', 'sess-opus').boundary('opus', 0, at(0)).usage('opus', 'o1', at(2), model='claude-opus', input=70)
        f.segment('cx', 'sess-cx').boundary('cx', 0, at(0), complexity='complex').usage('cx', 'c1', at(3))
        doc = report(f, at(0), at(12), 'session', complexity='standard', task='TASK-1')
        self.assertEqual(sorted((r['session'], list(r['by_model']), r['tokens']['input_tokens'],
                                 r['attribution'][0]['task_id'], r['attribution'][0]['complexity'])
                                for r in doc['rows']),
                         [('sess-luna', ['gpt-6-luna'], 50, 'TASK-1', 'standard'),
                          ('sess-opus', ['claude-opus'], 70, 'TASK-1', 'standard')])
        self.assertEqual(report(f, at(0), at(12), model='claude-opus')['rows'][0]['tokens']['input_tokens'], 70)

    def test_unknown_model_and_missing_cache_counter_stay_explicit(self):
        f = Facts().segment('s', 'sess').boundary('s', 0, at(0), task=None, complexity='unknown')
        f.usage('s', 'e', at(1), model=None, cache_write=None)
        doc = report(f, at(0), at(12), 'session')
        r = doc['rows'][0]
        self.assertEqual(list(r['by_model']), ['unknown'])   # never the requested model
        self.assertEqual((r['unknown_counters']['cache_write_tokens'], r['tokens']['cache_write_tokens']), (1, 0))
        c = doc['coverage']
        self.assertEqual((c['unknown_model'], c['unknown_task'], c['unknown_complexity']), (1, 1, 1))
        self.assertEqual(doc['sync'], {'state': 'not_configured', 'local_only': True})
        self.assertTrue(any('not billed cost' in n for n in doc['notes']))

    def test_coarse_interval_is_not_split(self):
        f = Facts().segment('s', 'sess').boundary('s', 0, at(0))
        f.usage('s', 'wide', at(3), semantics=[f'coarse_from:{at(1)}'], input=900)
        f.usage('s', 'narrow', at(3, 30), semantics=[f'coarse_from:{at(3, 10)}'], input=10)
        doc = report(f, at(0), at(6), 'hour')
        self.assertEqual([(r['bucket'], r['tokens']['input_tokens']) for r in doc['rows'] if r['events']],
                         [('2026-10-11T03:00:00Z', 10)])
        self.assertEqual([(c['interval_from'], c['interval_to'], c['quality'], c['tokens']['input_tokens'])
                          for c in doc['coarse']], [('2026-10-11T01:00:00Z', '2026-10-11T03:00:00Z', 'coarse', 900)])


class RuntimeTests(unittest.TestCase):
    def test_restart_gap_and_model_split_do_not_multiply_runtime(self):
        f = Facts()
        f.segment('a', 'first', start=at(1, 0), end=at(1, 10)).boundary('a', 0, at(1, 0))
        f.segment('b', 'resume', start=at(1, 30), end=at(1, 35)).boundary('b', 0, at(1, 30))
        f.usage('a', 'm1', at(1, 5), model='opus').usage('b', 'm2', at(1, 32), model='luna')
        day = report(f, '2026-10-11', '2026-10-12')
        self.assertEqual((day['rows'][0]['wall_runtime_ms'], day['rows'][0]['runtime_quality']), (15 * 60000, ['complete']))
        sessions = report(f, '2026-10-11', '2026-10-12', 'session')
        self.assertEqual(sorted(r['wall_runtime_ms'] for r in sessions['rows']), [5 * 60000, 10 * 60000])
        filtered = report(f, '2026-10-11', '2026-10-12', model='opus')
        self.assertIsNone(filtered['rows'][0]['wall_runtime_ms'])
        self.assertTrue(any('not per model' in n for n in filtered['notes']))

    def test_clipping_partial_and_provisional_runtime(self):
        f = Facts()
        f.segment('crash', 'crash', start=at(0, 30), end=at(2, 15), kind='exit_unobserved').boundary('crash', 0, at(0, 30))
        f.segment('live', 'live', start=at(1, 50), beat=at(2, 20)).boundary('live', 0, at(1, 50))
        doc = report(f, at(1), at(3), 'hour')
        self.assertEqual([(r['bucket'], r['wall_runtime_ms'], r['runtime_quality']) for r in doc['rows']],
                         [('2026-10-11T01:00:00Z', 70 * 60000, ['partial', 'provisional']),
                          ('2026-10-11T02:00:00Z', 35 * 60000, ['partial', 'provisional'])])

    def test_task_transition_splits_runtime(self):
        f = Facts().segment('s', 'sess', start=at(1), end=at(3))
        f.boundary('s', 0, at(1), task='TASK-1').boundary('s', 1, at(2), task='TASK-2')
        first = report(f, at(0), at(6), task='TASK-1')
        self.assertEqual(first['rows'][0]['wall_runtime_ms'], 60 * 60000)
        session = tr.session(f.tables, META, 'sess', NOW)
        self.assertEqual((session['wall_runtime_ms'], [b['task_id'] for b in session['attribution']]),
                         (120 * 60000, ['TASK-1', 'TASK-2']))
        with self.assertRaises(ReportError):
            tr.session(f.tables, META, 'missing', NOW)


class ExportTests(unittest.TestCase):
    def test_export_roundtrip_and_tamper_refusal(self):
        f = Facts().segment('s', 'sess', end=at(2)).boundary('s', 0, at(0)).usage('s', 'e', at(1))
        f.usage('s', 'late', at(5, day=12))
        lines = list(tr.export_lines(f.tables, META, *tr.window(at(0), at(12), NOW), NOW))
        header = json.loads(lines[0])
        self.assertEqual((header['schema'], header['project_id']), (tr.EXPORT_SCHEMA, META['project_id']))
        project, records, registry = tr.import_records(lines, META)
        self.assertEqual(project, META['project_id'])
        self.assertEqual(sorted({t for t, _ in records}),
                         ['attribution_events', 'lifecycle_events', 'session_segments', 'usage_events'])
        self.assertEqual([v['event_id'] for t, v in records if t == 'usage_events'], ['e'])
        tampered = [lines[0]] + [l.replace('"input_tokens": 100', '"input_tokens": 999') for l in lines[1:]]
        with self.assertRaises(ReportError):
            tr.import_records(tampered, META)
        with self.assertRaises(ReportError):
            tr.import_records(lines, {'project_id': '22222222-2222-4222-8222-222222222222'})


class ReviewFixTests(unittest.TestCase):
    def test_restarted_session_aggregates_all_segments(self):
        f = Facts()
        f.segment('run1', 'orchestrator', start=at(1), end=at(2)).boundary('run1', 0, at(1))
        f.segment('run2', 'orchestrator', start=at(4), end=at(4, 30)).boundary('run2', 0, at(4))
        f.usage('run1', 'a', at(1, 30)).usage('run2', 'b', at(4, 10), model='opus')
        doc = tr.session(f.tables, META, 'orchestrator', NOW)
        self.assertEqual((doc['wall_runtime_ms'], [p['segment_id'] for p in doc['segments']], doc['totals']['events']),
                         (90 * 60000, ['run1', 'run2'], 2))   # 60 + 30 minutes, downtime excluded
        rows = report(f, at(0), at(12), 'session')['rows']
        self.assertEqual([(r['session'], r['segments'], r['events'], r['wall_runtime_ms']) for r in rows],
                         [('orchestrator', ['run1', 'run2'], 2, 90 * 60000)])

    def test_unknown_filter_values_and_tie_order(self):
        f = Facts().segment('s', 'sess', start=at(0), end=at(3))
        f.boundary('s', 2, at(1), task='TASK-early').boundary('s', 10, at(1), task='TASK-late')
        f.usage('s', 'known', at(2)).usage('s', 'anon', at(2, 30), model=None)
        self.assertEqual([r['events'] for r in report(f, at(0), at(12), model='unknown')['rows']], [1])
        self.assertEqual(report(f, at(0), at(12), task='TASK-late')['rows'][0]['events'], 2)  # boundary:10 after :2

    def test_coarse_disclosed_in_session_rows_and_untimed_coverage_filtered(self):
        f = Facts().segment('s', 'sess').boundary('s', 0, at(0))
        f.usage('s', 'wide', at(3), semantics=[f'coarse_from:{at(1)}'])
        f.usage('s', 'untimed-luna', None).usage('s', 'untimed-opus', None, model='opus')
        doc = report(f, at(0), at(12), 'session', model='luna')
        self.assertEqual((doc['rows'][0]['coarse_events'], doc['coverage']['untimed_events']), (1, 1))

    def test_export_includes_untimed_facts_and_spanning_sessions(self):
        f = Facts()
        f.segment('long', 'long', start=at(0, day=10), end=at(0, day=13)).boundary('long', 0, at(0, day=10))
        f.segment('s', 'sess', end=at(2)).boundary('s', 0, at(0)).usage('s', 'untimed', None)
        registry = {'devices': [{'device_id': 'dev-1', 'hostname': 'pi'}, {'device_id': 'dev-x', 'hostname': 'x'}],
                    'source_owners': [{'source_id': 'claude:conv-s', 'device_id': 'dev-1'}]}
        lines = list(tr.export_lines(f.tables, META, *tr.window(at(0, day=12), at(0, day=13), NOW), NOW, registry))
        facts = [json.loads(l) for l in lines[1:]]
        self.assertIn('untimed', [x['fact']['event_id'] for x in facts if x.get('table') == 'usage_events'])
        self.assertIn('nogg-session:long', [x['fact']['source_id'] for x in facts if x.get('table') == 'session_segments'])
        self.assertEqual([x['row']['device_id'] for x in facts if x.get('registry') == 'devices'], ['dev-1'])
        _, _, recovered = tr.import_records(lines, META)
        self.assertEqual(recovered['source_owners'], {'claude:conv-s': 'dev-1'})


class FreshInputTests(unittest.TestCase):
    """Stored input includes cache reads for every adapter; fresh = input - cache read."""

    def test_fresh_input_per_runtime_semantics(self):
        claude = ClaudeAdapter().parse_record({'type': 'assistant', 'sessionId': 's', 'timestamp': at(1),
            'message': {'id': 'm', 'role': 'assistant', 'model': 'opus', 'usage': {
                'input_tokens': 40, 'cache_read_input_tokens': 900, 'cache_creation_input_tokens': 60,
                'output_tokens': 7}}})[1]
        self.assertEqual((claude['input_tokens'], tr.fresh_input(claude)), (1000, 100))   # uncached 40 + cache write 60
        no_write = ClaudeAdapter().parse_record({'type': 'assistant', 'sessionId': 's', 'timestamp': at(1),
            'message': {'id': 'n', 'role': 'assistant', 'model': 'opus', 'usage': {
                'input_tokens': 40, 'cache_read_input_tokens': 900, 'output_tokens': 7}}})[1]
        self.assertIsNone(tr.fresh_input(no_write))   # cache creation unknown: fresh input is unknown, not 40
        codex = CodexAdapter().parse_record({'type': 'token_usage_record', 'timestamp': at(1), 'payload': {
            'response_id': 'r', 'session_id': 's', 'usage': {'input_tokens': 2000, 'cached_input_tokens': 1500,
                                                             'output_tokens': 9, 'total_tokens': 2009}}})[1]
        self.assertEqual((codex['input_tokens'], tr.fresh_input(codex)), (2000, 500))     # cached input is inside input
        antigravity = {'input_tokens': 300, 'cache_read_tokens': 200,
                       'semantics': ['input_includes_cache_read', 'thinking_in_output']}
        self.assertEqual(tr.fresh_input(antigravity), 100)                                 # its cache-exclusive input
        unflagged = {'input_tokens': 50, 'semantics': []}
        self.assertEqual(tr.fresh_input(dict(unflagged, cache_read_tokens=0)), 50)
        for unprovable in (dict(unflagged, cache_read_tokens=10), dict(unflagged, cache_read_tokens=None),
                           {'input_tokens': None, 'cache_read_tokens': 0},
                           {'input_tokens': 5, 'cache_read_tokens': 9, 'semantics': ['cache_inclusive_input']}):
            self.assertIsNone(tr.fresh_input(unprovable), unprovable)

    def test_classify_paths(self):
        for path in ('scripts/lib/token_usage_report_test.py', 'scripts/nogg-tests/x.py', 'tests/a.sh', 'pkg/test/a.go',
                     'src/__tests__/a.js', 'scripts/foo.test.sh', 'src/a.test.ts', 'src/a.spec.js', 'fixtures/a.json',
                     'tests/fixtures/x', 'test_api.py', 'go/x_test.go', 'testdata/in.txt'):
            self.assertEqual(tr.classify_path(path), 'test' if 'nogg-tests' not in path else 'production', path)
        for path in ('openspec/changes/x/tasks.md', '.beads/issues.jsonl', 'package-lock.json', 'web/yarn.lock',
                     'Cargo.lock', 'go.sum', 'uv.lock'):
            self.assertEqual(tr.classify_path(path), 'generated', path)
        for path in ('scripts/nogg', 'docs/token-usage.md', 'src/latest.py', 'scripts/test', 'contest/app.py'):
            self.assertEqual(tr.classify_path(path), 'production', path)
        self.assertEqual([tr.numstat_path(p) for p in ('src/{a.py => b.py}', 'old.py => new.py', 'a/{ => b}/c.py',
                                                        'a/{b => }/c.py')], ['src/b.py', 'new.py', 'a/b/c.py', 'a/c.py'])


def bead_facts():
    f = Facts()
    f.segment('lead', 'lead-sess', start=at(1), end=at(3))
    f.boundary('lead', 0, at(1), bead='SPEC-a').boundary('lead', 1, at(2), bead='SPEC-b')
    f.usage('lead', 'a1', at(1, 30), input=1000, cache_read=900, cache_write=60, output=40,
            semantics=['cache_summed_input'])
    f.usage('lead', 'b1', at(2, 30), input=500, cache_write=0, output=20, semantics=['cache_summed_input'])
    f.segment('cx', 'codex-sess', runtime='codex', start=at(1), end=at(2)).boundary('cx', 0, at(1), bead='SPEC-a')
    f.usage('cx', 'c1', at(1, 10), runtime='codex', input=2000, cache_read=1500, cache_write=None, output=100,
            semantics=['cache_inclusive_input'])
    f.segment('free', 'loose', start=at(4), end=at(5)).usage('free', 'u1', at(4, 30), input=10, output=1)
    return f


GIT_LINES = {'SPEC-a': {'commits': 2, 'production_lines': 100, 'test_lines': 30},
             'SPEC-b': {'commits': 0, 'production_lines': 0, 'test_lines': 0}}


class BeadViewTests(unittest.TestCase):
    def doc(self, lines=None, **filters):
        lo, hi = tr.window(at(0), at(12), NOW)
        context = {'bead_lines': (lambda beads: {b: GIT_LINES[b] for b in beads}) if lines else lines}
        return tr.report(bead_facts().tables, META, lo, hi, 'bead', filters, NOW, context)

    def test_rows_per_bead_and_runtime_with_unattributed_group(self):
        doc = self.doc(lines=True)
        work = lambda r: tuple(r['work']['tokens'][k] for k in tr.WORK_COUNTERS)
        self.assertEqual([(r['bead'], r['runtime'], r['events'], work(r), r['wall_runtime_ms'] // 60000, r['sessions'])
                          for r in doc['rows']],
                         [('SPEC-a', 'claude', 1, (100, 900, 60, 40, 1040), 60, ['lead-sess']),
                          ('SPEC-a', 'codex', 1, (500, 1500, 0, 100, 2100), 60, ['codex-sess']),
                          ('SPEC-b', 'claude', 1, (500, 0, 0, 20, 520), 60, ['lead-sess']),
                          (None, 'claude', 1, (10, 0, 5, 1, 11), 60, ['loose'])])
        self.assertEqual(doc['rows'][1]['work']['unknown_counters']['cache_write_tokens'], 1)   # Codex reported none
        self.assertEqual(doc['coverage']['unknown_bead'], 1)
        a_claude, a_codex, b_claude, loose = doc['rows']
        self.assertEqual((a_claude['commits'], a_claude['production_lines'], a_claude['test_lines'],
                          a_claude['per_production_line']),
                         (2, 100, 30, {'fresh_input_tokens': 1.0, 'output_tokens': 0.4, 'total_tokens': 10.4}))
        nulls = {'fresh_input_tokens': None, 'output_tokens': None, 'total_tokens': None}
        self.assertEqual((b_claude['commits'], b_claude['production_lines'], b_claude['per_production_line']),
                         (0, None, nulls))   # no commits: no production lines
        self.assertEqual((loose['commits'], loose['production_lines'], loose['per_production_line']), (None, None, nulls))
        totals = {t['bead']: t for t in doc['beads']}
        self.assertEqual((totals['SPEC-a']['runtimes'], totals['SPEC-a']['events'], work(totals['SPEC-a']),
                          totals['SPEC-a']['per_production_line'], totals['SPEC-a']['wall_runtime_ms'] // 60000),
                         (['claude', 'codex'], 2, (600, 2400, 60, 140, 3140),
                          {'fresh_input_tokens': 6.0, 'output_tokens': 1.4, 'total_tokens': 31.4}, 120))
        self.assertEqual([t['bead'] for t in doc['beads']], ['SPEC-a', 'SPEC-b', None])
        self.assertTrue(doc['git']['available'])
        self.assertTrue(any('production lines count' in n for n in doc['notes']))

    def test_without_git_every_git_field_is_null(self):
        doc = self.doc()
        self.assertFalse(doc['git']['available'])
        self.assertTrue(any('git attribution unavailable' in n for n in doc['notes']))
        for item in doc['rows'] + doc['beads']:
            self.assertEqual((item['commits'], item['production_lines'], item['test_lines'],
                              set(item['per_production_line'].values())), (None, None, None, {None}))
        unavailable = tr.report(bead_facts().tables, META, *tr.window(at(0), at(12), NOW), 'bead', {}, NOW,
                                {'bead_lines': lambda beads: None})
        self.assertEqual(unavailable['rows'][0]['commits'], None)

    def test_bead_filter_and_runtime_only_rows(self):
        doc = self.doc(lines=True, bead='SPEC-b')
        self.assertEqual([(r['bead'], r['events']) for r in doc['rows']], [('SPEC-b', 1)])
        self.assertEqual(report(bead_facts(), at(0), at(12), 'day', bead='SPEC-a')['rows'][0]['events'], 2)
        f = Facts().segment('quiet', 'quiet', start=at(1), end=at(2)).boundary('quiet', 0, at(1), bead='SPEC-a')
        lo, hi = tr.window(at(0), at(12), NOW)
        quiet = tr.report(f.tables, META, lo, hi, 'bead', {}, NOW, {'bead_lines': lambda b: GIT_LINES})['rows'][0]
        self.assertEqual((quiet['events'], quiet['wall_runtime_ms'], quiet['production_lines'],
                          quiet['per_production_line']['total_tokens']), (0, 60 * 60000, 100, None))
        with self.assertRaises(ReportError):
            tr.report(f.tables, META, lo, hi, 'week', {}, NOW)

    def test_test_cost_fields_are_additive_and_null_without_their_sources(self):
        plain = self.doc(lines=True)
        for item in plain['rows'] + plain['beads']:
            self.assertEqual((item['tests_added'], item['tests_deleted'], item['skips_added'], item['stage_seconds']),
                             (None, None, None, None))
        lo, hi = tr.window(at(0), at(12), NOW)
        tests = {'SPEC-a': {'tests_added': 4, 'tests_deleted': 1, 'skips_added': 2}}
        seconds = {'SPEC-a': {'commit': 12.0, 'bead': 310.0}, 'SPEC-b': {'bead': 5.5}}
        context = {'bead_lines': lambda beads: {b: GIT_LINES[b] for b in beads},
                   'bead_tests': lambda beads: tests, 'stage_seconds': lambda beads: seconds}
        doc = tr.report(bead_facts().tables, META, lo, hi, 'bead', {}, NOW, context)
        for key in ('commits', 'production_lines', 'test_lines', 'per_production_line'):
            self.assertEqual([r[key] for r in doc['rows']], [r[key] for r in plain['rows']])   # nothing existing moves
        a_claude, _, b_claude, loose = doc['rows']
        self.assertEqual((a_claude['tests_added'], a_claude['tests_deleted'], a_claude['skips_added']), (4, 1, 2))
        self.assertEqual(a_claude['stage_seconds'], {'changed': None, 'commit': 12.0, 'bead': 310.0, 'full': None})
        self.assertEqual((b_claude['tests_added'], b_claude['stage_seconds']['bead']), (None, 5.5))
        self.assertEqual((loose['tests_added'], loose['stage_seconds']), (None, None))
        total = {t['bead']: t for t in doc['beads']}['SPEC-a']
        self.assertEqual((total['tests_added'], total['skips_added']), (4, 2))
        lines = tr.render_bead_report(doc)
        self.assertIn('TESTS+', lines[0])
        self.assertEqual(lines[1].split()[-4:], ['4', '1', '2', '-/12/310/-'])
        self.assertEqual(lines[4].split()[-4:], ['-', '-', '-', '-/-/6/-'])

    def test_text_render(self):
        lines = tr.render_bead_report(self.doc(lines=True))
        self.assertEqual(lines[0].split()[:4], ['BEAD', 'AGENT', 'EVENTS', 'FRESH_IN'])
        self.assertIn('TOTAL/LINE', lines[0])
        self.assertEqual([l.split()[:2] for l in lines[1:]],
                         [['SPEC-a', 'claude'], ['SPEC-a', 'codex'], ['SPEC-a', 'all'], ['SPEC-b', 'claude'],
                          ['-', 'claude']])
        self.assertEqual(lines[1].split()[-7:-4], ['1.0', '0.4', '10.4'])
        self.assertIn('0+?', lines[2])              # Codex cache write unknown
        self.assertEqual(lines[4].split()[-9:], ['0'] + ['-'] * 8)
        self.assertEqual(lines[5].split()[-9:], ['-'] * 9)
        long = self.doc(lines=True)
        long['rows'][0]['bead'] = 'loadcompass-03v'
        self.assertTrue(tr.render_bead_report(long)[1].startswith('loadcompass-03v '))   # never truncated


@unittest.skipUnless(shutil.which('git'), 'git not installed')
class UsageViewTests(unittest.TestCase):
    """The additive day and model view reconciled with report() over one set of facts."""

    def views(self, facts):
        return tr.usage_views(facts.tables, *tr.WHOLE_HISTORY)

    def bead_rows(self, facts):
        return tr.report(facts.tables, META, *tr.WHOLE_HISTORY, 'bead', {}, NOW)['rows']

    def test_the_views_add_up_to_the_report_totals(self):
        facts = bead_facts()
        facts.segment('old', 'old-sess', start=at(1, day=9), end=at(2, day=9))
        facts.usage('old', 'd1', at(1, 30, day=9), input=70, cache_read=0, cache_write=0, output=7)
        views = self.views(facts)
        days = tr.report(facts.tables, META, *tr.WHOLE_HISTORY, 'day', {}, NOW)['rows']
        for key in ('output_tokens', 'cache_read_tokens'):
            for bucket in days:
                self.assertEqual(sum(work['tokens'][key] for work in views['by_day'][bucket['bucket'][:10]].values()),
                                 bucket['tokens'][key], bucket['bucket'])
        for key in tr.WORK_COUNTERS:
            for part in ('tokens', 'unknown_counters'):
                by_bead = sum(row['work'][part][key] for row in self.bead_rows(facts))
                self.assertEqual(sum(work[part][key] for work in views['by_model'].values()), by_bead, key)
                self.assertEqual(sum(work[part][key] for runtimes in views['by_day'].values()
                                     for work in runtimes.values()), by_bead, key)
        self.assertEqual(views['floors'], {'claude': at(1, 30, day=9), 'codex': at(1, 10)})

    def test_a_partial_runtime_is_named_and_its_known_sum_stays_known(self):
        facts = Facts().segment('p', 'pi-sess', runtime='pi')
        facts.usage('p', 'known', at(1), runtime='pi', input=10, cache_read=0, cache_write=0, output=5)
        facts.usage('p', 'blind', at(2), runtime='pi', input=None, cache_read=None, output=None)
        facts.segment('c', 'claude-sess').usage('c', 'whole', at(3), input=4, cache_read=0, cache_write=0, output=1)
        views = self.views(facts)
        self.assertEqual(views['partial'], ['pi'])
        work = views['by_day'][at(0)[:10]]['pi']
        self.assertEqual(work['tokens']['output_tokens'], 5)
        self.assertEqual(work['unknown_counters']['output_tokens'], 1)

    def test_an_incomplete_fact_names_its_runtime(self):
        facts = Facts().segment('c', 'claude-sess')
        facts.usage('c', 'gap', at(1), input=4, cache_read=0, cache_write=0, output=1, completeness='partial')
        self.assertEqual(self.views(facts)['partial'], ['claude'])

    def test_consumption_across_a_day_stays_out_of_the_days(self):
        facts = Facts().segment('a', 'agy-sess', runtime='antigravity')
        facts.usage('a', 'run', at(1, day=11), runtime='antigravity', input=30, cache_read=0, cache_write=0, output=3,
                    semantics=['coarse_from:' + at(23, day=10)])
        views = self.views(facts)
        self.assertEqual(views['by_day'], {})
        self.assertEqual(views['partial'], ['antigravity'])
        self.assertEqual(views['by_model']['luna']['tokens']['output_tokens'], 3)

    def test_an_untimed_fact_counts_nowhere_and_names_its_runtime(self):
        facts = Facts().segment('c', 'claude-sess').usage('c', 'lost', None, input=4, output=1)
        self.assertEqual(self.views(facts), {'by_day': {}, 'by_model': {}, 'floors': {}, 'partial': ['claude']})

    def test_a_window_narrows_the_work_but_not_the_floor(self):
        facts = bead_facts()
        views = tr.usage_views(facts.tables, *tr.window(at(2), at(3), NOW))
        self.assertEqual(sum(work['tokens']['output_tokens'] for work in views['by_model'].values()), 20)
        self.assertEqual(views['floors']['claude'], at(1, 30))


class GitAttributionTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='T', GIT_AUTHOR_EMAIL='t@example.org',
                        GIT_COMMITTER_NAME='T', GIT_COMMITTER_EMAIL='t@example.org')
        self.git('init', '-q', '-b', 'develop')
        self.git('commit', '-q', '--allow-empty', '-m', 'init')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True, capture_output=True, text=True,
                              env=self.env).stdout.strip()

    def commit(self, subject, files):
        for path, lines in files.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(lines) if isinstance(lines, bytes) else target.write_text(
                ''.join(f'line {i}\n' for i in range(lines)) if isinstance(lines, int) else lines)
        self.git('add', '-A')
        self.git('commit', '-q', '-m', subject)
        return self.git('rev-parse', 'HEAD')

    def test_production_lines_from_bead_commits(self):
        self.commit('feat: add [SPEC-a]', {'src/app.py': 10, 'docs/guide.md': 2, 'src/app_test.py': 5,
                                           'tests/run.sh': 3, 'scripts/x.test.sh': 2, 'fixtures/data.json': 3,
                                           'openspec/changes/x.md': 4, 'package-lock.json': 6})
        self.commit('fix: tweak [SPEC-a] [loadcompass-wum2]', {'src/app.py': 'changed\n' + ''.join(
            f'line {i}\n' for i in range(1, 10))})
        (self.repo / 'lib').mkdir()
        self.git('mv', 'src/app.py', 'lib/app.py')
        self.commit('refactor: move [SPEC-b]', {'img.png': b'\x00\x01binary\x00'})
        self.commit('feat: lookalike [SPEC-ab]', {'src/other.py': 7})
        self.git('checkout', '-q', '-b', 'topic')
        side = self.commit('feat: side [SPEC-c]', {'src/side.py': 1})
        self.git('checkout', '-q', 'develop')
        self.git('cherry-pick', side)                 # a copy: same author time and subject
        self.git('checkout', '-q', '-b', 'merged')
        self.commit('feat: merged work [SPEC-d]', {'src/d.py': 2})
        self.git('checkout', '-q', 'develop')
        self.git('merge', '-q', '--no-ff', '-m', 'merge [SPEC-a]', 'merged')   # merges never count
        found = tr.bead_git_lines(self.repo, ['SPEC-a', 'SPEC-b', 'SPEC-c', 'SPEC-d', 'loadcompass-wum2', 'SPEC-none'])
        self.assertEqual(found, {'SPEC-a': {'commits': 2, 'production_lines': 14, 'test_lines': 13},
                                 'SPEC-b': {'commits': 1, 'production_lines': 0, 'test_lines': 0},
                                 'SPEC-c': {'commits': 1, 'production_lines': 1, 'test_lines': 0},
                                 'SPEC-d': {'commits': 1, 'production_lines': 2, 'test_lines': 0},
                                 'loadcompass-wum2': {'commits': 1, 'production_lines': 2, 'test_lines': 0},
                                 'SPEC-none': {'commits': 0, 'production_lines': 0, 'test_lines': 0}})
        doc = tr.report(bead_facts().tables, META, *tr.window(at(0), at(12), NOW), 'bead', {}, NOW,
                        {'bead_lines': lambda beads: tr.bead_git_lines(self.repo, beads)})
        self.assertEqual([(r['bead'], r['commits'], r['production_lines']) for r in doc['rows']],
                         [('SPEC-a', 2, 14), ('SPEC-a', 2, 14), ('SPEC-b', 1, 0), (None, None, None)])
        self.assertEqual(doc['rows'][2]['per_production_line']['total_tokens'], None)   # zero production lines

    def test_bead_commits_lists_rebased_copies_once(self):
        side_branch = self.git('rev-parse', '--abbrev-ref', 'HEAD')
        self.git('checkout', '-q', '-b', 'topic')
        side = self.commit('feat: side [SPEC-c]', {'src/side.py': 3})
        self.git('checkout', '-q', side_branch)
        self.commit('chore: no token', {'notes.txt': 1})
        self.git('cherry-pick', side)                 # a copy: same author time and subject
        found = tr.bead_commits(self.repo, {'SPEC-c'})
        self.assertEqual([(c['subject'], c['beads'], c['production_lines'], c['test_lines'])
                          for c in found['commits']], [('feat: side [SPEC-c]', ['SPEC-c'], 3, 0)])
        self.assertEqual(found['tokenless'], 2)       # the seed commit and `no token`
        self.assertIsInstance(found['commits'][0]['at'], int)

    def test_bead_commits_asks_git_only_for_unseen_commits(self):
        first = self.commit('feat: one [SPEC-a]', {'src/one.py': 2})
        calls, cache = [], {}
        def run(argv, **kwargs):
            calls.append(kwargs.get('input'))
            return subprocess.run(argv, **kwargs)
        tr.bead_commits(self.repo, {'SPEC-a'}, run=run, numstat=cache)
        self.assertEqual(calls[-1], first + '\n')
        second = self.commit('feat: two [SPEC-a]', {'src/two.py': 4})
        found = tr.bead_commits(self.repo, {'SPEC-a'}, run=run, numstat=cache)
        self.assertEqual(calls[-1], second + '\n')
        self.assertEqual(sorted(c['production_lines'] for c in found['commits']), [2, 4])
        calls.clear()
        tr.bead_commits(self.repo, {'SPEC-a'}, run=run, numstat=cache)
        self.assertEqual(calls, [None], 'nothing new, so only the log runs')

    def test_git_unavailable(self):
        outside = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, outside, ignore_errors=True)
        self.assertIsNone(tr.bead_git_lines(outside, ['SPEC-a']))
        def missing(*args, **kwargs):
            raise FileNotFoundError('git')
        self.assertIsNone(tr.bead_git_lines(self.repo, ['SPEC-a'], run=missing))
        def slow(*args, **kwargs):
            raise subprocess.TimeoutExpired(args[0], kwargs.get('timeout'))
        self.assertIsNone(tr.bead_git_lines(self.repo, ['SPEC-a'], run=slow))
        self.assertEqual(tr.bead_git_lines(self.repo, []), {})

    def test_non_utf8_paths_and_subjects_never_fail_the_view(self):
        name = os.fsdecode(b'src/caf\xe9.py')   # a Latin-1 file name, not valid UTF-8
        self.commit('feat: latin-1 [SPEC-a]', {name: 4})
        found = tr.bead_git_lines(self.repo, ['SPEC-a'])
        self.assertEqual(found['SPEC-a'], {'commits': 1, 'production_lines': 4, 'test_lines': 0})


class BoundedLoadTests(unittest.TestCase):
    def test_loaders_pass_the_timeout_and_skip_payloads_for_counts(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        store = Store(tmp, lambda _: {'state_dir': str(tmp)})
        self.assertEqual(tr.load_counts(store, timeout=1), (None, {t: 0 for t in FIELDS}))
        self.assertIsNone(tr.load_meta(store))
        (store.database / '.dolt').mkdir(parents=True)
        calls = []
        def fake(*args, sql=None, timeout=None):
            calls.append((args[-1], timeout))
            if 'store_meta' in args[-1]:
                return json.dumps({'rows': [dict(META, identity_version=1, project_id=META['project_id'])]})
            if 'UNION ALL' in args[-1]:
                return json.dumps({'rows': [{'fact_table': 'usage_events', 'source_id': 's', 'event_id': 'e',
                                             'source_ordinal': o} for o in (0, 1)]})
            raise StoreTimeout('local Dolt timed out after 7s; usage evidence must remain pending', 7)
        store._dolt = fake
        meta, counts = tr.load_counts(store, timeout=7)
        self.assertEqual((meta['project_id'], counts['usage_events'], counts['session_segments']), (META['project_id'], 1, 0))
        self.assertEqual({t for _, t in calls}, {7})
        self.assertFalse(any('current_' in sql or 'SELECT *' in sql and 'store_meta' not in sql for sql, _ in calls))
        with self.assertRaises(StoreTimeout):
            tr.load_facts(store, timeout=7)


@unittest.skipUnless(shutil.which('dolt'), 'dolt not installed')
class DoltRecoveryTests(unittest.TestCase):
    def test_export_recovery_then_recollection_keeps_totals(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        f = Facts().segment('s', 'sess', end=at(2)).boundary('s', 0, at(0)).usage('s', 'e', at(1))
        strip = lambda rows: [(t, {k: v for k, v in r.items() if k not in ('fact_id', 'content_hash')})
                              for t, items in rows.items() for r in items]
        original = Store(tmp, lambda _: {'state_dir': str(tmp / 'a')})
        original.initialize()
        original.append(strip(f.tables))
        meta, facts = tr.load_facts(original)
        lines = list(tr.export_lines(facts, meta, *tr.window(at(0), at(12), NOW), NOW))
        recovered = Store(tmp, lambda _: {'state_dir': str(tmp / 'b')})
        project, records, registry = tr.import_records(lines, None)
        recovered.initialize(project_id=project)
        self.assertEqual(recovered.check_schema()['project_id'], meta['project_id'])
        recovered.append(records)
        recovered.append(strip(f.tables))   # the same facts collected again
        meta2, facts2 = tr.load_facts(recovered)
        lo, hi = tr.window(at(0), at(12), NOW)
        totals = lambda m, fs: tr.report(fs, m, lo, hi, 'day', {}, NOW)['rows'][0]['tokens']
        self.assertEqual(totals(meta2, facts2), totals(meta, facts))
        self.assertEqual(len(facts2['usage_events']), 1)

    def test_large_import_and_registry_roundtrip(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        device = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        store = Store(tmp, lambda _: {'state_dir': str(tmp / 'a')})
        store.initialize()
        store.register_devices([{'device_id': device, 'hostname': 'pi'}])
        many = [('usage_events', {'source_id': 'claude:big', 'event_id': f'e{i}', 'revision': 'v1',
                                  'source_ordinal': 0, 'source_timestamp': at(1), 'input_tokens': 1})
                for i in range(2500)]
        self.assertEqual(store.append(many, owners={'claude:big': device}), 2501)   # past the old ARG_MAX failure
        self.assertEqual(store.append(many, owners={'claude:big': device}), 0)
        meta, facts = tr.load_facts(store)
        lines = list(tr.export_lines(facts, meta, *tr.window(at(0), at(12), NOW), NOW, store.registry()))
        project, records, registry = tr.import_records(lines, None)
        self.assertEqual((len(records), registry['source_owners']), (2500, {'claude:big': device}))
        self.assertEqual([r['device_id'] for r in registry['devices']], [device])


if __name__ == '__main__':
    unittest.main()
