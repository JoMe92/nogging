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


GATE_KEYS = ('enabled', 'cap_percent', 'estimate_percent', 'stale_seconds',
             'on_unknown', 'size_multipliers', 'exclude_roles')
GATE_ROLES = ('lead', 'planning', 'orchestrator', 'specialist')
GATE_AGENTS = ('claude', 'codex', 'pi', 'antigravity')


def _number(value, name, *, low=0, high=None, inclusive_low=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f'usage_gate.{name} must be a finite number')
    if value < low or (value == low and not inclusive_low) or (high is not None and value > high):
        bound = f'{"at least" if inclusive_low else "above"} {low:g}' + (f' and at most {high:g}' if high is not None else '')
        raise ValueError(f'usage_gate.{name} must be {bound}')
    return value


def gate_config(raw):
    """Validate the `usage_gate` config value; return it with defaults filled.

    Defaults: enabled, cap 92%, estimate 5% per launch, stale after 600s,
    unknown usage warns and continues, size labels small/medium/large scale
    the estimate 0.5/1/2, and planning plus orchestrator launches are not
    gated. `estimate_percent` is one number or a per-agent object with an
    optional `default`. Any unknown key or bad value is rejected.
    """
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise ValueError('usage_gate must be an object')
    unknown = sorted(set(raw) - set(GATE_KEYS) - {'//'})
    if unknown:
        raise ValueError(f'usage_gate has unsupported key(s): {", ".join(unknown)}')
    enabled = raw.get('enabled', True)
    if not isinstance(enabled, bool):
        raise ValueError('usage_gate.enabled must be true or false')
    cap = _number(raw.get('cap_percent', 92), 'cap_percent', high=100)
    estimate = raw.get('estimate_percent', 5)
    if isinstance(estimate, dict):
        bad = sorted(set(estimate) - set(GATE_AGENTS) - {'default'})
        if bad:
            raise ValueError(f'usage_gate.estimate_percent has unsupported agent(s): {", ".join(bad)}')
        estimate = {key: _number(value, f'estimate_percent.{key}', high=100, inclusive_low=True)
                    for key, value in estimate.items()}
        estimate.setdefault('default', 5)
    else:
        estimate = {'default': _number(estimate, 'estimate_percent', high=100, inclusive_low=True)}
    stale = _number(raw.get('stale_seconds', 600), 'stale_seconds')
    on_unknown = raw.get('on_unknown', 'warn')
    if on_unknown not in ('warn', 'deny'):
        raise ValueError('usage_gate.on_unknown must be "warn" or "deny"')
    sizes = raw.get('size_multipliers', {'small': 0.5, 'medium': 1, 'large': 2})
    if not isinstance(sizes, dict) or not sizes:
        raise ValueError('usage_gate.size_multipliers must be a non-empty object')
    for name, value in sizes.items():
        if not isinstance(name, str) or not name or name != name.strip() or ':' in name:
            raise ValueError('usage_gate.size_multipliers names must be plain non-empty labels')
        _number(value, f'size_multipliers.{name}')
    excluded = raw.get('exclude_roles', ['planning', 'orchestrator'])
    if not isinstance(excluded, list) or any(role not in GATE_ROLES for role in excluded):
        raise ValueError(f'usage_gate.exclude_roles must list roles from: {", ".join(GATE_ROLES)}')
    return {'enabled': enabled, 'cap_percent': cap, 'estimate_percent': estimate,
            'stale_seconds': stale, 'on_unknown': on_unknown,
            'size_multipliers': dict(sizes), 'exclude_roles': list(excluded)}


def size_multiplier(labels, config):
    """Return (size, multiplier) from at most one `size:<name>` Bead label."""
    sizes = sorted({label.split(':', 1)[1] for label in labels
                    if isinstance(label, str) and label.startswith('size:')})
    if not sizes:
        return None, 1
    if len(sizes) > 1:
        raise ValueError(f'conflicting size labels: {", ".join("size:" + s for s in sizes)}')
    if sizes[0] not in config['size_multipliers']:
        raise ValueError(f'unsupported size label size:{sizes[0]} (configured: '
                         f'{", ".join(sorted(config["size_multipliers"]))})')
    return sizes[0], config['size_multipliers'][sizes[0]]


def launch_estimate(agent, labels, config):
    size, multiplier = size_multiplier(labels, config)
    base = config['estimate_percent'].get(agent, config['estimate_percent']['default'])
    return {'base_percent': base, 'size': size, 'multiplier': multiplier,
            'estimate_percent': base * multiplier}


def evaluate_gate(report, config, estimate, reserved_percent=0):
    """Project current used + outstanding reservations + this estimate per
    window against the cap. A known window over the cap denies outright;
    otherwise any unknown window applies the unknown policy. Unknown usage is
    never treated as zero."""
    windows, limiting, unknown = [], [], []
    for window in report['windows']:
        item = {'bucket': window['bucket'], 'status': window['status'],
                'reason': window['reason'], 'used_percent': window['used_percent'],
                'resets_at': window['resets_at'], 'projected_percent': None, 'fits': None}
        if window['status'] == 'known':
            projected = window['used_percent'] + reserved_percent + estimate
            item.update(projected_percent=round(projected, 4), fits=projected <= config['cap_percent'])
            if not item['fits']:
                limiting.append(item)
        else:
            unknown.append(item)
        windows.append(item)
    if limiting:
        decision = 'denied'
    elif unknown:
        decision = 'unknown-denied' if config['on_unknown'] == 'deny' else 'unknown-admitted'
    else:
        decision = 'admitted'
    return {'decision': decision, 'cap_percent': config['cap_percent'],
            'estimate_percent': estimate, 'reserved_percent': reserved_percent,
            'fits': False if limiting else (None if unknown else True),
            'retry_after': max((w['resets_at'] for w in limiting), default=None),
            'windows': windows}


def observe(agent, config, *, now=None):
    try:
        return inspect_usage(agent, now=now, stale_after=config['stale_seconds'])
    except ValueError:
        reason = 'unsupported usage provider'
        return {'schema_version': 1, 'provider': agent, 'account': None, 'model_group': None,
                'status': 'unknown',
                'windows': [{'bucket': bucket, 'status': 'unknown', 'reason': reason,
                             'used_percent': None, 'resets_at': None, 'observed_at': None}
                            for bucket in ('short', 'weekly')]}


def describe_denial(gate):
    if gate['decision'] == 'unknown-denied':
        reasons = '; '.join(f"{w['bucket']}: {w['reason']}" for w in gate['windows'] if w['status'] != 'known')
        return f'usage unknown and usage_gate.on_unknown is deny ({reasons})'
    parts = [f"{w['bucket']} {w['used_percent']:g}% used + {gate['reserved_percent']:g}% reserved + "
             f"{gate['estimate_percent']:g}% estimate = {w['projected_percent']:g}% > cap "
             f"{gate['cap_percent']:g}% (resets {w['resets_at']})"
             for w in gate['windows'] if w['fits'] is False]
    return 'usage would exceed the cap: ' + '; '.join(parts) + f"; retry after {gate['retry_after']}"


def usage_command(agent, json_output=False, config=None):
    config = gate_config(config)
    report = observe(agent, config)
    estimate = launch_estimate(agent, (), config)
    report['gate'] = evaluate_gate(report, config, estimate['estimate_percent'])
    report['gate']['enabled'] = config['enabled']
    if json_output:
        print(json.dumps(report, sort_keys=True, allow_nan=False))
        return
    gate = report['gate']
    print(f"{agent} usage (account and model-group identity unknown)")
    for window, projection in zip(report['windows'], gate['windows']):
        if window['status'] == 'known':
            print(f"  {window['bucket']}: {window['used_percent']:g}% used; reset {window['resets_at']}; observed {window['observed_at']}; "
                  f"projected {projection['projected_percent']:g}% of cap {gate['cap_percent']:g}% "
                  f"({'fits' if projection['fits'] else 'does not fit'})")
        else:
            print(f"  {window['bucket']}: unknown ({window['reason']})")
    print(f"  estimate {gate['estimate_percent']:g}% per launch; reserved {gate['reserved_percent']:g}%; "
          f"fits: {'unknown' if gate['fits'] is None else ('yes' if gate['fits'] else 'no')}"
          + ('' if config['enabled'] else ' (usage_gate disabled)'))
