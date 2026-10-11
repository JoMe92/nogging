"""Report/session/export tests over synthetic current facts (plus real Dolt)."""
import datetime as dt
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import token_usage_report as tr
from token_usage_report import ReportError
from token_usage_store import FIELDS, Store, fact

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

    def boundary(self, seg, index, when, task='TASK-1', complexity='standard', effort=None):
        self.tables['attribution_events'].append(row('attribution_events', source_id=f'nogg-session:{seg}',
            event_id=f'boundary:{index}', source_timestamp=when, segment_id=seg, task_id=task, bead_id='SPEC-1',
            change_id='change', role='lead', complexity=complexity, complexity_source='launch',
            vocabulary_version='1', requested_model='requested-model', configured_effort=effort))
        return self

    def usage(self, seg, event, when, model='luna', input=100, output=10, cache_write=5, semantics=None,
              runtime='claude', duration=1000):
        self.tables['usage_events'].append(row('usage_events', source_id=f'{runtime}:conv-{seg}', event_id=event,
            source_timestamp=when, segment_id=seg, runtime=runtime, provider='p', model=model,
            input_tokens=input, output_tokens=output, cache_read_tokens=0, cache_write_tokens=cache_write,
            thinking_tokens=0, inference_duration_ms=duration, completeness='complete',
            semantics=semantics or [], raw_usage={'input_tokens': input}))
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
        project, records = tr.import_records(lines, META)
        self.assertEqual(project, META['project_id'])
        self.assertEqual(sorted({t for t, _ in records}),
                         ['attribution_events', 'lifecycle_events', 'session_segments', 'usage_events'])
        self.assertEqual([v['event_id'] for t, v in records if t == 'usage_events'], ['e'])
        tampered = [lines[0]] + [l.replace('"input_tokens": 100', '"input_tokens": 999') for l in lines[1:]]
        with self.assertRaises(ReportError):
            tr.import_records(tampered, META)
        with self.assertRaises(ReportError):
            tr.import_records(lines, {'project_id': '22222222-2222-4222-8222-222222222222'})


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
        project, records = tr.import_records(lines, None)
        recovered.initialize(project_id=project)
        self.assertEqual(recovered.check_schema()['project_id'], meta['project_id'])
        recovered.append(records)
        recovered.append(strip(f.tables))   # the same facts collected again
        meta2, facts2 = tr.load_facts(recovered)
        lo, hi = tr.window(at(0), at(12), NOW)
        totals = lambda m, fs: tr.report(fs, m, lo, hi, 'day', {}, NOW)['rows'][0]['tokens']
        self.assertEqual(totals(meta2, facts2), totals(meta, facts))
        self.assertEqual(len(facts2['usage_events']), 1)


if __name__ == '__main__':
    unittest.main()
