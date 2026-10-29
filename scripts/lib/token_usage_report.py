"""Consumption reports over the local usage store (no prices, no quota percent).

Pure functions over loaded current facts, so windows, buckets, filters,
coarse attribution and runtime clipping are testable without Dolt. All
windows are half-open UTC [from, to); hour/day buckets are UTC. The one
side effect, the git attribution of the per-Bead view (bead_git_lines), is
injected by the caller as context['bead_lines'] so report() stays pure.
"""
import datetime as dt
import json
from pathlib import Path
import re
import subprocess

# StoreTimeout/StoreUnavailable are re-exported for nogg's bounded readers.
from token_usage_store import FIELDS, JSON_FIELDS, StoreError, StoreTimeout, StoreUnavailable, fact  # noqa: F401

REPORT_SCHEMA = 'nogg.token-usage.report/v1'
SESSION_SCHEMA = 'nogg.token-usage.session/v1'
STATUS_SCHEMA = 'nogg.token-usage.status/v1'
EXPORT_SCHEMA = 'nogg.token-usage.export/v1'
TOKEN_COUNTERS = ('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens',
                  'thinking_tokens', 'provider_total_tokens')
COMPLEXITIES = ('routine', 'standard', 'complex', 'unknown')
RUNTIMES = ('claude', 'codex', 'antigravity', 'pi')
FILTERS = ('project', 'device', 'runtime', 'provider', 'model', 'task', 'bead', 'complexity', 'effort')
GROUPS = ('hour', 'day', 'session', 'bead')
NOTES = ['token sums are known source-reported consumption, not billed cost or quota percentage',
         'known sums are complete only where coverage reports no unknown or unsupported sources']
BEAD_NOTES = ['fresh input is input not served from the prompt cache (input minus cache read); with output '
              'it is the cost of the work, while cache reads grow with waiting and context size',
              'production lines count added+deleted lines, tests and generated files excluded, of every '
              'non-merge commit whose subject carries the [<bead-id>] token, regardless of the window; '
              'widen --from/--to to cover the whole Bead']
# Every adapter stores input inclusive of cache reads and flags it: Claude sums
# uncached input + cache read + cache write, Codex reports cached input inside
# input, Antigravity adds cache read to its cache-exclusive input.
INCLUSIVE_INPUT = frozenset(('cache_summed_input', 'cache_inclusive_input', 'input_includes_cache_read'))
WORK_COUNTERS = ('fresh_input_tokens', 'cache_read_tokens', 'cache_write_tokens', 'output_tokens', 'total_tokens')
PER_LINE = ('fresh_input_tokens', 'output_tokens', 'total_tokens')
# Any bracketed subject token; only the attributed Bead IDs themselves count,
# whatever their prefix case (`[SPEC-1cu]`, `[loadcompass-wum2]`).
BEAD_TOKEN_RE = re.compile(r'\[([^\[\]\s]+)\]')
TEST_PATH_RE = re.compile(r'(^|/)(tests?|__tests__|fixtures|testdata)/|\.(test|spec)\.[^/]+$|_test\.(py|go)$'
                          r'|(^|/)test_[^/]*\.py$')
GENERATED_PATH_RE = re.compile(r'(^|/)(openspec|\.beads)/|(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock'
                               r'|pnpm-lock\.yaml|bun\.lockb?|Cargo\.lock|poetry\.lock|uv\.lock|Pipfile\.lock'
                               r'|Gemfile\.lock|composer\.lock|go\.sum)$')


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


def load_meta(store, timeout=None):
    """Store metadata, or None when no store exists (no fact scan)."""
    if not (store.database / '.dolt').exists():
        return None
    return store.check_schema(timeout=timeout)


def load_facts(store, timeout=None):
    """Current (latest-revision) facts by table; empty when no store exists.

    One base-table scan per table, the latest revision selected in Python
    (Store.current): the current_<table> views are quadratic in Dolt. Each
    Dolt call is bounded by `timeout` seconds (StoreTimeout past it)."""
    meta = load_meta(store, timeout)
    if meta is None:
        return None, {t: [] for t in FIELDS}
    facts = {}
    for table in FIELDS:
        rows = store.current(table, timeout=timeout)
        facts[table] = [dict(decode_row(table, r), fact_id=r['fact_id'], content_hash=r['content_hash'])
                        for r in rows]
    return meta, facts


def load_counts(store, timeout=None):
    """(meta, current fact count per table) without loading fact payloads."""
    meta = load_meta(store, timeout)
    if meta is None:
        return None, {t: 0 for t in FIELDS}
    return meta, store.current_counts(timeout=timeout)


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
    if key == 'bead':
        return (boundary or {}).get('bead_id')
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


def fresh_input(usage):
    """Input tokens not served from the prompt cache, or None when unprovable.

    Stored input includes cache reads for every adapter (INCLUSIVE_INPUT), so
    fresh input is input minus cache read: for Claude that is uncached input
    plus cache-creation (cache write) tokens, for Codex input minus cached
    input, for Antigravity its cache-exclusive input. A source without an
    inclusive flag is fresh only when it reports no cache read at all."""
    total, cached = usage.get('input_tokens'), usage.get('cache_read_tokens')
    if total is None or cached is None:
        return None
    if cached == 0:
        return total
    if INCLUSIVE_INPUT & set(usage.get('semantics') or ()) and cached <= total:
        return total - cached
    return None


def empty_work():
    return {'tokens': {c: 0 for c in WORK_COUNTERS}, 'unknown_counters': {c: 0 for c in WORK_COUNTERS}}


def add_work(work, usage):
    """Accumulate the per-Bead work counters; unprovable values stay unknown."""
    inp, out = usage.get('input_tokens'), usage.get('output_tokens')
    values = {'fresh_input_tokens': fresh_input(usage), 'cache_read_tokens': usage.get('cache_read_tokens'),
              'cache_write_tokens': usage.get('cache_write_tokens'), 'output_tokens': out,
              'total_tokens': None if inp is None or out is None else inp + out}
    for key, value in values.items():
        if value is None:
            work['unknown_counters'][key] += 1
        else:
            work['tokens'][key] += value


def classify_path(path):
    """'test', 'generated' (planning, tracker export, lockfile) or 'production'."""
    if GENERATED_PATH_RE.search(path):
        return 'generated'
    if TEST_PATH_RE.search(path):
        return 'test'
    return 'production'


def numstat_path(path):
    """The post-change path of a `git --numstat` entry (renames resolved)."""
    path = re.sub(r'\{([^{}]*) => ([^{}]*)\}', lambda m: m.group(2), path)
    path = path.split(' => ', 1)[-1]
    return re.sub(r'//+', '/', path)


def bead_git_lines(repo, beads, timeout=30, run=subprocess.run):
    """{bead: {commits, production_lines, test_lines}} from the commits whose
    subject carries `[<bead>]`, or None when git cannot answer.

    Commits come from every local and remote-tracking branch and tag (not
    stash, notes or Beads' refs/dolt/*), merges excluded; a rebased or
    cherry-picked copy (same author time and subject) counts once, and a
    commit naming several Beads counts for each. Lines are numstat added +
    deleted per file, classified by classify_path; binary files count 0."""
    beads = {b for b in beads if b}
    out = {b: {'commits': 0, 'production_lines': 0, 'test_lines': 0} for b in beads}
    if not beads:
        return out
    def git(*args, stdin=None):
        try:
            result = run(['git', '-C', str(repo), '-c', 'core.quotePath=false', *args], input=stdin,
                         capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.SubprocessError):
            return None
        return result.stdout if result.returncode == 0 else None
    log = git('log', '--branches', '--remotes', '--tags', '--no-merges', '--format=%H%x1f%at%x1f%s')
    if log is None:
        return None
    wanted, seen = {}, set()
    for line in log.splitlines():
        sha, _, rest = line.partition('\x1f')
        stamp, _, subject = rest.partition('\x1f')
        tokens = [t for t in dict.fromkeys(BEAD_TOKEN_RE.findall(subject)) if t in beads]
        if tokens and (stamp, subject) not in seen:
            seen.add((stamp, subject))
            wanted[sha] = tokens
    if not wanted:
        return out
    stat = git('log', '--no-walk=unsorted', '--stdin', '-M', '--numstat', '--format=%x1e%H',
               stdin='\n'.join(wanted) + '\n')
    if stat is None:
        return None
    for chunk in stat.split('\x1e')[1:]:
        lines = chunk.splitlines()
        tokens = wanted.get(lines[0].strip() if lines else None, [])
        counts = {'production': 0, 'test': 0, 'generated': 0}
        for entry in lines[1:]:
            parts = entry.split('\t', 2)
            if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
                counts[classify_path(numstat_path(parts[2]))] += int(parts[0]) + int(parts[1])
        for token in tokens:
            out[token]['commits'] += 1
            out[token]['production_lines'] += counts['production']
            out[token]['test_lines'] += counts['test']
    return out


def per_line(item, lines):
    """Known tokens per production line (one decimal); None without production
    lines or without any usage event (runtime alone is no token evidence)."""
    return {k: (round(item['work']['tokens'][k] / lines, 1) if lines and item['events'] else None)
            for k in PER_LINE}


def attach_git(item, bead, lines):
    """Stable git fields: null when git is unavailable or the Bead has no commits."""
    found = (lines or {}).get(bead) if bead else None
    commits = found['commits'] if found is not None else None
    item['commits'] = commits
    item['production_lines'] = found['production_lines'] if commits else None
    item['test_lines'] = found['test_lines'] if commits else None
    item['per_production_line'] = per_line(item, item['production_lines'])


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
    if group_by not in GROUPS:
        raise ReportError('--group-by must be hour, day, session or bead')
    model = Model(facts)
    project = (meta or {}).get('project_id')
    project_match = 'project' not in filters or filters['project'] == project
    rows, coarse = {}, []
    coverage = {'events_in_window': 0, 'untimed_events': 0, 'unknown_model': 0, 'unknown_task': 0,
                'unknown_bead': 0, 'unknown_complexity': 0, 'unattributed_segment': 0, 'completeness': {}}

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
            elif group_by == 'bead':
                rows[key].update(bead=key[0], runtime=key[1], sessions=set(), work=empty_work())
            else:
                rows[key].update(bucket=iso(key), bucket_end=iso(key + bucket_span(group_by)))
        return rows[key]

    def bead_key(boundary, runtime):
        return (boundary or {}).get('bead_id'), runtime

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
        coverage['unknown_bead'] += (boundary or {}).get('bead_id') is None
        coverage['unknown_complexity'] += dimension(model, usage, boundary, 'complexity') == 'unknown'
        coverage['unattributed_segment'] += usage.get('segment_id') is None
        state = usage.get('completeness') or 'unknown'
        coverage['completeness'][state] = coverage['completeness'].get(state, 0) + 1
        observed_from = coarse_interval(usage)
        if group_by in ('hour', 'day') and observed_from is not None and \
                bucket_start(observed_from, group_by) != bucket_start(stamp, group_by):
            # Never invent a split of cumulative-only consumption across buckets.
            entry = dict(empty_metrics(), interval_from=iso(observed_from), interval_to=iso(stamp),
                         quality='coarse', model=usage.get('model'), segment_id=usage.get('segment_id'))
            add_usage(entry, usage)
            coarse.append(entry)
            continue
        if group_by == 'session':
            key = model.session_key(usage.get('segment_id'))
        elif group_by == 'bead':
            key = bead_key(boundary, usage.get('runtime'))
        else:
            key = bucket_start(stamp, group_by)
        row = row_for(key, usage.get('segment_id'))
        add_usage(row, usage)
        if group_by == 'bead':
            add_work(row['work'], usage)
            if usage.get('segment_id') in model.segments:
                row['sessions'].add(model.session_key(usage['segment_id']))
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
                if group_by in ('session', 'bead'):
                    piece = overlap(lo, hi, start, end)
                    if piece:
                        if group_by == 'bead':
                            row = row_for(bead_key(boundary, pseudo['runtime']))
                            row['sessions'].add(model.session_key(segment))
                        else:
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
    def order(key):
        if group_by == 'bead':   # Beads by ID, the unattributed group last
            return (key[0] is None, key[0] or '', key[1] or '')
        return str(key)
    ordered = []
    for key in sorted(rows, key=order):
        row = rows[key]
        row['runtime_quality'] = sorted(row['runtime_quality'])
        if runtime_note:
            row['wall_runtime_ms'] = None
        if group_by == 'bead':
            row['sessions'] = sorted(row['sessions'])
        ordered.append(row)
    context = context or {}
    notes = list(NOTES) + ([runtime_note] if runtime_note else [])
    if not project_match:
        notes.append(f'this store belongs to project {project}; no facts match --project')
    doc = {'schema': REPORT_SCHEMA, 'as_of': iso(now), 'project_id': project,
           'window': {'from': iso(start), 'to': iso(end), 'half_open': True, 'timezone': 'UTC'},
           'group_by': group_by, 'filters': filters, 'rows': ordered, 'coarse': coarse,
           'coverage': dict(coverage, sources=context.get('sources', {})),
           'pending': context.get('pending', {}), 'sync': context.get('sync', {'state': 'not_configured',
                                                                                   'local_only': True}),
           'store': context.get('store', 'present' if meta else 'absent'), 'notes': notes}
    if group_by == 'bead':
        bead_view(doc, context.get('bead_lines'))
    return doc


def bead_view(doc, bead_lines):
    """Attach git attribution and per-Bead totals (all runtimes) to a bead report.

    bead_lines(beads) -> {bead: {commits, production_lines, test_lines}} or None;
    without it (or when it returns None) every git field is null."""
    beads = sorted({r['bead'] for r in doc['rows'] if r['bead']})
    lines = bead_lines(beads) if callable(bead_lines) and beads else None
    totals = {}
    for row in doc['rows']:
        attach_git(row, row['bead'], lines)
        total = totals.setdefault(row['bead'], {'bead': row['bead'], 'runtimes': [], 'sessions': set(),
                                                'events': 0, 'wall_runtime_ms': 0, 'work': empty_work()})
        total['runtimes'].append(row['runtime'])
        total['sessions'].update(row['sessions'])
        total['events'] += row['events']
        total['wall_runtime_ms'] = (None if total['wall_runtime_ms'] is None or row['wall_runtime_ms'] is None
                                    else total['wall_runtime_ms'] + row['wall_runtime_ms'])
        for part in ('tokens', 'unknown_counters'):
            for key, value in row['work'][part].items():
                total['work'][part][key] += value
    for total in totals.values():
        total['sessions'] = sorted(total['sessions'])
        attach_git(total, total['bead'], lines)
    doc['beads'] = list(totals.values())
    doc['git'] = {'available': lines is not None or not beads,
                  'source': 'commit subjects carrying [<bead-id>] on all branches and tags'}
    doc['notes'] = doc['notes'] + BEAD_NOTES + (
        [] if doc['git']['available'] else ['git attribution unavailable; production-line fields are null'])


def render_bead_report(doc):
    """Text rows of a bead report: one line per Bead and runtime, plus a total
    line for a Bead worked by several runtimes. '-' marks a null field."""
    def cell(work, key):
        return f"{work['tokens'][key]}" + ('+?' if work['unknown_counters'][key] else '')
    def num(value):
        return '-' if value is None else f'{value:.1f}' if isinstance(value, float) else str(value)
    width = max([4] + [len(r['bead'] or '-') for r in doc['rows']])
    head = (f"{'BEAD':<{width}}  {'AGENT':<11}  {'EVENTS':>6}  {'FRESH_IN':>11}  {'CACHE_READ':>12}  {'CACHE_WRITE':>11}  "
            f"{'OUTPUT':>9}  {'TOTAL':>12}  {'COMMITS':>7}  {'PROD_LINES':>10}  {'FRESH/LINE':>10}  "
            f"{'OUT/LINE':>8}  {'TOTAL/LINE':>10}")
    lines = [head]
    def line(bead, agent, item):
        w, p = item['work'], item['per_production_line']
        return (f"{bead or '-':<{width}}  {agent[:11]:<11}  {item['events']:>6}  "
                f"{cell(w, 'fresh_input_tokens'):>11}  {cell(w, 'cache_read_tokens'):>12}  "
                f"{cell(w, 'cache_write_tokens'):>11}  {cell(w, 'output_tokens'):>9}  {cell(w, 'total_tokens'):>12}  "
                f"{num(item['commits']):>7}  {num(item['production_lines']):>10}  "
                f"{num(p['fresh_input_tokens']):>10}  {num(p['output_tokens']):>8}  {num(p['total_tokens']):>10}")
    totals = {t['bead']: t for t in doc.get('beads', [])}
    for index, row in enumerate(doc['rows']):
        lines.append(line(row['bead'], row['runtime'] or '-', row))
        following = doc['rows'][index + 1]['bead'] if index + 1 < len(doc['rows']) else object()
        total = totals.get(row['bead'])
        if total and len(total['runtimes']) > 1 and following != row['bead']:
            lines.append(line(row['bead'], 'all', total))
    return lines


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
