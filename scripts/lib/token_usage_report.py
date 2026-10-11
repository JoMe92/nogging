"""Consumption reports over the local usage store (no prices, no quota percent).

Pure functions over loaded current facts, so windows, buckets, filters,
coarse attribution and runtime clipping are testable without Dolt. All
windows are half-open UTC [from, to); hour/day buckets are UTC.
"""
import datetime as dt
import json
from pathlib import Path

from token_usage_store import FIELDS, JSON_FIELDS, StoreError, fact

REPORT_SCHEMA = 'nogg.token-usage.report/v1'
SESSION_SCHEMA = 'nogg.token-usage.session/v1'
STATUS_SCHEMA = 'nogg.token-usage.status/v1'
EXPORT_SCHEMA = 'nogg.token-usage.export/v1'
TOKEN_COUNTERS = ('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens',
                  'thinking_tokens', 'provider_total_tokens')
COMPLEXITIES = ('routine', 'standard', 'complex', 'unknown')
RUNTIMES = ('claude', 'codex', 'antigravity', 'pi')
FILTERS = ('project', 'device', 'runtime', 'provider', 'model', 'task', 'complexity', 'effort')
NOTES = ['token sums are known source-reported consumption, not billed cost or quota percentage',
         'known sums are complete only where coverage reports no unknown or unsupported sources']


class ReportError(ValueError):
    """Invalid window or filter; the message carries the remedy."""


def parse_utc(value, name):
    """ISO date or datetime with an explicit offset; dates are UTC midnight."""
    if not isinstance(value, str) or not value:
        raise ReportError(f'--{name} needs an ISO-8601 time, e.g. 2026-10-11T00:00:00Z')
    try:
        if len(value) == 10:
            return dt.datetime.combine(dt.date.fromisoformat(value), dt.time(), dt.timezone.utc)
        stamp = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError as exc:
        raise ReportError(f'--{name} {value!r} is not ISO-8601; use e.g. 2026-10-11T00:00:00Z') from exc
    if stamp.tzinfo is None:
        raise ReportError(f'--{name} {value!r} has no UTC offset; append Z or +00:00')
    return stamp.astimezone(dt.timezone.utc)


def window(start, end, now):
    """Validated half-open UTC window; the default is the current UTC day."""
    if (start is None) != (end is None):
        raise ReportError('pass both --from and --to, or neither for the current UTC day')
    if start is None:
        lo = dt.datetime.combine(now.astimezone(dt.timezone.utc).date(), dt.time(), dt.timezone.utc)
        return lo, lo + dt.timedelta(days=1)
    lo, hi = parse_utc(start, 'from'), parse_utc(end, 'to')
    if lo >= hi:
        raise ReportError('--from must be earlier than --to (the window is half-open [from, to))')
    return lo, hi


def validate_filters(filters):
    out = {k: v for k, v in (filters or {}).items() if v is not None}
    unknown = set(out) - set(FILTERS)
    if unknown:
        raise ReportError(f'unsupported filter(s): {", ".join(sorted(unknown))}')
    if 'complexity' in out and out['complexity'] not in COMPLEXITIES:
        raise ReportError(f'--complexity must be one of {", ".join(COMPLEXITIES)}')
    if 'runtime' in out and out['runtime'] not in RUNTIMES:
        raise ReportError(f'--runtime must be one of {", ".join(RUNTIMES)}')
    for key, value in out.items():
        if not isinstance(value, str) or not value.strip() or len(value) > 512:
            raise ReportError(f'--{key} needs a non-empty value')
    return out


def iso(stamp):
    return stamp.astimezone(dt.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def ts(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        stamp = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None
    return (stamp if stamp.tzinfo else stamp.replace(tzinfo=dt.timezone.utc)).astimezone(dt.timezone.utc)


def bucket_start(stamp, group_by):
    if group_by == 'hour':
        return stamp.replace(minute=0, second=0, microsecond=0)
    return stamp.replace(hour=0, minute=0, second=0, microsecond=0)


def bucket_span(group_by):
    return dt.timedelta(hours=1) if group_by == 'hour' else dt.timedelta(days=1)


def decode_row(table, row):
    """Store row -> allowlisted fact values (JSON columns decoded)."""
    values = {}
    for key in FIELDS[table]:
        value = row.get(key)
        if key in JSON_FIELDS and isinstance(value, str):
            value = json.loads(value)
        elif isinstance(value, float) and value.is_integer():
            value = int(value)
        values[key] = value
    return values


def load_facts(store):
    """Current (latest-revision) facts by table; empty when no store exists."""
    if not (store.database / '.dolt').exists():
        return None, {t: [] for t in FIELDS}
    meta = store.check_schema()
    facts = {}
    for table in FIELDS:
        rows = store.query(f'SELECT * FROM current_{table}')
        facts[table] = [dict(decode_row(table, r), fact_id=r['fact_id'], content_hash=r['content_hash'])
                        for r in rows]
    return meta, facts


class Model:
    """Indexed view joining usage to segments, attribution and lifecycle."""

    def __init__(self, facts):
        self.segments = {f['source_id'].split(':', 1)[1]: f for f in facts['session_segments']
                         if f['source_id'].startswith('nogg-session:')}
        self.boundaries = {}
        for f in facts['attribution_events']:
            self.boundaries.setdefault(f['segment_id'], []).append(f)
        def index(event_id):
            tail = str(event_id).rsplit(':', 1)[-1]
            return int(tail) if tail.isdigit() else -1
        for items in self.boundaries.values():
            items.sort(key=lambda f: (ts(f['source_timestamp']) or dt.datetime.min.replace(tzinfo=dt.timezone.utc),
                                      index(f['event_id'])))
        self.lifecycle = {}
        for f in facts['lifecycle_events']:
            self.lifecycle.setdefault(f['segment_id'], {})[f['event_id']] = f
        self.usage = facts['usage_events']

    def session_key(self, segment):
        """Grouping key: the supervised session name (all of its segments)."""
        return (self.segments.get(segment) or {}).get('supervised_id') or segment

    def segments_of(self, ident):
        if ident in self.segments:
            return [ident]
        return sorted((s for s, f in self.segments.items() if f.get('supervised_id') == ident),
                      key=lambda s: ts(self.segments[s].get('source_timestamp')) or dt.datetime.min.replace(tzinfo=dt.timezone.utc))

    def attribution(self, segment, stamp):
        """Latest boundary at or before stamp; None when unprovable."""
        owner = None
        for boundary in self.boundaries.get(segment, []):
            at = ts(boundary['source_timestamp'])
            if stamp is not None and at is not None and at <= stamp:
                owner = boundary
        return owner

    def interval(self, segment):
        """(start, end, quality) of a segment's observed runtime."""
        events = self.lifecycle.get(segment, {})
        start = ts((events.get('start') or {}).get('source_timestamp'))
        if start is None:
            return None
        exit_fact, beat = events.get('exit'), events.get('liveness')
        if exit_fact and ts(exit_fact['source_timestamp']):
            quality = 'complete' if exit_fact['kind'] == 'exit' else 'partial'
            return start, max(start, ts(exit_fact['source_timestamp'])), quality
        if beat and ts(beat['source_timestamp']):
            return start, max(start, ts(beat['source_timestamp'])), 'provisional'
        return start, start, 'provisional'

    def runtime_pieces(self, segment):
        """Segment runtime split at attribution boundaries: (lo, hi, boundary, quality)."""
        span = self.interval(segment)
        if span is None:
            return []
        start, end, quality = span
        cuts = [(ts(b['source_timestamp']), b) for b in self.boundaries.get(segment, [])
                if ts(b['source_timestamp']) is not None]
        pieces, current, cursor = [], None, start
        for at, boundary in cuts:
            if at <= start:
                current = boundary
                continue
            if at >= end:
                break
            pieces.append((cursor, at, current, quality))
            cursor, current = at, boundary
        pieces.append((cursor, end, current, quality))
        return pieces


def dimension(model, usage, boundary, key):
    segment = model.segments.get(usage.get('segment_id')) if usage else None
    if key == 'device':
        return (segment or {}).get('device_id')
    if key in ('runtime', 'provider', 'model'):
        return usage.get(key)
    if key == 'task':
        return (boundary or {}).get('task_id')
    if key == 'complexity':
        return (boundary or {}).get('complexity') or 'unknown'
    if key == 'effort':
        return usage.get('effort') or (boundary or {}).get('configured_effort')
    return None


def empty_metrics():
    return {'events': 0,
            'tokens': {c: 0 for c in TOKEN_COUNTERS},
            'unknown_counters': {c: 0 for c in TOKEN_COUNTERS + ('inference_duration_ms',)},
            'inference_duration_ms': 0}


def add_usage(metrics, usage):
    metrics['events'] += 1
    for counter in TOKEN_COUNTERS + ('inference_duration_ms',):
        value = usage.get(counter)
        if value is None:
            metrics['unknown_counters'][counter] += 1
        elif counter == 'inference_duration_ms':
            metrics['inference_duration_ms'] += value
        else:
            metrics['tokens'][counter] += value


def coarse_interval(usage):
    """Observation interval start for cumulative-only (coarse) facts."""
    for flag in usage.get('semantics') or []:
        if isinstance(flag, str) and flag.startswith('coarse_from:'):
            return ts(flag.split(':', 1)[1])
    return None


def overlap(lo, hi, a, b):
    start, end = max(lo, a), min(hi, b)
    return (end - start) if end > start else dt.timedelta(0)


def report(facts, meta, start, end, group_by, filters, now, context=None):
    """Build the versioned report document."""
    filters = validate_filters(filters)
    if group_by not in ('hour', 'day', 'session'):
        raise ReportError('--group-by must be hour, day or session')
    model = Model(facts)
    project = (meta or {}).get('project_id')
    project_match = 'project' not in filters or filters['project'] == project
    rows, coarse = {}, []
    coverage = {'events_in_window': 0, 'untimed_events': 0, 'unknown_model': 0, 'unknown_task': 0,
                'unknown_complexity': 0, 'unattributed_segment': 0, 'completeness': {}}

    def row_for(key, segment=None):
        if key not in rows:
            rows[key] = dict(empty_metrics(), wall_runtime_ms=0, runtime_quality=set(), by_model={},
                             coarse_events=0)
            if group_by == 'session':
                segs = model.segments_of(key) if key in {model.session_key(s) for s in model.segments} else [segment]
                first = model.segments.get(segs[0]) or {} if segs else {}
                rows[key].update(session=first.get('supervised_id'), segments=segs,
                                 runtime=first.get('runtime'), device=first.get('device_id'),
                                 attribution=[{k: b.get(k) for k in ('task_id', 'bead_id', 'change_id', 'role',
                                               'complexity', 'complexity_source', 'requested_model')}
                                              | {'at': b.get('source_timestamp'), 'segment_id': s}
                                              for s in segs for b in model.boundaries.get(s, [])])
            else:
                rows[key].update(bucket=iso(key), bucket_end=iso(key + bucket_span(group_by)))
        return rows[key]

    def matches(usage, boundary, keys=None):
        return project_match and all(
            (lambda d: d if d is not None else 'unknown')(dimension(model, usage, boundary, k)) == v
            for k, v in filters.items() if k != 'project' and (keys is None or k in keys))
    for usage in (model.usage if project_match else []):
        stamp = ts(usage.get('source_timestamp'))
        if stamp is None:
            # No window can place it; count it when its own dimensions match.
            if matches(usage, None, keys=('device', 'runtime', 'provider', 'model', 'effort')):
                coverage['untimed_events'] += 1
            continue
        if not (start <= stamp < end):
            continue
        boundary = model.attribution(usage.get('segment_id'), stamp)
        if not matches(usage, boundary):
            continue
        coverage['events_in_window'] += 1
        coverage['unknown_model'] += usage.get('model') is None
        coverage['unknown_task'] += (boundary or {}).get('task_id') is None
        coverage['unknown_complexity'] += dimension(model, usage, boundary, 'complexity') == 'unknown'
        coverage['unattributed_segment'] += usage.get('segment_id') is None
        state = usage.get('completeness') or 'unknown'
        coverage['completeness'][state] = coverage['completeness'].get(state, 0) + 1
        observed_from = coarse_interval(usage)
        if group_by != 'session' and observed_from is not None and \
                bucket_start(observed_from, group_by) != bucket_start(stamp, group_by):
            # Never invent a split of cumulative-only consumption across buckets.
            entry = dict(empty_metrics(), interval_from=iso(observed_from), interval_to=iso(stamp),
                         quality='coarse', model=usage.get('model'), segment_id=usage.get('segment_id'))
            add_usage(entry, usage)
            coarse.append(entry)
            continue
        key = model.session_key(usage.get('segment_id')) if group_by == 'session' else bucket_start(stamp, group_by)
        row = row_for(key, usage.get('segment_id'))
        add_usage(row, usage)
        row['coarse_events'] += observed_from is not None   # disclosed, never split
        by_model = row['by_model'].setdefault(usage.get('model') or 'unknown', empty_metrics())
        add_usage(by_model, usage)

    runtime_note = None
    if any(k in filters for k in ('model', 'provider')):
        runtime_note = 'wall runtime is per session, not per model or provider; omitted under model/provider filters'
    elif project_match:
        for segment in model.segments:
            for lo, hi, boundary, quality in model.runtime_pieces(segment):
                pseudo = {'segment_id': segment, 'runtime': model.segments[segment].get('runtime')}
                if not all(dimension(model, pseudo, boundary, k) == v for k, v in filters.items()
                           if k not in ('project',)):
                    continue
                if group_by == 'session':
                    piece = overlap(lo, hi, start, end)
                    if piece:
                        row = row_for(model.session_key(segment), segment)
                        row['wall_runtime_ms'] += int(piece.total_seconds() * 1000)
                        row['runtime_quality'].add(quality)
                    continue
                cursor = bucket_start(max(lo, start), group_by)
                while cursor < min(hi, end):
                    piece = overlap(lo, hi, max(cursor, start), min(cursor + bucket_span(group_by), end))
                    if piece:
                        row = row_for(cursor)
                        row['wall_runtime_ms'] += int(piece.total_seconds() * 1000)
                        row['runtime_quality'].add(quality)
                    cursor += bucket_span(group_by)
    ordered = []
    for key in sorted(rows, key=lambda k: (str(k))):
        row = rows[key]
        row['runtime_quality'] = sorted(row['runtime_quality'])
        if runtime_note:
            row['wall_runtime_ms'] = None
        ordered.append(row)
    context = context or {}
    notes = list(NOTES) + ([runtime_note] if runtime_note else [])
    if not project_match:
        notes.append(f'this store belongs to project {project}; no facts match --project')
    return {'schema': REPORT_SCHEMA, 'as_of': iso(now), 'project_id': project,
            'window': {'from': iso(start), 'to': iso(end), 'half_open': True, 'timezone': 'UTC'},
            'group_by': group_by, 'filters': filters, 'rows': ordered, 'coarse': coarse,
            'coverage': dict(coverage, sources=context.get('sources', {})),
            'pending': context.get('pending', {}), 'sync': context.get('sync', {'state': 'not_configured',
                                                                                    'local_only': True}),
            'store': context.get('store', 'present' if meta else 'absent'), 'notes': notes}


def session(facts, meta, ident, now, context=None):
    """Lifetime facts for one supervised session (name or segment ID)."""
    model = Model(facts)
    segments = model.segments_of(ident)
    if not segments:
        raise ReportError(f'no usage facts for session {ident!r}; run `nogg token-usage collect --session {ident}`')
    totals, by_model, untimed = empty_metrics(), {}, 0
    for usage in model.usage:
        if usage.get('segment_id') not in segments:
            continue
        add_usage(totals, usage)
        add_usage(by_model.setdefault(usage.get('model') or 'unknown', empty_metrics()), usage)
        untimed += ts(usage.get('source_timestamp')) is None
    parts, runtime, qualities = [], 0, set()
    for segment in segments:
        span = model.interval(segment)
        if span:
            runtime += int((span[1] - span[0]).total_seconds() * 1000)
            qualities.add(span[2])
        parts.append({'segment_id': segment, 'started_at': span and iso(span[0]), 'ended_at': span and iso(span[1]),
                      'runtime_quality': span[2] if span else 'unknown',
                      'lifecycle': {k: {'kind': v.get('kind'), 'at': v.get('source_timestamp')}
                                    for k, v in sorted(model.lifecycle.get(segment, {}).items())}})
    seg = model.segments[segments[0]]
    return {'schema': SESSION_SCHEMA, 'as_of': iso(now), 'project_id': (meta or {}).get('project_id'),
            'segment_id': segments[-1], 'segments': parts, 'session': seg.get('supervised_id'),
            'runtime': seg.get('runtime'), 'device': seg.get('device_id'),
            # Sum of observed segments: restart downtime between them is excluded.
            'wall_runtime_ms': runtime if qualities else None,
            'runtime_quality': ('partial' if 'partial' in qualities else 'provisional' if 'provisional' in qualities
                                else 'complete' if qualities else 'unknown'),
            'attribution': [{k: b.get(k) for k in ('task_id', 'bead_id', 'change_id', 'planning_id', 'role',
                             'complexity', 'complexity_source', 'vocabulary_version', 'requested_model',
                             'model_source', 'configured_effort', 'selection_version', 'selection_hash')}
                            | {'at': b.get('source_timestamp'), 'segment_id': s}
                            for s in segments for b in model.boundaries.get(s, [])],
            'totals': totals, 'by_model': by_model, 'untimed_events': untimed,
            'sources': (context or {}).get('sources', {}).get(seg.get('supervised_id'), {}),
            'notes': list(NOTES)}


def export_lines(facts, meta, start, end, now, registry=None):
    """Versioned JSONL: header, then facts with stable identities. Usage facts
    are selected by completion time, and untimed usage facts are always
    included (no window can place them). Sessions whose events or observed
    runtime overlap the window follow with all their session facts, then the
    device and source-ownership registry rows those facts need."""
    model = Model(facts)
    usage = [f for f in facts['usage_events'] if ts(f.get('source_timestamp')) is None
             or start <= ts(f['source_timestamp']) < end]
    segments = {f.get('segment_id') for f in usage}
    for table in ('lifecycle_events', 'attribution_events'):
        for f in facts[table]:
            stamp = ts(f.get('source_timestamp'))
            if stamp is not None and start <= stamp < end:
                segments.add(f.get('segment_id'))
    for segment in model.segments:
        span = model.interval(segment)
        if span and span[0] < end and max(span[1], span[0]) >= start:
            segments.add(segment)
    segments.discard(None)
    yield json.dumps({'schema': EXPORT_SCHEMA, 'project_id': (meta or {}).get('project_id'),
                      'from': iso(start), 'to': iso(end), 'exported_at': iso(now)}, sort_keys=True)
    selected = [('session_segments', f) for f in facts['session_segments']
                if f['source_id'].split(':', 1)[-1] in segments]
    selected += [(t, f) for t in ('lifecycle_events', 'attribution_events') for f in facts[t]
                 if f.get('segment_id') in segments]
    selected += [('usage_events', f) for f in usage]
    for table, f in selected:
        values = {k: f[k] for k in FIELDS[table]}
        yield json.dumps({'table': table, 'fact_id': f['fact_id'], 'content_hash': f['content_hash'],
                          'fact': values}, sort_keys=True)
    registry = registry or {}
    sources = {f['source_id'] for _, f in selected}
    devices = {f.get('device_id') for t, f in selected if t == 'session_segments'}
    owners = [r for r in registry.get('source_owners', []) if r.get('source_id') in sources]
    devices |= {r.get('device_id') for r in owners}
    for row in registry.get('devices', []):
        if row.get('device_id') in devices:
            yield json.dumps({'registry': 'devices', 'row': {'device_id': row['device_id'],
                              'hostname': row.get('hostname')}}, sort_keys=True)
    for row in owners:
        yield json.dumps({'registry': 'source_owners', 'row': {'source_id': row['source_id'],
                          'device_id': row['device_id']}}, sort_keys=True)


def import_records(lines, meta):
    """Validate an export for recovery: identities must reproduce exactly.
    Returns (project_id, records, registry)."""
    records, header, registry = [], None, {'devices': [], 'source_owners': {}}
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except ValueError as exc:
            raise ReportError(f'export line {number} is not JSON') from exc
        if header is None:
            if item.get('schema') != EXPORT_SCHEMA:
                raise ReportError(f'unsupported export schema {item.get("schema")!r}; expected {EXPORT_SCHEMA}')
            if meta and item.get('project_id') not in (None, meta.get('project_id')):
                raise ReportError('export belongs to a different usage project; refusing to merge identities')
            header = item
            continue
        if 'registry' in item:
            row = item.get('row') or {}
            if item['registry'] == 'devices' and isinstance(row.get('device_id'), str):
                registry['devices'].append(row)
            elif item['registry'] == 'source_owners' and isinstance(row.get('source_id'), str) \
                    and isinstance(row.get('device_id'), str):
                if registry['source_owners'].get(row['source_id'], row['device_id']) != row['device_id']:
                    raise ReportError(f'export line {number} lists competing owners for one source')
                registry['source_owners'][row['source_id']] = row['device_id']
            else:
                raise ReportError(f'export line {number} is an unsupported registry row')
            continue
        try:
            identity, content, _ = fact(item['table'], item['fact'])
        except (KeyError, TypeError, StoreError) as exc:
            raise ReportError(f'export line {number} is not a supported fact: {exc}') from exc
        if identity != item.get('fact_id') or content != item.get('content_hash'):
            raise ReportError(f'export line {number} identity does not reproduce; the export is altered or unsupported')
        records.append((item['table'], item['fact']))
    if header is None:
        raise ReportError('empty export')
    return header.get('project_id'), records, registry
