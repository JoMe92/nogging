"""Read-only quota observations. Never return raw runtime records or paths.

Claude cache v1: {schema_version: 1, observed_at: RFC3339,
                 rate_limits: <statusline rate_limits object>}.
Account identity is deliberately unknown: source directories are not accounts.
"""
import datetime as dt
import json
import math
import os
from pathlib import Path

UTC = dt.timezone.utc


def timestamp(value):
    if isinstance(value, bool):
        raise ValueError('invalid timestamp')
    if isinstance(value, (int, float)):
        if not math.isfinite(value):
            raise ValueError('invalid timestamp')
        return dt.datetime.fromtimestamp(value, UTC)
    if isinstance(value, str):
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is not None:
            return parsed.astimezone(UTC)
    raise ValueError('timestamp needs timezone')


def iso(value):
    return value.isoformat().replace('+00:00', 'Z')


def percent(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError('invalid percentage')
    if not math.isfinite(value) or not 0 <= value <= 100:
        raise ValueError('invalid percentage')
    return value


def codex_observation(root):
    """Choose newest observation by event time, never filesystem mtime.

    Parse only metadata events. Invalid UTF-8 in transcripts does not prevent
    reading quota metadata. A newer invalid observation cannot resurrect an
    older valid quota sample. No authentication files are consulted.
    """
    best = None
    damaged = False
    for path in root.glob('*/*/*/rollout-*.jsonl'):
        try:
            with path.open(errors='replace') as stream:
                for line in stream:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        damaged = True
                        continue
                    if not isinstance(row, dict) or row.get('type') != 'event_msg':
                        continue
                    payload = row.get('payload')
                    if not isinstance(payload, dict) or payload.get('type') != 'token_count':
                        continue
                    if payload.get('rate_limits') is None:
                        continue
                    try:
                        observed = timestamp(row.get('timestamp'))
                    except (ValueError, TypeError, OverflowError, OSError):
                        damaged = True
                        continue
                    if best is None or observed >= best[0]:
                        best = (observed, payload['rate_limits'])
        except OSError:
            damaged = True
    if best is None:
        return None, None, 'malformed or unreadable source' if damaged else 'missing usage source'
    return *best, None


def claude_observation(path):
    try:
        row = json.loads(path.read_text())
        if not isinstance(row, dict) or type(row.get('schema_version')) is not int or row.get('schema_version') != 1:
            return None, None, 'unsupported cache schema'
        return timestamp(row.get('observed_at')), row.get('rate_limits'), None
    except FileNotFoundError:
        return None, None, 'missing usage source'
    except (ValueError, TypeError, OSError, OverflowError):
        return None, None, 'malformed or unreadable source'


def inspect_usage(agent, *, source=None, now=None, stale_after=600):
    if agent not in ('codex', 'claude'):
        raise ValueError('unsupported usage provider')
    if agent == 'codex':
        root = Path(source) if source else Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'sessions'
        observed, limits, reason = codex_observation(root)
        names = (('short', 'primary'), ('weekly', 'secondary'))
        used_key = 'used_percent'
    else:
        cache = Path(source) if source else Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'nogging/usage/claude.json'
        observed, limits, reason = claude_observation(cache)
        names = (('short', 'five_hour'), ('weekly', 'seven_day'))
        used_key = 'used_percentage'
    now = now or dt.datetime.now(UTC)
    if observed is not None:
        age = (now - observed).total_seconds()
        if age < 0:
            reason = 'observation is in the future'
        elif age > stale_after:
            reason = 'stale observation'
    if not isinstance(limits, dict) and reason is None:
        reason = 'missing or unsupported usage windows'
    windows = []
    for bucket, key in names:
        item = {'bucket': bucket, 'status': 'unknown', 'reason': reason,
                'used_percent': None, 'resets_at': None,
                'observed_at': iso(observed) if observed else None}
        if reason is None:
            try:
                raw = limits[key]
                used = percent(raw[used_key])
                reset = timestamp(raw['resets_at'])
                if agent == 'codex':
                    minutes = raw['window_minutes']
                    if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or not math.isfinite(minutes) or minutes <= 0:
                        raise ValueError('invalid window')
                    item['window_minutes'] = minutes
                if reset <= now:
                    item['reason'] = 'reset elapsed; fresh observation required'
                elif reset <= observed:
                    item['reason'] = 'reset precedes observation'
                else:
                    item.update(status='known', reason=None, used_percent=used, resets_at=iso(reset))
            except (KeyError, ValueError, TypeError, OverflowError, OSError):
                item['reason'] = 'missing or malformed window'
        windows.append(item)
    return {'schema_version': 1, 'provider': agent, 'account': None,
            'model_group': None, 'status': 'known' if all(w['status'] == 'known' for w in windows) else 'unknown',
            'windows': windows}


def usage_command(agent, json_output=False):
    report = inspect_usage(agent)
    if json_output:
        print(json.dumps(report, sort_keys=True, allow_nan=False))
        return
    print(f"{agent} usage (account and model-group identity unknown)")
    for window in report['windows']:
        if window['status'] == 'known':
            print(f"  {window['bucket']}: {window['used_percent']:g}% used; reset {window['resets_at']}; observed {window['observed_at']}")
        else:
            print(f"  {window['bucket']}: unknown ({window['reason']})")
