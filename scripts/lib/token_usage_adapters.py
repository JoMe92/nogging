"""Adapters and durable ingestion checkpoints for runtime token usage.

Normalizes Claude and Codex transcripts into canonical usage_events facts.
Handles repeated streaming snapshots, overlapping summaries, cache semantics,
partial final lines, file rotation, crashes around checkpoints, and durable spooling.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import uuid

from token_usage_store import Store, StoreError, fact, COUNTERS


def now_iso():
    return datetime.now(timezone.utc).isoformat()


class ClaudeAdapter:
    """Normalizes Claude Code assistant records and streaming snapshots."""

    def __init__(self):
        # Maps (source_id, event_id) -> state dict
        self.seen = {}
        self.diagnostics = []

    def parse_record(self, data, segment_id=None):
        """Parse a single Claude record dictionary. Returns ('usage_events', fact) or None."""
        if not isinstance(data, dict):
            return None
        # Must be an assistant record or message record with assistant role and usage
        rec_type = data.get('type')
        message = data.get('message')
        if not isinstance(message, dict):
            return None
        role = message.get('role')
        if rec_type != 'assistant' and role != 'assistant':
            return None
        usage = message.get('usage')
        if not isinstance(usage, dict):
            return None

        msg_id = message.get('id') or data.get('requestId') or data.get('uuid')
        session_id = data.get('sessionId') or data.get('session_id')
        if not msg_id or not session_id:
            return None

        source_id = f"claude:{session_id}"
        event_id = str(msg_id)

        raw_input = usage.get('input_tokens')
        cache_read = usage.get('cache_read_input_tokens')
        cache_creation = usage.get('cache_creation_input_tokens')
        raw_output = usage.get('output_tokens')

        details = usage.get('output_tokens_details') or {}
        thinking = details.get('thinking_tokens')
        duration_ms = usage.get('inference_duration_ms') or data.get('duration_ms')
        provider_total = usage.get('total_tokens')

        # Claude inclusive input is uncached input + cache read + cache creation
        # Cache creation and iterations sub-structures are breakdowns and must NOT be added again
        semantics = ['cache_summed_input']
        if cache_creation is None:
            cache_write_tokens = None
            inclusive_input = (raw_input or 0) + (cache_read or 0)
            semantics.append('missing_cache_write')
        else:
            cache_write_tokens = cache_creation
            inclusive_input = (raw_input or 0) + (cache_read or 0) + (cache_creation or 0)
            semantics.append('cache_write')

        if cache_read:
            semantics.append('cache_read')
        if thinking:
            semantics.append('thinking')

        # Provider total consistency
        if provider_total is not None and provider_total != (inclusive_input or 0) + (raw_output or 0):
            semantics.append('inconsistent_provider_total')

        if 'inconsistent_provider_total' in semantics:
            completeness = 'inconsistent'
        elif 'missing_cache_write' in semantics:
            completeness = 'partial'
        else:
            completeness = 'complete'

        # Allowlisted raw usage counters
        raw_usage = {}
        if raw_input is not None:
            raw_usage['input_tokens'] = raw_input
        if raw_output is not None:
            raw_usage['output_tokens'] = raw_output
        if cache_read is not None:
            raw_usage['cache_read_tokens'] = cache_read
        if cache_write_tokens is not None:
            raw_usage['cache_write_tokens'] = cache_write_tokens
        if thinking is not None:
            raw_usage['thinking_tokens'] = thinking
        if provider_total is not None:
            raw_usage['provider_total_tokens'] = provider_total
        if duration_ms is not None:
            raw_usage['inference_duration_ms'] = duration_ms

        model = message.get('model') or data.get('advisorModel')
        effort = data.get('effort') or data.get('perTurnEffort')
        timestamp = data.get('timestamp')

        current_state = {
            'input_tokens': raw_input,
            'output_tokens': raw_output,
            'cache_read': cache_read,
            'cache_write': cache_write_tokens,
            'model': model,
        }

        # Deduplicate identical streaming snapshots and validate revisions
        key = (source_id, event_id)
        if key in self.seen:
            prior = self.seen[key]
            # Identical snapshot: skip
            if prior['state'] == current_state:
                return None
            # Check revision validity: model unchanged, raw input and cache read consistent, output monotonic
            valid = (
                model == prior['state']['model'] and
                raw_input == prior['state']['input_tokens'] and
                cache_read == prior['state']['cache_read'] and
                (raw_output or 0) >= (prior['state']['output_tokens'] or 0)
            )
            if not valid:
                self.diagnostics.append({
                    'type': 'incompatible_revision',
                    'source_id': source_id,
                    'event_id': event_id,
                    'prior': prior['state'],
                    'current': current_state,
                })
                return None
            source_ordinal = prior['source_ordinal'] + 1
            revision = f"rev_{source_ordinal}"
        else:
            source_ordinal = 0
            revision = "rev_0"

        self.seen[key] = {
            'state': current_state,
            'source_ordinal': source_ordinal,
            'revision': revision,
        }

        fact_dict = {
            'source_id': source_id,
            'event_id': event_id,
            'revision': revision,
            'source_ordinal': source_ordinal,
            'source_timestamp': timestamp,
            'segment_id': segment_id,
            'runtime': 'claude',
            'provider': 'anthropic',
            'model': model,
            'effort': effort,
            'source_schema': 'claude:assistant_message:v1',
            'completeness': completeness,
            'semantics': semantics,
            'raw_usage': raw_usage,
            'input_tokens': inclusive_input,
            'output_tokens': raw_output,
            'cache_read_tokens': cache_read,
            'cache_write_tokens': cache_write_tokens,
            'thinking_tokens': thinking,
            'provider_total_tokens': provider_total,
            'inference_duration_ms': duration_ms,
        }
        return ('usage_events', fact_dict)


class CodexAdapter:
    """Normalizes Codex rollout records (token_usage_record) and tracks context."""

    def __init__(self):
        self.current_provider = 'openai'
        self.current_model = None
        self.current_effort = None
        self.session_id = None
        self.seen = {}
        self.diagnostics = []

    def parse_record(self, data, segment_id=None):
        """Parse a single Codex rollout record dictionary. Returns ('usage_events', fact) or None."""
        if not isinstance(data, dict):
            return None
        rec_type = data.get('type')
        payload = data.get('payload') or {}

        if rec_type == 'session_meta':
            if payload.get('model_provider'):
                self.current_provider = payload['model_provider']
            if payload.get('session_id'):
                self.session_id = payload['session_id']
            return None

        if rec_type == 'turn_context':
            if payload.get('model'):
                self.current_model = payload['model']
            if payload.get('effort'):
                self.current_effort = payload['effort']
            return None

        # Ignore overlapping summaries: token_count in event_msg
        if rec_type == 'event_msg':
            return None

        if rec_type == 'token_usage_record':
            response_id = payload.get('response_id')
            session_id = payload.get('session_id') or payload.get('thread_id') or self.session_id
            usage = payload.get('usage')
            if not response_id or not session_id or not isinstance(usage, dict):
                return None

            source_id = f"codex:{session_id}"
            event_id = str(response_id)

            input_tokens = usage.get('input_tokens')  # Already includes cached input
            cache_read = usage.get('cached_input_tokens')
            cache_write = usage.get('cache_write_input_tokens')
            output_tokens = usage.get('output_tokens')
            reasoning = usage.get('reasoning_output_tokens')
            total_tokens = usage.get('total_tokens')
            duration_ms = usage.get('inference_duration_ms') or payload.get('duration_ms')

            # Check provider total consistency: observed input + output = total
            expected_total = (input_tokens or 0) + (output_tokens or 0)
            inconsistent_total = total_tokens is not None and total_tokens != expected_total

            semantics = ['cache_inclusive_input']
            if cache_read:
                semantics.append('cache_read')
            if cache_write:
                semantics.append('cache_write')
            if cache_write is None:
                semantics.append('missing_cache_write')
            if reasoning:
                semantics.append('reasoning_output')
            if inconsistent_total:
                semantics.append('inconsistent_provider_total')

            if inconsistent_total:
                completeness = 'inconsistent'
            elif cache_write is None:
                completeness = 'partial'
            else:
                completeness = 'complete'

            raw_usage = {}
            if input_tokens is not None:
                raw_usage['input_tokens'] = input_tokens
            if output_tokens is not None:
                raw_usage['output_tokens'] = output_tokens
            if cache_read is not None:
                raw_usage['cache_read_tokens'] = cache_read
            if cache_write is not None:
                raw_usage['cache_write_tokens'] = cache_write
            if reasoning is not None:
                raw_usage['thinking_tokens'] = reasoning
            if total_tokens is not None:
                raw_usage['provider_total_tokens'] = total_tokens
            if duration_ms is not None:
                raw_usage['inference_duration_ms'] = duration_ms

            model = self.current_model or payload.get('model')
            effort = self.current_effort or payload.get('effort')
            timestamp = data.get('timestamp')

            current_state = {
                'input_tokens': input_tokens,
                'output_tokens': output_tokens,
                'cache_read': cache_read,
                'cache_write': cache_write,
                'total_tokens': total_tokens,
                'model': model,
            }

            key = (source_id, event_id)
            if key in self.seen:
                prior = self.seen[key]
                if prior['state'] == current_state:
                    return None
                # Revision
                valid = (
                    model == prior['state']['model'] and
                    input_tokens == prior['state']['input_tokens'] and
                    (output_tokens or 0) >= (prior['state']['output_tokens'] or 0)
                )
                if not valid:
                    self.diagnostics.append({
                        'type': 'incompatible_revision',
                        'source_id': source_id,
                        'event_id': event_id,
                        'prior': prior['state'],
                        'current': current_state,
                    })
                    return None
                source_ordinal = prior['source_ordinal'] + 1
                revision = f"rev_{source_ordinal}"
            else:
                source_ordinal = 0
                revision = "rev_0"

            self.seen[key] = {
                'state': current_state,
                'source_ordinal': source_ordinal,
                'revision': revision,
            }

            fact_dict = {
                'source_id': source_id,
                'event_id': event_id,
                'revision': revision,
                'source_ordinal': source_ordinal,
                'source_timestamp': timestamp,
                'segment_id': segment_id,
                'runtime': 'codex',
                'provider': self.current_provider,
                'model': model,
                'effort': effort,
                'source_schema': 'codex:token_usage_record:v1',
                'completeness': completeness,
                'semantics': semantics,
                'raw_usage': raw_usage,
                'input_tokens': input_tokens,
                'output_tokens': output_tokens,
                'cache_read_tokens': cache_read,
                'cache_write_tokens': cache_write,
                'thinking_tokens': reasoning,
                'provider_total_tokens': total_tokens,
                'inference_duration_ms': duration_ms,
            }
            return ('usage_events', fact_dict)

        return None


def read_source_lines(source_path, start_offset=0):
    """Read complete lines from a file from start_offset.

    Returns (parsed_lines, new_offset, has_partial_tail) where:
    - parsed_lines is list of dicts from valid JSON lines
    - new_offset is the byte offset up to which complete lines were read
    - has_partial_tail is True if a trailing line without '\n' was skipped
    """
    path = Path(source_path)
    if not path.is_file():
        return [], 0, False

    parsed = []
    current_offset = start_offset
    has_partial_tail = False

    with path.open('rb') as f:
        f.seek(start_offset)
        while True:
            line_bytes = f.readline()
            if not line_bytes:
                break
            if not line_bytes.endswith(b'\n'):
                # Incomplete partial line at EOF: do not consume!
                has_partial_tail = True
                break
            line_str = line_bytes.decode('utf-8', errors='replace').strip()
            if line_str:
                try:
                    data = json.loads(line_str)
                    parsed.append(data)
                except ValueError:
                    # Malformed JSON line: advance offset past it to avoid hang
                    pass
            current_offset += len(line_bytes)

    return parsed, current_offset, has_partial_tail


class CheckpointManager:
    """Manages durable per-source checkpoints."""

    def __init__(self, state_root):
        self.root = Path(state_root) / 'checkpoints'
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)

    def _path_for(self, source_path):
        resolved = str(Path(source_path).resolve())
        slug = hashlib.sha256(resolved.encode('utf-8')).hexdigest()
        return self.root / f"{slug}.json"

    def get(self, source_path):
        p = self._path_for(source_path)
        if not p.is_file():
            return None
        try:
            return json.loads(p.read_text())
        except (ValueError, OSError):
            return None

    def save(self, source_path, offset, inode, size, mtime_ns):
        data = {
            'source_path': str(Path(source_path).resolve()),
            'offset': offset,
            'inode': inode,
            'size': size,
            'mtime_ns': mtime_ns,
            'updated_at': now_iso(),
        }
        target = self._path_for(source_path)
        temp = target.with_suffix(f'.tmp.{os.getpid()}')
        try:
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w') as f:
                f.write(json.dumps(data))
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp, target)
        except Exception:
            if temp.exists():
                temp.unlink(missing_ok=True)
            raise

    def check_rotation(self, source_path):
        """Check if source file was rotated or truncated. Returns (start_offset, stat)."""
        stat = os.stat(source_path)
        cp = self.get(source_path)
        if cp is None:
            return 0, stat
        # If inode changed or file size shrank below recorded offset, it was rotated/truncated
        if cp.get('inode') != stat.st_ino or stat.st_size < cp.get('offset', 0):
            return 0, stat
        return cp.get('offset', 0), stat


class SpoolManager:
    """Durable spooling for allowlisted usage facts when Dolt is unavailable."""

    def __init__(self, state_root):
        self.root = Path(state_root) / 'spool'
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)

    def spool_batch(self, records, owners=None):
        batch_id = f"batch_{int(datetime.now(timezone.utc).timestamp())}_{uuid.uuid4().hex[:12]}"
        path = self.root / f"{batch_id}.json"
        temp = path.with_suffix(f'.tmp.{os.getpid()}')
        data = {'batch_id': batch_id, 'records': records, 'owners': owners or {}}
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(json.dumps(data))
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
        return path

    def pending_batches(self):
        return sorted(self.root.glob('batch_*.json'))

    def drain(self, store):
        """Replay and drain pending spooled batches into store."""
        drained = 0
        for batch_file in self.pending_batches():
            try:
                data = json.loads(batch_file.read_text())
                records = data.get('records', [])
                owners = data.get('owners', {})
                store.append(records, owners)
                batch_file.unlink(missing_ok=True)
                drained += 1
            except (ValueError, OSError, StoreError):
                # Stop on error, preserve remaining spool files
                break
        return drained


class Ingester:
    """Orchestrates ingestion, checkpoints, adapters, and spooling."""

    def __init__(self, store=None, state_root=None, device_id=None):
        self.store = store
        root = state_root or (store.root if store else None)
        if not root:
            raise ValueError('either store or state_root must be provided')
        self.root = Path(root)
        self.checkpoints = CheckpointManager(self.root)
        self.spool = SpoolManager(self.root)
        self.device_id = device_id or (store.device() if store else None)
        self.claude_adapter = ClaudeAdapter()
        self.codex_adapter = CodexAdapter()

    def ingest_file(self, source_path, runtime, segment_id=None):
        """Ingest new lines from source_path using the designated runtime adapter."""
        source_path = Path(source_path).resolve()
        if not source_path.is_file():
            return {'status': 'missing', 'records': 0, 'diagnostics': []}

        # Drain prior spooled batches if store is available
        if self.store:
            try:
                self.spool.drain(self.store)
            except StoreError:
                pass

        start_offset, stat = self.checkpoints.check_rotation(source_path)
        records_data, new_offset, has_partial = read_source_lines(source_path, start_offset)

        adapter = self.claude_adapter if runtime == 'claude' else self.codex_adapter
        facts = []
        for row in records_data:
            fact_entry = adapter.parse_record(row, segment_id=segment_id)
            if fact_entry:
                facts.append(fact_entry)

        spooled = False
        if facts and self.store:
            owners = {entry[1]['source_id']: self.device_id for entry in facts} if self.device_id else None
            try:
                self.store.append(facts, owners=owners)
            except StoreError:
                self.spool.spool_batch(facts, owners=owners)
                spooled = True

        # Advance checkpoint only up to complete consumed lines
        self.checkpoints.save(source_path, new_offset, stat.st_ino, stat.st_size, stat.st_mtime_ns)

        return {
            'status': 'spooled' if spooled else 'success',
            'records': len(facts),
            'new_offset': new_offset,
            'has_partial_tail': has_partial,
            'diagnostics': list(adapter.diagnostics),
        }
