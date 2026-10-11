"""Antigravity exact-conversation usage adapter. Read-only; no inference.

Source: the supervised conversation ID (validated from the Stop hook) names
<root>/conversations/<id>.db. Each gen_metadata row is one model generation,
a CortexStepGeneratorMetadata protobuf whose chat_model (ChatModelMetadata)
carries usage (ModelUsageStats) and the observed response_model. Field
numbers come from the descriptors embedded in agy 1.3.3:

  CortexStepGeneratorMetadata: 1 chat_model, 2 step_indices, 5 error
  ChatModelMetadata: 4 usage, 11 time_to_first_token, 12 streaming_duration,
                     19 response_model, 20 custom_metadata (cascade_id)
  ModelUsageStats: 2 input (excludes cache read), 3 output (thinking +
                   response), 4 cache_write, 5 cache_read, 6 api_provider,
                   9 thinking, 10 response_output, 11 response_id
  CortexStepMetadata (steps.metadata): 7 finished_generating_at

`/usage` command output and account quota are never read here: only the
exact conversation's per-generation usage counts. Prompts, tool text and
other strings are never decoded into facts.
"""
from collections import namedtuple
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
import sqlite3
import uuid

SOURCE_SCHEMA = 'antigravity-conversation-db/gen_metadata-v1'
PROVIDERS = {1: 'internal', 3: 'google-vertex', 24: 'google-gemini',
             26: 'anthropic-vertex', 30: 'google-evergreen', 31: 'openai-vertex'}
SEMANTICS = ['input_includes_cache_read', 'thinking_in_output']

Result = namedtuple('Result', 'records diagnostics high_water generations')


class AntigravitySourceError(RuntimeError):
    pass


def default_root():
    return Path.home() / '.gemini/antigravity-cli'


def _varint(data, i):
    result = shift = 0
    while True:
        if i >= len(data) or shift > 63:
            raise ValueError('truncated varint')
        byte = data[i]
        i += 1
        result |= (byte & 0x7f) << shift
        shift += 7
        if byte < 0x80:
            return result, i


def _message(data):
    """Decode one protobuf message into {field: [varint | bytes]}."""
    fields = {}
    i = 0
    while i < len(data):
        key, i = _varint(data, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = _varint(data, i)
        elif wire == 2:
            size, i = _varint(data, i)
            if i + size > len(data):
                raise ValueError('truncated field')
            value, i = bytes(data[i:i + size]), i + size
        elif wire in (1, 5):
            i += 8 if wire == 1 else 4
            continue
        else:
            raise ValueError('unsupported wire type')
        if number == 0 or i > len(data):
            raise ValueError('invalid field')
        fields.setdefault(number, []).append(value)
    return fields


def _int(fields, number):
    value = fields.get(number, [None])[-1]
    if value is not None and type(value) is not int:
        raise ValueError('expected varint')
    return value


def _sub(fields, number):
    value = fields.get(number, [None])[-1]
    if value is not None and type(value) is not bytes:
        raise ValueError('expected message')
    return _message(value) if value is not None else None


def _seconds(fields):
    """google.protobuf.Duration/Timestamp as (seconds, nanos)."""
    return (_int(fields, 1) or 0), (_int(fields, 2) or 0)


def _indices(fields, number):
    out = []
    for value in fields.get(number, []):
        if type(value) is int:
            out.append(value)
        else:
            i = 0
            while i < len(value):
                item, i = _varint(value, i)
                out.append(item)
    return out


def _metadata(chat_model):
    meta = {}
    for entry in chat_model.get(20, []):
        item = _message(entry)
        key, value = item.get(1, [b''])[-1], item.get(2, [b''])[-1]
        if key in (b'cascade_id', b'root_cascade_id'):
            meta[key.decode()] = value.decode('utf-8', 'replace')
    return meta


def conversation_path(conversation_id, root=None):
    try:
        if str(uuid.UUID(conversation_id)) != conversation_id:
            raise ValueError()
    except (TypeError, ValueError, AttributeError) as exc:
        raise AntigravitySourceError('invalid Antigravity conversation ID') from exc
    path = Path(root or default_root()) / 'conversations' / f'{conversation_id}.db'
    if path.is_symlink() or not path.is_file():
        raise AntigravitySourceError('Antigravity conversation source is missing or not a regular file')
    return path


def _segment(timestamp, segments):
    """Latest segment that started at or before the completion time.

    Deterministic for any collection pass, so a resume never re-attributes
    (and never recharges) generations completed in an earlier segment."""
    def parsed(value):
        try:
            stamp = datetime.fromisoformat(value.replace('Z', '+00:00'))
        except (AttributeError, ValueError):
            return None
        return stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)

    owner, latest, stamp = None, None, parsed(timestamp)
    for segment_id, started in segments or ():
        start = parsed(started)
        if stamp and start and start <= stamp and (latest is None or start >= latest):
            owner, latest = segment_id, start
    return owner


def _iso(seconds, nanos):
    stamp = datetime.fromtimestamp(seconds, timezone.utc).replace(microsecond=nanos // 1000)
    return stamp.isoformat(timespec='microseconds').replace('+00:00', 'Z')


def read_conversation(conversation_id, root=None, after_ordinal=-1, segments=None):
    """Normalize generations after `after_ordinal` into usage_events facts.

    segments: [(segment_id, started_at ISO-8601 UTC 'Z')] for this conversation.
    high_water advances only past terminal rows, so an in-flight generation
    without usage is revisited by the next pass.
    """
    path = conversation_path(conversation_id, root)
    source_id = f'antigravity:{conversation_id}'
    diagnostics = {}
    records = []

    def note(kind):
        diagnostics[kind] = diagnostics.get(kind, 0) + 1

    try:
        db = sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=5)
    except sqlite3.Error as exc:
        raise AntigravitySourceError('Antigravity conversation source could not be opened') from exc
    try:
        db.execute('BEGIN')  # one consistent snapshot of generations and steps
        columns = {table: {row[1] for row in db.execute(f'PRAGMA table_info({table})')}
                   for table in ('gen_metadata', 'steps')}
        if not {'idx', 'data'} <= columns['gen_metadata'] or not {'idx', 'metadata'} <= columns['steps']:
            raise AntigravitySourceError('unsupported Antigravity conversation schema; usage stays pending')
        rows = db.execute('SELECT idx, data FROM gen_metadata WHERE idx > ? ORDER BY idx',
                          (after_ordinal,)).fetchall()
        high_water, blocked, generations = after_ordinal, False, 0
        for idx, data in rows:
            terminal = True
            try:
                generator = _message(data or b'')
                chat = _sub(generator, 1) or {}
                usage = _sub(chat, 4)
                if usage is None or (_int(usage, 2) is None and _int(usage, 3) is None):
                    # Errored generations carry no counters; anything else may be in flight.
                    terminal = generator.get(5) is not None
                    note('generation_error_without_usage' if terminal else 'generation_pending')
                else:
                    records.append(_fact(source_id, conversation_id, idx, generator, chat, usage,
                                         db, segments, note))
                    generations += 1
            except (ValueError, TypeError, AttributeError, OverflowError, sqlite3.Error):
                note('undecodable_generation')
                terminal = False
            if not terminal:
                blocked = True
            elif not blocked:
                high_water = idx
        db.rollback()
    except sqlite3.Error as exc:
        raise AntigravitySourceError('Antigravity conversation source could not be read') from exc
    finally:
        db.close()
    if not records and after_ordinal < 0 and not diagnostics:
        note('no_inference_evidence')
    return Result(records, diagnostics, high_water, generations)


def _fact(source_id, conversation_id, idx, generator, chat, usage, db, segments, note):
    meta = _metadata(chat)
    if meta.get('cascade_id', conversation_id) != conversation_id:
        raise ValueError('generation belongs to another conversation')
    semantics = list(SEMANTICS)
    if meta.get('root_cascade_id', conversation_id) != conversation_id:
        semantics.append('child_conversation')
    raw = {'input_tokens': _int(usage, 2) or 0, 'output_tokens': _int(usage, 3) or 0,
           'cache_read_tokens': _int(usage, 5) or 0, 'thinking_tokens': _int(usage, 9) or 0}
    cache_write = _int(usage, 4)
    if cache_write is None:
        semantics.append('cache_write_unreported')
    else:
        raw['cache_write_tokens'] = cache_write
    if raw['output_tokens'] != raw['thinking_tokens'] + (_int(usage, 10) or 0):
        semantics.append('inconsistent_output_breakdown')
        note('inconsistent_output_breakdown')
    finished = None
    for step in _indices(generator, 2):
        row = db.execute('SELECT metadata FROM steps WHERE idx = ?', (step,)).fetchone()
        stamp = _sub(_message(row[0] or b''), 7) if row else None
        if stamp is not None:
            finished = max(finished or (0, 0), _seconds(stamp))
    timestamp = _iso(*finished) if finished else None
    if timestamp is None:
        semantics.append('completion_time_unknown')
        note('completion_time_unknown')
    ttft, streaming = _sub(chat, 11), _sub(chat, 12)
    duration = None
    if ttft is not None and streaming is not None:
        duration = sum(s * 1000 + n // 1000000 for s, n in (_seconds(ttft), _seconds(streaming)))
    model = chat.get(19, [b''])[-1].decode('utf-8', 'strict') or None
    if model is None:
        semantics.append('model_unobserved')
        note('model_unobserved')
    response_id = usage.get(11, [b''])[-1].decode('ascii', 'strict')
    counters = dict(raw, model=model)
    revision = response_id or 'sha256:' + hashlib.sha256(
        json.dumps(counters, sort_keys=True).encode()).hexdigest()[:32]
    return ('usage_events', {
        'source_id': source_id, 'event_id': f'generation:{idx}', 'revision': revision,
        'source_ordinal': idx, 'source_timestamp': timestamp,
        'segment_id': _segment(timestamp, segments), 'runtime': 'antigravity',
        'provider': PROVIDERS.get(_int(usage, 6)), 'model': model, 'effort': None,
        'input_tokens': raw['input_tokens'] + raw['cache_read_tokens'],
        'output_tokens': raw['output_tokens'], 'cache_read_tokens': raw['cache_read_tokens'],
        'cache_write_tokens': cache_write, 'thinking_tokens': raw['thinking_tokens'],
        'provider_total_tokens': None, 'inference_duration_ms': duration,
        'source_schema': SOURCE_SCHEMA, 'completeness': 'complete',
        'semantics': semantics, 'raw_usage': raw,
    })
