"""Private, local Dolt usage storage. No transcript fields or remote operations.

Callers supply canonical_repository_state from nogg; source adapters supply
stable runtime identities and source ordinals, never importer time or paths.
All writers (including future sync) must hold Store.locked().
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import uuid

SCHEMA_VERSION = 1
IDENTITY_VERSION = 1
COUNTERS = ('input_tokens', 'output_tokens', 'cache_read_tokens',
            'cache_write_tokens', 'thinking_tokens', 'provider_total_tokens',
            'inference_duration_ms')
COMMON = {'source_id', 'event_id', 'revision', 'source_ordinal', 'source_timestamp'}
FIELDS = {
    'session_segments': COMMON | {'runtime', 'supervised_id', 'parent_id', 'device_id'},
    'lifecycle_events': COMMON | {'segment_id', 'kind', 'monotonic_ms'},
    'attribution_events': COMMON | {'segment_id', 'task_id', 'bead_id', 'change_id',
        'planning_id', 'role', 'complexity', 'complexity_source', 'vocabulary_version',
        'requested_model', 'model_source', 'configured_effort', 'selection_version', 'selection_hash'},
    'usage_events': COMMON | set(COUNTERS) | {'segment_id', 'runtime', 'provider',
        'model', 'effort', 'source_schema', 'completeness', 'semantics', 'raw_usage'},
}
NUMBERS = set(COUNTERS) | {'source_ordinal', 'monotonic_ms'}
LOOKUP_CHUNK = 100
JSON_FIELDS = {'raw_usage', 'semantics'}


class StoreError(RuntimeError):
    pass


class StoreUnavailable(StoreError):
    """Dolt could not run; retain pending facts and retry (unlike a conflict)."""


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True, allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical_json(value).encode('ascii')).hexdigest()


def fact(table, values):
    """Validate an allowlisted fact and produce device/path-independent identity."""
    if table not in FIELDS or not isinstance(values, dict):
        raise StoreError('unsupported fact table or payload')
    if set(values) - FIELDS[table]:
        raise StoreError('unsupported fact fields')
    data = {key: values.get(key) for key in sorted(FIELDS[table])}
    for key in ('source_id', 'event_id', 'revision'):
        if not isinstance(data[key], str) or not data[key]:
            raise StoreError('source, event and revision identities must be nonempty strings')
    for key, value in data.items():
        if value is None:
            continue
        if key in NUMBERS:
            if type(value) is not int or value < 0 or value > 9223372036854775807:
                raise StoreError('counters and ordinals must be nonnegative signed 64-bit integers')
        elif key == 'raw_usage':
            if not isinstance(value, dict) or any(k not in COUNTERS or
                    type(v) is not int or v < 0 or v > 9223372036854775807 for k, v in value.items()):
                raise StoreError('raw_usage accepts only allowlisted numeric counters')
        elif key == 'semantics':
            if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
                raise StoreError('semantics must be a list of flags')
        elif not isinstance(value, str) or len(value) > 512:
            raise StoreError('fact dimensions must be strings of at most 512 characters')
    if data['source_ordinal'] is None:
        raise StoreError('source_ordinal is required; importer time cannot order revisions')
    if 'complexity' in data and data['complexity'] not in (None, 'unknown', 'routine', 'standard', 'complex'):
        raise StoreError('unsupported complexity')
    identity = digest([IDENTITY_VERSION, table, data['source_id'], data['event_id'], data['revision']])
    return identity, digest([IDENTITY_VERSION, table, data]), data


def literal(value):
    if value is None:
        return 'NULL'
    if type(value) is int:
        return str(value)
    # Hex conversion avoids SQL modes, quote escaping and SQL injection.
    return "CONVERT(X'%s' USING utf8mb4)" % str(value).encode('utf-8').hex()


class Store:
    def __init__(self, checkout, resolve_repository):
        self.root = Path(resolve_repository(checkout)['state_dir']) / 'token-usage'
        self.database = self.root / 'database'

    @contextmanager
    def locked(self):
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        fd = os.open(self.root / 'collector.lock', os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(fd, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            old = os.umask(0o077)
            try:
                yield
            finally:
                os.umask(old)

    def _dolt(self, *args, sql=None):
        try:
            result = subprocess.run(['dolt', *args], cwd=self.database, input=sql,
                                    text=True, capture_output=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise StoreUnavailable('local Dolt could not run; usage evidence must remain pending') from exc
        if result.returncode:
            # Do not echo SQL payloads or possible credential-bearing diagnostics.
            raise StoreUnavailable('local Dolt operation failed; usage evidence must remain pending')
        return result.stdout

    def query(self, sql):
        return json.loads(self._dolt('sql', '-r', 'json', '-q', sql)).get('rows', [])

    def check_schema(self):
        rows = self.query('SELECT * FROM store_meta')
        if len(rows) != 1 or rows[0]['schema_version'] != SCHEMA_VERSION or rows[0]['identity_version'] != IDENTITY_VERSION:
            raise StoreError('unsupported usage schema/identity version; owner-controlled migration required')
        try:
            uuid.UUID(rows[0]['project_id'])
        except (ValueError, KeyError) as exc:
            raise StoreError('invalid usage project identity') from exc
        return rows[0]

    def initialize(self, project_id=None):
        """Create the store lazily. project_id adopts an existing project
        identity (export recovery); otherwise a new UUID is generated."""
        if project_id is not None:
            try:
                project_id = str(uuid.UUID(project_id))
            except (TypeError, ValueError) as exc:
                raise StoreError('invalid usage project identity') from exc
        with self.locked():
            if (self.database / '.dolt').exists():
                return self.check_schema()
            if self.database.exists() and any(self.database.iterdir()):
                raise StoreError('unrecognized usage database; preserve it for recovery')
            self.database.mkdir(mode=0o700, exist_ok=True)
            self._dolt('init', '--name', 'Nogging Usage', '--email', 'usage@nogging.local')
            statements = [
                'CREATE TABLE store_meta (singleton INT PRIMARY KEY, schema_version INT NOT NULL, identity_version INT NOT NULL, project_id VARCHAR(36) NOT NULL)',
                f'INSERT INTO store_meta VALUES (1, {SCHEMA_VERSION}, {IDENTITY_VERSION}, {literal(project_id or str(uuid.uuid4()))})',
                'CREATE TABLE devices (device_id VARCHAR(36) PRIMARY KEY, hostname VARCHAR(512) NOT NULL)',
                'CREATE TABLE source_owners (source_id VARCHAR(512) PRIMARY KEY, device_id VARCHAR(36) NOT NULL)',
            ]
            for table, fields in FIELDS.items():
                columns = ['fact_id VARCHAR(64) PRIMARY KEY', 'content_hash VARCHAR(64) NOT NULL']
                for key in sorted(fields):
                    typ = 'BIGINT' if key in NUMBERS else 'LONGTEXT' if key in JSON_FIELDS else 'VARCHAR(512)'
                    columns.append(f'`{key}` {typ}')
                columns += ['UNIQUE KEY source_revision (source_id, event_id, revision)',
                            'UNIQUE KEY source_order (source_id, event_id, source_ordinal)',
                            'INDEX source_time (source_timestamp)']
                for key in ('segment_id', 'supervised_id', 'device_id', 'runtime', 'provider', 'model',
                            'task_id', 'bead_id', 'change_id', 'complexity', 'effort'):
                    if key in fields:
                        columns.append(f'INDEX dim_{key} (`{key}`)')
                statements.append(f'CREATE TABLE {table} ({", ".join(columns)})')
                statements.append(f'CREATE VIEW current_{table} AS SELECT a.* FROM {table} a WHERE NOT EXISTS '
                    f'(SELECT 1 FROM {table} b WHERE b.source_id=a.source_id AND b.event_id=a.event_id '
                    'AND b.source_ordinal>a.source_ordinal)')
            self._dolt('sql', sql=';\n'.join(statements) + ';')
            self._commit('Initialize usage schema v1')
            return self.check_schema()

    def _commit(self, message):
        self._dolt('add', '.')
        self._dolt('commit', '--allow-empty', '--author', 'Nogging Usage <usage@nogging.local>', '-m', message)

    def device(self):
        """Local device identity lives outside the cloned database."""
        with self.locked():
            self.check_schema()
            path = self.root / 'device-id'
            if path.exists():
                device_id = str(uuid.UUID(path.read_text().strip()))
            else:
                device_id = str(uuid.uuid4())
                with path.open('x') as output:
                    output.write(device_id + '\n')
                    output.flush()
                    os.fsync(output.fileno())
            rows = self.query(f'SELECT device_id FROM devices WHERE device_id={literal(device_id)}')
            if not rows:
                self._dolt('sql', sql=f'INSERT INTO devices VALUES ({literal(device_id)}, {literal(socket.gethostname())});')
            if self.query('SELECT * FROM dolt_status'):
                self._commit('Register usage device')
            return device_id

    def registry(self):
        """Device and source-ownership rows (not facts) for recovery exports."""
        return {'devices': self.query('SELECT device_id, hostname FROM devices'),
                'source_owners': self.query('SELECT source_id, device_id FROM source_owners')}

    def register_devices(self, rows):
        """Insert recovered device rows; an existing device keeps its row."""
        with self.locked():
            self.check_schema()
            known = {r['device_id'] for r in self.query('SELECT device_id FROM devices')}
            statements = []
            for row in rows:
                device_id = str(uuid.UUID(row['device_id']))
                hostname = row.get('hostname')
                if not isinstance(hostname, str) or len(hostname) > 512:
                    raise StoreError('invalid device hostname')
                if device_id not in known:
                    statements.append(f'INSERT INTO devices VALUES ({literal(device_id)}, {literal(hostname)})')
                    known.add(device_id)
            if statements:
                self._dolt('sql', sql=';\n'.join(statements) + ';')
                self._commit('Register recovered usage devices')
            return len(statements)

    def append(self, records, owners=None):
        """Atomically append a batch; exact replay is a no-op, collisions refuse.

        owners claims source streams for device UUIDs. Copied facts may be replayed
        without claiming a stream; ownership transfer requires an explicit future
        owner-controlled operation, never an implicit importer overwrite.
        """
        prepared = [(table, *fact(table, values)) for table, values in records]
        with self.locked():
            self.check_schema()
            statements = []
            seen = {}
            owners = owners or {}
            for source, device_id in owners.items():
                if not isinstance(source, str) or not source or len(source) > 512:
                    raise StoreError('invalid source identity')
                uuid.UUID(device_id)
            # One query per table (not per fact) keeps large batches bounded.
            existing = {}
            if owners:
                existing = {row['source_id']: row['device_id'] for row in self.query(
                    'SELECT source_id, device_id FROM source_owners WHERE source_id IN (%s)'
                    % ', '.join(literal(source) for source in owners))}
            for source, device_id in owners.items():
                if source in existing and existing[source] != device_id:
                    raise StoreError('source ownership conflict; explicit ownership transfer required')
                if source not in existing:
                    statements.append(f'INSERT INTO source_owners VALUES ({literal(source)}, {literal(device_id)})')
            candidates = {}
            for table, identity, content, data in prepared:
                key = (table, identity)
                order = (table, data['source_id'], data['event_id'], data['source_ordinal'])
                if key in seen:
                    if seen[key] != content:
                        raise StoreError('conflicting fact revision in batch')
                    continue
                if order in seen:
                    raise StoreError('ambiguous source revision ordinal in batch')
                seen[key] = content
                seen[order] = identity
                candidates.setdefault(table, []).append((identity, content, data))
            for table, items in candidates.items():
                rows = []
                # Bounded lookups keep each `dolt sql -q` argument far below ARG_MAX.
                for start in range(0, len(items), LOOKUP_CHUNK):
                    clauses = [f'fact_id={literal(identity)} OR (source_id={literal(data["source_id"])} AND '
                               f'event_id={literal(data["event_id"])} AND source_ordinal={data["source_ordinal"]})'
                               for identity, _, data in items[start:start + LOOKUP_CHUNK]]
                    rows += self.query(f'SELECT fact_id, content_hash, source_id, event_id, source_ordinal FROM {table} '
                                       f'WHERE {" OR ".join(clauses)}')
                for identity, content, data in items:
                    matches = [r for r in rows if r['fact_id'] == identity or (
                        r['source_id'] == data['source_id'] and r['event_id'] == data['event_id']
                        and int(r['source_ordinal']) == data['source_ordinal'])]
                    if matches:
                        if len(matches) != 1 or matches[0]['fact_id'] != identity or matches[0]['content_hash'] != content:
                            raise StoreError('conflicting fact revision or source ordinal; retain evidence for recovery')
                        continue
                    columns = ['fact_id', 'content_hash'] + sorted(data)
                    values = [identity, content] + [canonical_json(data[k]) if k in JSON_FIELDS and data[k] is not None else data[k] for k in sorted(data)]
                    statements.append(f'INSERT INTO {table} ({", ".join("`"+k+"`" for k in columns)}) VALUES ({", ".join(map(literal, values))})')
            if statements:
                # One CLI process/connection; failed transaction never advances a checkpoint.
                self._dolt('sql', sql='SET autocommit=0; START TRANSACTION;\n' + ';\n'.join(statements) + ';\nCOMMIT;')
            # A crash after SQL commit but before Dolt commit leaves a dirty
            # working set. Replay must finish the durable history commit too.
            if self.query('SELECT * FROM dolt_status'):
                self._commit('Append immutable usage facts')
            return len(statements)
