"""Host-side supervised usage collection: segments, attribution, lifecycle, usage.

Only the supervisor (nogg on the host) calls this; agent-invoked hooks never
do, so restricted agents gain no store, spool or source authority.

A pass re-parses each exact source from its start with fresh adapters, so
adapter state (Codex turn context, Claude revision ordinals) is deterministic
regardless of earlier passes. Segments are assigned by event completion time,
never by which pass saw the event, so replays reproduce identical facts.
Facts absent from the local per-source ledger are spooled (fsync) before
being acknowledged; a bounded drain then imports spooled batches. An outage
leaves batches pending; a genuine identity conflict is quarantined with its
evidence instead of blocking later batches.
"""
from contextlib import contextmanager
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import time
import uuid

from token_usage_store import Store, StoreError, StoreUnavailable, fact  # noqa: F401 (Store re-exported)
from token_usage_adapters import ClaudeAdapter, CodexAdapter
import token_usage_antigravity as agy

VOCABULARY_VERSION = '1'
SEGMENT_NAMESPACE = uuid.UUID('6f1b8d2e-6a43-4c55-9a51-7d1c0c7b3e10')
ATTRIBUTION_KEYS = ('task_id', 'bead_id', 'change_id', 'planning_id', 'role', 'complexity',
                    'complexity_source', 'vocabulary_version', 'requested_model', 'model_source',
                    'configured_effort', 'selection_version', 'selection_hash')


def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        stamp = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None
    return stamp if stamp.tzinfo else stamp.replace(tzinfo=dt.timezone.utc)


def iso(stamp):
    return stamp.astimezone(dt.timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')


def canonical_time(value):
    stamp = parse_time(value)
    return iso(stamp) if stamp else None


def segment_id(rec):
    """Launch-recorded segment UUID; legacy records derive a stable one."""
    if rec.get('usage_segment_id'):
        return rec['usage_segment_id']
    return str(uuid.uuid5(SEGMENT_NAMESPACE, f"{rec.get('name')}|{rec.get('started_at')}"))


def segment_start(rec):
    """Sub-second launch time when recorded; legacy records use started_at."""
    return rec.get('usage_started_at') or rec.get('started_at')


def exit_observed(rec):
    """Whether the exit time was observed, from durable record fields only."""
    reason = str(rec.get('exit_reason') or '')
    if 'usage_end_boot_id' in rec or reason.startswith(('launch failed', 'agent startup failed')):
        return True
    return 'vanished' not in reason and rec.get('state') != 'failed' and bool(rec.get('ended_at'))


def assign_segment(timestamp, segments):
    """Latest segment started at or before the event; None when unprovable."""
    stamp, owner, latest = parse_time(timestamp), None, None
    if stamp is None:
        return None
    for seg, started in segments:
        start = parse_time(started)
        if start is not None and start <= stamp and (latest is None or start >= latest):
            owner, latest = seg, start
    return owner


def legacy_attribution(rec):
    """Pre-collection records: keep what they recorded, never infer complexity."""
    entry = dict.fromkeys(ATTRIBUTION_KEYS)
    entry.update(at=rec.get('started_at'), bead_id=rec.get('bead_id'), planning_id=rec.get('planning_id'),
                 role=rec.get('role'), complexity='unknown', complexity_source='legacy',
                 vocabulary_version=VOCABULARY_VERSION, requested_model=rec.get('requested_model'),
                 model_source=rec.get('model_source'), configured_effort=rec.get('reasoning_effort'))
    return [entry]


def complete_lines(path):
    """JSON objects from complete lines; a partial final line waits for a later pass."""
    data = Path(path).read_bytes()
    end = data.rfind(b'\n') + 1
    rows, malformed = [], 0
    for line in data[:end].splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            malformed += 1
    return rows, malformed, end < len(data)


def source_facts(source, segments):
    """(facts, diagnostics) for one exact runtime source."""
    runtime, diagnostics = source['runtime'], {}
    if runtime == 'antigravity':
        result = agy.read_conversation(source['id'], root=source.get('root'))
        facts, diagnostics = list(result.records), dict(result.diagnostics)
    elif runtime in ('claude', 'codex'):
        path = source.get('path')
        if not path or not Path(path).is_file():
            return [], {'source_missing': 1}
        adapter = ClaudeAdapter() if runtime == 'claude' else CodexAdapter()
        rows, malformed, partial = complete_lines(path)
        facts = [entry for entry in (adapter.parse_record(row) for row in rows) if entry]
        if malformed:
            diagnostics['malformed_lines'] = malformed
        if partial:
            diagnostics['partial_final_line'] = 1
        for item in adapter.diagnostics:
            kind = item.get('type', 'adapter') if isinstance(item, dict) else 'adapter'
            diagnostics[kind] = diagnostics.get(kind, 0) + 1
    else:
        return [], {'unsupported_runtime': 1}
    out = []
    for table, values in facts:
        values = dict(values, segment_id=assign_segment(values.get('source_timestamp'), segments))
        if values['segment_id'] is None:
            diagnostics['segment_unattributed'] = diagnostics.get('segment_unattributed', 0) + 1
        out.append((table, values))
    return out, diagnostics


class CollectorBusy(RuntimeError):
    """Another host pass holds the collector; retry shortly."""


class Collector:
    BATCH = 50          # facts per spool batch, bounding each store transaction
    MAX_ATTEMPTS = 3    # repeated data-specific failures before quarantine

    def __init__(self, store, root=None):
        self.store = store
        self.root = Path(root or store.root) / 'collector'

    def _dir(self, *parts):
        path = self.root.joinpath(*parts)
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        return path

    @contextmanager
    def locked(self, timeout):
        self._dir()
        fd = os.open(self.root / 'pass.lock', os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(fd, 'w') as lock:
            deadline = time.monotonic() + max(timeout, 0)
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise CollectorBusy('another usage collection pass is running; retry shortly')
                    time.sleep(0.1)
            old = os.umask(0o077)
            try:
                yield
            finally:
                os.umask(old)

    @staticmethod
    def _write(path, value):
        temp = path.with_name(f'.{path.name}.{os.getpid()}.tmp')
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    @staticmethod
    def _read(path, default):
        """Missing or corrupt local state reads as default: a lost ledger only
        re-spools facts (an exact replay), never drops them."""
        try:
            value = json.loads(path.read_text())
        except (FileNotFoundError, ValueError):
            return default
        return value if default is None or isinstance(value, type(default)) else default

    def device_id(self):
        """Local device identity, created without needing the database."""
        root = Path(self.store.root)
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = root / 'device-id'
        try:
            with path.open('x') as output:
                output.write(str(uuid.uuid4()) + '\n')
                output.flush()
                os.fsync(output.fileno())
        except FileExistsError:
            pass
        return str(uuid.UUID(path.read_text().strip()))

    def segment_state(self, seg):
        return self._read(self._dir('segments') / f'{seg}.json', {})

    def save_segment_state(self, seg, state):
        self._write(self._dir('segments') / f'{seg}.json', state)

    def session_facts(self, rec, live, now, device, evidence=()):
        """Segment, attribution and lifecycle facts for one supervised launch.

        An exit is recorded only for a terminal record; an active record that
        is not live is left to reap/stop, so a transient tmux failure or a
        concurrent stop never fixes a wrong exit."""
        seg = segment_id(rec)
        source = f'nogg-session:{seg}'
        started = canonical_time(segment_start(rec))
        base = {'source_id': source, 'revision': 'v1', 'source_ordinal': 0}
        facts = [('session_segments', dict(base, event_id='segment', source_timestamp=started,
                  runtime=rec.get('agent') or 'claude', supervised_id=rec.get('name'),
                  parent_id=rec.get('parent_session'), device_id=device)),
                 ('lifecycle_events', dict(base, event_id='start', source_timestamp=started,
                  segment_id=seg, kind='start', monotonic_ms=rec.get('usage_monotonic_start_ms')))]
        for index, entry in enumerate(rec.get('usage_attribution') or legacy_attribution(rec)):
            values = {key: entry.get(key) for key in ATTRIBUTION_KEYS}
            values['complexity'] = values['complexity'] or 'unknown'
            facts.append(('attribution_events', {**base, **values, 'event_id': f'boundary:{index}',
                          'source_timestamp': canonical_time(entry.get('at')), 'segment_id': seg}))
        state = self.segment_state(seg)
        if live:
            state['last_seen_at'] = iso(now)
            facts.append(('lifecycle_events', {'source_id': source, 'event_id': 'liveness',
                          'revision': state['last_seen_at'], 'source_ordinal': int(now.timestamp() * 1000),
                          'source_timestamp': state['last_seen_at'], 'segment_id': seg,
                          'kind': 'heartbeat', 'monotonic_ms': None}))
        elif rec.get('state') in ('stopped', 'failed', 'retired'):
            if 'exit' not in state:
                if exit_observed(rec) and rec.get('ended_at'):
                    same_boot = rec.get('usage_end_boot_id') == rec.get('usage_boot_id')
                    state['exit'] = {'kind': 'exit', 'at': canonical_time(rec['ended_at']),
                                     'monotonic_ms': rec.get('usage_monotonic_end_ms') if same_boot else None}
                else:
                    # Unobserved crash: bound by last liveness evidence, never collection time.
                    seen = [parse_time(v) for v in (segment_start(rec), state.get('last_seen_at'),
                            rec.get('antigravity_ready_at'), rec.get('kickoff_sent_at'), *evidence)]
                    bound = max([e for e in seen if e], default=None)
                    state['exit'] = {'kind': 'exit_unobserved', 'at': iso(bound) if bound else None,
                                     'monotonic_ms': None}
            facts.append(('lifecycle_events', dict(base, event_id='exit', source_timestamp=state['exit']['at'],
                          segment_id=seg, kind=state['exit']['kind'],
                          monotonic_ms=state['exit']['monotonic_ms'])))
        return seg, source, facts, state

    def persist(self, facts, owners, diagnostics):
        """Spool facts not yet acknowledged; return how many were new. An
        individually invalid fact is quarantined instead of aborting the pass."""
        ledgers, fresh, invalid = {}, [], []
        for table, values in facts:
            try:
                identity, content, _ = fact(table, values)
            except StoreError as exc:
                invalid.append({'record': [table, values], 'error': str(exc)})
                continue
            source = values['source_id']
            if source not in ledgers:
                path = self._dir('ledger') / (hashlib.sha256(source.encode()).hexdigest() + '.json')
                ledgers[source] = (path, self._read(path, {}))
            if ledgers[source][1].get(identity) != content:
                fresh.append((table, values, source, identity, content))
        if invalid:
            diagnostics['invalid_fact'] = len(invalid)
            self._write(self._dir('quarantine') / f'{time.time_ns():020d}-{uuid.uuid4().hex}.json',
                        {'rejected': invalid})
        for start in range(0, len(fresh), self.BATCH):
            chunk = fresh[start:start + self.BATCH]
            batch = self._dir('spool') / f'{time.time_ns():020d}-{uuid.uuid4().hex}.json'
            self._write(batch, {'records': [[t, v] for t, v, *_ in chunk],
                                'owners': {s: owners[s] for _, _, s, *_ in chunk if s in owners}})
            # Acknowledge only after the spool write is durable.
            for _, _, source, identity, content in chunk:
                ledgers[source][1][identity] = content
            for path, ledger in ledgers.values():
                self._write(path, ledger)
        return len(fresh)

    def _quarantine(self, batch, rejected):
        self._write(self._dir('quarantine') / batch.name, {'rejected': rejected})

    def drain(self, budget_seconds):
        """Import spooled batches until the budget ends. An outage stops the
        drain with batches retained; a conflict is quarantined; a batch that
        keeps failing while Dolt otherwise works is quarantined after
        MAX_ATTEMPTS so it cannot block later batches forever."""
        deadline = time.monotonic() + budget_seconds
        imported, error = 0, None
        batches = sorted(self._dir('spool').glob('*.json'))
        if not batches or budget_seconds <= 0:
            return 0, None
        try:
            self.store.initialize()
            self.store.device()
        except StoreError as exc:
            return 0, f'usage store unavailable: {exc}'
        attempts_path = self.root / 'attempts.json'
        attempts = self._read(attempts_path, {})
        for batch in batches:
            if time.monotonic() >= deadline:
                break
            data = self._read(batch, None)
            if not isinstance(data, dict) or not isinstance(data.get('records'), list):
                self._quarantine(batch, [{'error': 'unreadable spool batch'}])
                batch.unlink()
                continue
            records = [tuple(r) for r in data['records']]
            owners = data.get('owners') or None
            try:
                imported += self.store.append(records, owners)
            except StoreUnavailable as exc:
                attempts[batch.name] = attempts.get(batch.name, 0) + 1
                if attempts[batch.name] < self.MAX_ATTEMPTS:
                    error = f'usage store unavailable: {exc}'
                    break
                self._quarantine(batch, [{'record': list(r), 'error': f'failed {self.MAX_ATTEMPTS} imports: {exc}'}
                                         for r in records])
            except StoreError:
                rejected = []
                for index, record in enumerate(records):
                    if time.monotonic() >= deadline:
                        # Keep the unprocessed remainder pending for the next pass.
                        self._write(batch, {'records': [list(r) for r in records[index:]], 'owners': owners or {}})
                        if rejected:
                            self._quarantine(batch.with_name('partial-' + batch.name), rejected)
                        self._write(attempts_path, attempts)
                        return imported, error
                    try:
                        imported += self.store.append([record], owners)
                    except StoreUnavailable as exc:
                        self._write(batch, {'records': [list(r) for r in records[index:]], 'owners': owners or {}})
                        if rejected:
                            self._quarantine(batch.with_name('partial-' + batch.name), rejected)
                        self._write(attempts_path, attempts)
                        return imported, f'usage store unavailable: {exc}'
                    except StoreError as exc:
                        rejected.append({'record': list(record), 'error': str(exc)})
                if rejected:
                    self._quarantine(batch, rejected)
            attempts.pop(batch.name, None)
            batch.unlink()
        self._write(attempts_path, attempts)
        return imported, error

    def pending(self):
        return {'spooled_batches': len(list(self._dir('spool').glob('*.json'))),
                'quarantined_batches': len(list(self._dir('quarantine').glob('*.json')))}

    def collect(self, targets, budget_seconds=20.0, now=None, lock_timeout=5.0):
        """targets: [{'record', 'live', 'source', 'segments'}]. A bad source or
        fact only affects its own target. Raises only when evidence could not
        be made durable (spool, ledger or segment-state writes) or the
        collector is busy, so cleanup can refuse instead of losing evidence."""
        now = now or dt.datetime.now(dt.timezone.utc)
        with self.locked(lock_timeout):
            device = self.device_id()
            report = {'sessions': {}, 'spooled': 0}
            for target in targets:
                rec = target['record']
                usage, diagnostics = [], {}
                if target.get('source'):
                    try:
                        usage, diagnostics = source_facts(target['source'], target.get('segments') or [])
                    except Exception as exc:  # one unreadable source never blocks others
                        diagnostics = {'source_error': 1, 'source_error_type': exc.__class__.__name__}
                else:
                    diagnostics = {'no_exact_source': 1}
                evidence = [values.get('source_timestamp') for _, values in usage]
                seg, session_source, facts, state = self.session_facts(rec, target['live'], now, device, evidence)
                # Liveness state first: a crash after this only makes a later
                # exit bound later (still observed evidence), never earlier.
                self.save_segment_state(seg, state)
                owners = {session_source: device}
                owners.update({values['source_id']: device for _, values in usage})
                report['spooled'] += self.persist(facts + usage, owners, diagnostics)
                if target['record'].get('state') in ('starting', 'running', 'idle') and not target['live']:
                    diagnostics['liveness_unconfirmed'] = 1
                report['sessions'][rec.get('name')] = {'segment_id': seg, 'diagnostics': diagnostics}
            imported, error = self.drain(budget_seconds)
            status = self._read(self.root / 'status.json', {})
            status.update(self.pending(), last_collection_at=iso(now), last_error=error,
                          sessions={**status.get('sessions', {}), **report['sessions']})
            if error is None:
                status['last_success_at'] = iso(now)
            self._write(self.root / 'status.json', status)
            report.update(imported=imported, error=error, **self.pending())
            return report
