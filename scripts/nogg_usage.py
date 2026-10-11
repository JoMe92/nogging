"""Quota observations and same-host admission. Never return raw runtime records or paths.

Claude cache v1: {schema_version: 1, observed_at: RFC3339,
                 rate_limits: <statusline rate_limits object>}.
Account identity is deliberately unknown: source directories are not accounts.
"""
import datetime as dt
import json
import math
import os
import re
import shutil
import subprocess
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


AGY_PROBE_TIMEOUT = 45
# Runtime window names -> gate bucket names. Any other window the runtime
# reports is evaluated under its own sanitized name rather than dropped.
AGY_WINDOWS = {'5h': 'short', 'weekly': 'weekly'}
# Model id prefix -> the family name a group lists in its own description
# ("Models within this group: Gemini Flash, Gemini Pro"). A group is chosen
# only when exactly one group lists the selected model's family.
AGY_MODEL_FAMILIES = (
    (re.compile(r'^gemini-[0-9.]+-flash(?:-|$)'), 'gemini flash'),
    (re.compile(r'^gemini-[0-9.]+-pro(?:-|$)'), 'gemini pro'),
    (re.compile(r'^claude-opus(?:-|$)'), 'claude opus'),
    (re.compile(r'^claude-sonnet(?:-|$)'), 'claude sonnet'),
    (re.compile(r'^gpt-oss(?:-|$)'), 'gpt-oss'),
)


def _cache_root():
    return Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'nogging/usage'


def agy_cache_path():
    return _cache_root() / 'antigravity.json'


def agy_clean_groups(command):
    """Validate the runtime `/usage` command object and keep only allowlisted
    fields. Raises ValueError with a short reason when the shape is not the
    verified contract: an unrecognized result is never read as zero usage."""
    if not isinstance(command, dict) or command.get('name') != 'usage':
        raise ValueError('usage probe returned an unexpected command result')
    data = command.get('data')
    groups = data.get('groups') if isinstance(data, dict) else None
    if not isinstance(groups, list) or not groups:
        raise ValueError('usage probe returned no model groups')
    cleaned = []
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get('name'), str) or not group['name'].strip():
            raise ValueError('usage probe returned a malformed model group')
        buckets = group.get('buckets')
        if not isinstance(buckets, list):
            raise ValueError('usage probe returned a malformed model group')
        kept = []
        for bucket in buckets:
            if not isinstance(bucket, dict):
                raise ValueError('usage probe returned a malformed bucket')
            fraction, reset = bucket.get('remaining_fraction'), bucket.get('reset_time')
            kept.append({'id': bucket.get('id') if isinstance(bucket.get('id'), str) else None,
                         'window': bucket.get('window') if isinstance(bucket.get('window'), str) else None,
                         'remaining_fraction': fraction if isinstance(fraction, (int, float))
                         and not isinstance(fraction, bool) and math.isfinite(fraction) else None,
                         'reset_time': reset if isinstance(reset, str) else None})
        description = group.get('description')
        cleaned.append({'name': group['name'].strip(),
                        'description': description[:500] if isinstance(description, str) else '',
                        'buckets': kept})
    return cleaned


def agy_parse_probe(stdout):
    """Parse one headless `/usage` result. Exit status zero is not enough:
    the runtime reports hook denials and timeouts as SUCCESS with exit 0, so
    the status, denied actions, errors and the command shape are all checked."""
    try:
        doc = json.loads(stdout)
    except (ValueError, TypeError):
        raise ValueError('usage probe returned unparseable output') from None
    if not isinstance(doc, dict):
        raise ValueError('usage probe returned unparseable output')
    status = doc.get('status')
    if status != 'SUCCESS':
        shown = status[:40] if isinstance(status, str) else type(status).__name__
        raise ValueError(f'usage probe status was {shown!r}, not SUCCESS')
    if doc.get('denied_actions'):
        raise ValueError('usage probe reported denied actions')
    if doc.get('error') or doc.get('errors'):
        raise ValueError('usage probe reported an error')
    return agy_clean_groups(doc.get('command'))


def agy_probe(*, run=None, which=None, timeout=AGY_PROBE_TIMEOUT):
    """Run the runtime's read-only `/usage` command. Returns (groups, reason).

    The probe runs from a private neutral directory, never a worktree, with
    runtime auto-update disabled. It reads no credential and passes none.
    `AGY_NOGG_USAGE_PROBE=0` makes observation cache-only (the repository
    test runner sets it so no test reaches a developer's real runtime)."""
    if os.environ.get('AGY_NOGG_USAGE_PROBE', '1').strip().lower() in ('0', 'false', 'no', 'off'):
        return None, 'usage probe disabled by AGY_NOGG_USAGE_PROBE'
    exe = (which or shutil.which)('agy')
    if not exe:
        return None, 'agy is not installed'
    workdir = _cache_root() / 'antigravity-probe'
    try:
        workdir.mkdir(parents=True, exist_ok=True, mode=0o700)
    except OSError:
        return None, 'usage probe directory unavailable'
    env = dict(os.environ, AGY_CLI_DISABLE_AUTO_UPDATE='true')
    try:
        result = (run or subprocess.run)(
            [exe, '--print', '/usage', '--output-format', 'json', '--print-timeout', '30s'],
            cwd=workdir, env=env, capture_output=True, text=True, timeout=timeout,
            stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, 'usage probe timed out'
    except OSError:
        return None, 'usage probe could not run'
    if result.returncode != 0:
        return None, f'usage probe exited {result.returncode}'
    try:
        return agy_parse_probe(result.stdout), None
    except ValueError as exc:
        return None, str(exc)


def agy_cache_observation(path):
    try:
        row = json.loads(path.read_text())
        if not isinstance(row, dict) or type(row.get('schema_version')) is not int or row.get('schema_version') != 1:
            return None, None, 'unsupported cache schema'
        groups = row.get('groups')
        if not isinstance(groups, list):
            return None, None, 'malformed or unreadable source'
        return timestamp(row.get('observed_at')), groups, None
    except FileNotFoundError:
        return None, None, 'missing usage source'
    except (ValueError, TypeError, OSError, OverflowError):
        return None, None, 'malformed or unreadable source'


def agy_write_cache(path, groups, observed):
    import tempfile
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('w', dir=path.parent, prefix='.antigravity-usage-', delete=False) as stream:
            temporary = Path(stream.name)
            json.dump({'schema_version': 1, 'observed_at': iso(observed), 'groups': groups},
                      stream, sort_keys=True, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


def agy_observation(*, cache=None, probe=True, now=None, stale_after=600, run=None, which=None):
    """(observed_at, groups, reason): a fresh cached observation, else one
    bounded `/usage` probe. A failed probe never falls back to stale data."""
    now = now or dt.datetime.now(UTC)
    path = Path(cache) if cache else agy_cache_path()
    observed, groups, reason = agy_cache_observation(path)
    if reason is None and 0 <= (now - observed).total_seconds() <= stale_after:
        return observed, groups, None
    if not probe:
        return observed, groups, reason
    fresh, why = agy_probe(run=run, which=which)
    if fresh is None:
        return observed, groups, why
    try:
        agy_write_cache(path, fresh, now)
    except (OSError, ValueError):
        pass   # only reuse is lost; this observation is still valid
    return now, fresh, None


def agy_model_family(model):
    text = str(model or '').strip().lower()
    for pattern, family in AGY_MODEL_FAMILIES:
        if pattern.match(text):
            return family
    return None


def agy_select_group(groups, model):
    """(group, reason): the one group that lists the selected model's family.
    An unset model, an unrecognized family, or zero/several matches is an
    unknown mapping, never a guess and never another group's headroom."""
    family = agy_model_family(model)
    if family is None:
        return None, 'unknown model mapping'
    matches = []
    for group in groups:
        listed = str(group.get('description') or '').split(':', 1)
        if len(listed) == 2 and family in {item.strip().lower() for item in listed[1].split(',')}:
            matches.append(group)
    if len(matches) != 1:
        return None, 'unknown model mapping' if not matches else 'ambiguous model mapping'
    return matches[0], None


def agy_report(model, observed, groups, reason, now):
    group, group_reason = (None, reason)
    if reason is None:
        group, group_reason = agy_select_group(groups, model)
    base_reason = group_reason
    if observed is not None and base_reason is None:
        age = (now - observed).total_seconds()
        if age < 0:
            base_reason = 'observation is in the future'
    buckets = {}
    if group is not None:
        for entry in group['buckets']:
            window = entry.get('window')
            if not isinstance(window, str) or not window:
                continue
            name = AGY_WINDOWS.get(window) or re.sub(r'[^a-z0-9]+', '_', window.lower()).strip('_') or 'unknown'
            buckets[name] = None if name in buckets else entry
    windows = []
    for name in list(dict.fromkeys(['short', 'weekly', *buckets])):
        item = {'bucket': name, 'status': 'unknown', 'reason': base_reason, 'used_percent': None,
                'resets_at': None, 'observed_at': iso(observed) if observed else None}
        if base_reason is None:
            entry = buckets.get(name)
            if name not in buckets:
                item['reason'] = 'missing bucket'
            elif entry is None:
                item['reason'] = 'ambiguous bucket'
            else:
                try:
                    fraction = entry['remaining_fraction']
                    if (isinstance(fraction, bool) or not isinstance(fraction, (int, float))
                            or not math.isfinite(fraction) or not 0 <= fraction <= 1):
                        raise ValueError('invalid remaining fraction')
                    reset = timestamp(entry['reset_time'])
                    if reset <= now:
                        item['reason'] = 'reset elapsed; fresh observation required'
                    elif reset <= observed:
                        item['reason'] = 'reset precedes observation'
                    else:
                        item.update(status='known', reason=None, resets_at=iso(reset),
                                    used_percent=round((1 - fraction) * 100, 4))
                except (KeyError, ValueError, TypeError, OverflowError, OSError):
                    item['reason'] = 'missing or malformed window'
        windows.append(item)
    return {'schema_version': 1, 'provider': 'antigravity', 'account': None,
            'model_group': group['name'] if group else None,
            'status': 'known' if all(w['status'] == 'known' for w in windows) else 'unknown',
            'windows': windows}


def antigravity_usage(model=None, *, source=None, now=None, stale_after=600,
                      probe=None, run=None, which=None):
    """Quota report for the group the selected model belongs to. `source`
    names a cache file and, like the Claude cache, is read without probing;
    otherwise a stale or missing cache triggers one bounded `/usage` probe."""
    now = now or dt.datetime.now(UTC)
    observed, groups, reason = agy_observation(
        cache=source, probe=(source is None) if probe is None else probe,
        now=now, stale_after=stale_after, run=run, which=which)
    if observed is not None and reason is None and (now - observed).total_seconds() > stale_after:
        reason = 'stale observation'
    return agy_report(model, observed, groups, reason, now)


def antigravity_resume(model=None, **kwargs):
    """Resume guidance from every exhausted applicable bucket.

    `wait` carries the latest reset among exhausted buckets, so a weekly
    bucket that is still exhausted after the 5h window reset keeps the
    session waiting. `ready` requires every applicable bucket to be known and
    non-exhausted; anything else is `unknown`, never ready."""
    report = antigravity_usage(model, **kwargs)
    exhausted = [w for w in report['windows'] if w['status'] == 'known' and w['used_percent'] >= 100]
    unknown = [w for w in report['windows'] if w['status'] != 'known']
    if exhausted:
        status, resume_at = 'wait', max(w['resets_at'] for w in exhausted)
    elif unknown:
        status, resume_at = 'unknown', None
    else:
        status, resume_at = 'ready', None
    return {'status': status, 'resume_at': resume_at, 'model_group': report['model_group'],
            'exhausted': [w['bucket'] for w in exhausted],
            'reasons': {w['bucket']: w['reason'] for w in unknown}}


def inspect_usage(agent, *, source=None, now=None, stale_after=600, model=None):
    if agent == 'antigravity':
        return antigravity_usage(model, source=source, now=now, stale_after=stale_after)
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


class RecordResult(dict):
    """Result of recording a usage interval/sample. Truthy if accepted, falsy if rejected."""
    def __bool__(self):
        return bool(self.get('accepted'))

    @property
    def accepted(self):
        return bool(self.get('accepted'))

    @property
    def reason(self):
        return self.get('reason')


def history_key(agent, model=None):
    if not agent or not isinstance(agent, str):
        raise ValueError('agent must be a non-empty string')
    if model:
        return f"{agent}:{model}"
    return str(agent)


class UsageHistory:
    """Bounded per-agent/model usage history and conservative learned medians.

    Learns estimates only from complete, non-reset, attributable isolated
    intervals per agent/model. Overlapping intervals, quota resets, and
    outlier samples are rejected. If sample count is below `min_samples`,
    data is insufficient and callers fall back conservatively to configured
    estimates.
    Never stores or exposes credentials, tokens, or raw account identifiers.
    """
    def __init__(self, root=None, *, min_samples=3, max_samples=20):
        raw_root = Path(root) if root else Path(os.environ.get(
            'XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'nogging/usage/history'
        if raw_root.suffix == '.json':
            self.root = raw_root.parent
            self.file_path = raw_root
            self.lock_path = raw_root.with_suffix('.lock')
        else:
            self.root = raw_root
            self.file_path = raw_root / 'history.json'
            self.lock_path = raw_root / 'history.lock'
        self.min_samples = int(min_samples)
        self.max_samples = int(max_samples)

    def _transaction(self, action, *, readonly=False):
        import fcntl
        import tempfile
        if readonly and not self.file_path.exists():
            return action({})
        if not readonly:
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.root.chmod(0o700)
        lock_fd = os.open(self.lock_path, os.O_RDONLY if readonly else os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(lock_fd, 'r' if readonly else 'a+') as lock:
            if not readonly:
                os.fchmod(lock.fileno(), 0o600)
            fcntl.flock(lock, fcntl.LOCK_SH if readonly else fcntl.LOCK_EX)
            try:
                entries = json.loads(self.file_path.read_text())
                if not isinstance(entries, dict):
                    raise ValueError('invalid history')
            except FileNotFoundError:
                entries = {'schema_version': 1, 'samples': {}}
            except ValueError as exc:
                raise RuntimeError('usage history store is malformed') from exc
            result = action(entries)
            if readonly:
                return result
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode='w', dir=self.root, delete=False) as stream:
                    temporary = Path(stream.name)
                    json.dump(entries, stream, allow_nan=False, indent=2)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.chmod(temporary, 0o600)
                os.replace(temporary, self.file_path)
            finally:
                if temporary:
                    temporary.unlink(missing_ok=True)
            return result

    def get_samples(self, agent, model=None):
        key = history_key(agent, model)
        def action(entries):
            samples_map = entries.get('samples', {})
            return list(samples_map.get(key, []))
        return self._transaction(action, readonly=True)

    def has_sufficient_data(self, agent, model=None):
        return len(self.get_samples(agent, model)) >= self.min_samples

    def is_outlier(self, agent, model, delta):
        if delta < 0 or delta > 100:
            return True
        samples = self.get_samples(agent, model)
        if len(samples) < self.min_samples:
            return False
        import statistics
        values = sorted(s['delta_percent'] for s in samples)
        n = len(values)
        med = statistics.median(values)
        q1 = values[n // 4]
        q3 = values[(3 * n) // 4]
        iqr = q3 - q1
        upper_fence = q3 + max(1.5 * iqr, med * 1.5, 5.0)
        if delta > upper_fence:
            return True
        lower_fence = q1 - max(1.5 * iqr, med * 1.5, 5.0)
        if lower_fence > 0 and delta < lower_fence:
            return True
        return False

    def get_median(self, agent, model=None):
        samples = self.get_samples(agent, model)
        if len(samples) >= self.min_samples:
            import statistics
            values = sorted(s['delta_percent'] for s in samples)
            return round(float(statistics.median_high(values)), 4)
        if model:
            agent_samples = self.get_samples(agent, None)
            if len(agent_samples) >= self.min_samples:
                import statistics
                values = sorted(s['delta_percent'] for s in agent_samples)
                return round(float(statistics.median_high(values)), 4)
        return None

    def get_estimate(self, agent, model=None, fallback=5.0):
        med = self.get_median(agent, model)
        return med if med is not None else fallback

    def record_sample(self, agent, model, delta_percent, *,
                      overlapping=False, reset=False, outlier=False,
                      complete=True, recorded_at=None):
        if not complete:
            return RecordResult(accepted=False, reason='incomplete interval', decision='rejected')
        if overlapping:
            return RecordResult(accepted=False, reason='overlapping interval: concurrent sessions span interval', decision='rejected')
        if reset:
            return RecordResult(accepted=False, reason='reset interval: quota window reset during interval', decision='rejected')
        if outlier is True:
            return RecordResult(accepted=False, reason='outlier sample: explicit outlier', decision='rejected')

        if isinstance(delta_percent, bool) or not isinstance(delta_percent, (int, float)):
            raise ValueError('delta_percent must be a number')
        if not math.isfinite(delta_percent):
            raise ValueError('delta_percent must be finite')

        if delta_percent < 0:
            return RecordResult(accepted=False, reason='reset interval: negative delta indicates reset', decision='rejected')
        if delta_percent > 100:
            return RecordResult(accepted=False, reason='outlier sample: delta exceeds 100%', decision='rejected')

        if self.is_outlier(agent, model, delta_percent):
            return RecordResult(accepted=False, reason='outlier sample: deviates significantly from historical distribution', decision='rejected')

        key = history_key(agent, model)
        now_dt = dt.datetime.now(UTC)
        now_iso = iso(now_dt) if recorded_at is None else (
            iso(recorded_at) if isinstance(recorded_at, dt.datetime) else str(recorded_at))

        sample = {
            'delta_percent': round(float(delta_percent), 4),
            'recorded_at': now_iso
        }

        def action(entries):
            samples_map = entries.setdefault('samples', {})
            items = samples_map.setdefault(key, [])
            items.append(sample)
            if len(items) > self.max_samples:
                del items[:-self.max_samples]
            return RecordResult(accepted=True, reason=None, decision='accepted', sample=sample)

        return self._transaction(action)

    def record_interval(self, agent, model, start_report, end_report, *,
                        overlapping=False, concurrent_sessions=0, complete=True,
                        now=None, outlier=None, bucket='short'):
        if not complete:
            return RecordResult(accepted=False, reason='incomplete interval', decision='rejected')
        if overlapping or concurrent_sessions > 0:
            return RecordResult(accepted=False, reason='overlapping interval: concurrent sessions span interval', decision='rejected')
        if outlier is True:
            return RecordResult(accepted=False, reason='outlier sample: explicit outlier', decision='rejected')
        if start_report is None or end_report is None:
            return RecordResult(accepted=False, reason='missing usage observation', decision='rejected')
        if start_report.get('status') != 'known' or end_report.get('status') != 'known':
            return RecordResult(accepted=False, reason='unknown usage observation', decision='rejected')

        start_w = next((w for w in start_report.get('windows', []) if w.get('bucket') == bucket), None)
        end_w = next((w for w in end_report.get('windows', []) if w.get('bucket') == bucket), None)
        if not start_w or not end_w:
            return RecordResult(accepted=False, reason=f'missing {bucket} usage window', decision='rejected')
        if start_w.get('status') != 'known' or end_w.get('status') != 'known':
            return RecordResult(accepted=False, reason=f'unknown {bucket} usage window', decision='rejected')

        start_reset = start_w.get('resets_at')
        end_reset = end_w.get('resets_at')
        start_used = start_w.get('used_percent')
        end_used = end_w.get('used_percent')

        if start_reset is None or end_reset is None or start_used is None or end_used is None:
            return RecordResult(accepted=False, reason='incomplete window data', decision='rejected')

        if start_reset != end_reset:
            return RecordResult(accepted=False, reason='reset interval: reset boundary crossed', decision='rejected')

        if end_used < start_used:
            return RecordResult(accepted=False, reason='reset interval: counter decreased', decision='rejected')

        now_check = now or dt.datetime.now(UTC)
        try:
            reset_dt = timestamp(start_reset)
            if now_check >= reset_dt:
                return RecordResult(accepted=False, reason='reset interval: reset time elapsed', decision='rejected')
        except (ValueError, TypeError):
            pass

        delta = round(end_used - start_used, 4)
        return self.record_sample(agent, model, delta,
                                  outlier=(outlier if outlier is not None else False),
                                  recorded_at=end_w.get('observed_at') or now_check)

    def clear(self):
        def action(entries):
            entries.clear()
            entries['schema_version'] = 1
            entries['samples'] = {}
        self._transaction(action)


def launch_estimate(agent, labels, config, model=None, *, history=None):
    size, multiplier = size_multiplier(labels, config)
    fallback = config['estimate_percent'].get(agent, config['estimate_percent']['default'])
    hist = history if history is not None else UsageHistory()
    learned = hist.get_median(agent, model)
    base = learned if learned is not None else fallback
    return {'base_percent': base, 'size': size, 'multiplier': multiplier,
            'estimate_percent': base * multiplier}


def evaluate_gate(report, config, estimate, reserved_percent=0):
    """Project current used + outstanding reservations + this estimate per
    window against the cap. A known window over the cap denies outright;
    otherwise any unknown window applies the unknown policy. Unknown usage is
    never treated as zero."""
    windows, limiting, unknown = [], [], []
    for window in report['windows']:
        reserved = (reserved_percent.get(window['bucket'], 0)
                    if isinstance(reserved_percent, dict) else reserved_percent)
        item = {'bucket': window['bucket'], 'reserved_percent': reserved, 'status': window['status'],
                'reason': window['reason'], 'used_percent': window['used_percent'],
                'resets_at': window['resets_at'], 'projected_percent': None, 'fits': None}
        if window['status'] == 'known':
            projected = window['used_percent'] + reserved + estimate
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
    retry_after = max((w['resets_at'] for w in limiting), default=None)
    result = {'decision': decision, 'cap_percent': config['cap_percent'],
              'estimate_percent': estimate, 'reserved_percent': max(reserved_percent.values(), default=0) if isinstance(reserved_percent, dict) else reserved_percent,
              'fits': False if limiting else (None if unknown else True),
              'retry_after': retry_after,
              'windows': windows}
    guidance = orchestrator_retry_guidance(result)
    if guidance is not None:
        result['retry_guidance'] = guidance
    return result


def orchestrator_retry_guidance(gate):
    """Scheduling guidance for orchestrators when admission is denied.

    Uses all limiting reset windows (reporting the latest reset time) and
    explicitly prohibits model switching to bypass account limits.
    """
    decision = gate.get('decision')
    if decision not in ('denied', 'unknown-denied'):
        return None
    if decision == 'unknown-denied':
        return {
            'action': 'verify_source',
            'retry_after': None,
            'model_switching_allowed': False,
            'guidance': 'unknown quota denied; verify local observation sources; do not switch models to bypass limits'
        }
    limiting = [w for w in gate.get('windows', []) if not w.get('fits', True)]
    retry_after = gate.get('retry_after')
    limiting_names = [w['bucket'] for w in limiting]
    return {
        'action': 'retry_after_reset',
        'retry_after': retry_after,
        'limiting_windows': limiting_names,
        'model_switching_allowed': False,
        'guidance': f"schedule bounded retry after latest reset {retry_after} across all limiting windows ({', '.join(limiting_names)}); do not switch models to bypass account limits"
    }


def observe(agent, config, *, now=None, model=None):
    try:
        return inspect_usage(agent, now=now, stale_after=config['stale_seconds'], model=model)
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
    parts = [f"{w['bucket']} {w.get('used_percent', 0):g}% used + {w.get('reserved_percent', gate.get('reserved_percent', 0)):g}% reserved + "
             f"{gate.get('estimate_percent', 0):g}% estimate = {w.get('projected_percent', 0):g}% > cap "
             f"{gate.get('cap_percent', 0):g}% (resets {w.get('resets_at')})"
             for w in gate['windows'] if w.get('fits') is False]
    return 'usage would exceed the cap: ' + '; '.join(parts) + f"; retry after {gate['retry_after']} (scheduling uses all limiting reset windows without model switching)"


def usage_command(agent, json_output=False, config=None, model=None):
    config = gate_config(config)
    report = observe(agent, config, model=model)
    if model:
        report['model'] = model
    estimate = launch_estimate(agent, (), config, model=model)
    report['gate'] = evaluate_gate(report, config, estimate['estimate_percent'], Reservations().totals(report))
    report['gate']['enabled'] = config['enabled']
    if json_output:
        print(json.dumps(report, sort_keys=True, allow_nan=False))
        return
    gate = report['gate']
    target_desc = f"{agent} (model {model})" if model else agent
    identity = ('account identity unknown; model group ' + report['model_group']
                if report.get('model_group') else 'account and model-group identity unknown')
    print(f"{target_desc} usage ({identity})")
    for window, projection in zip(report['windows'], gate['windows']):
        if window['status'] == 'known':
            print(f"  {window['bucket']}: {window['used_percent']:g}% used; reset {window['resets_at']}; observed {window['observed_at']}; "
                  f"reserved {projection['reserved_percent']:g}%; projected {projection['projected_percent']:g}% of cap {gate['cap_percent']:g}% "
                  f"({'fits' if projection['fits'] else 'does not fit'})")
        else:
            print(f"  {window['bucket']}: unknown ({window['reason']})")
    print(f"  estimate {gate['estimate_percent']:g}% per launch; reserved {gate['reserved_percent']:g}%; "
          f"fits: {'unknown' if gate['fits'] is None else ('yes' if gate['fits'] else 'no')}"
          + ('' if config['enabled'] else ' (usage_gate disabled)'))
    if gate.get('retry_guidance'):
        print(f"  orchestrator retry guidance: {gate['retry_guidance']['guidance']}")



def reservation_scope(report):
    """Opaque scope only; never infer an account from authentication files.

    Until an adapter supplies account/group identity, conservatively share all
    launches of that provider for this OS user, even across source directories.
    The public report continues to describe identity as unknown.
    """
    import hashlib
    provider = report['provider']
    identity = report.get('account') or {'unknown': True}
    return hashlib.sha256(json.dumps([provider, identity, report.get('model_group')],
                                    sort_keys=True).encode()).hexdigest()


class Reservations:
    """Same-user, same-host admission ledger, shared across repositories.

    Lock files are stable inodes; the ledger is replaced atomically under the
    lock. Pending owners hold kernel file locks, which work across PID
    namespaces and are released on process death. Bound owners use durable
    session state and tmux liveness, so a launcher
    exit does not release a still-running worker's estimate.
    """
    def __init__(self, root=None):
        self.root = Path(root) if root else Path(os.environ.get(
            'XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'nogging/usage/reservations'
        self.pending = {}

    def _alive(self, entry):
        import subprocess
        owner = entry.get('session')
        if owner:
            try:
                record = json.loads(Path(owner['path']).read_text())
            except (OSError, ValueError):
                record = None
            if record and record.get('state') in ('stopped', 'failed', 'retired'):
                return False
            try:
                result = subprocess.run([owner['tmux'], '-L', owner['socket'],
                                         'has-session', '-t', owner['name']],
                                        capture_output=True, timeout=5)
                if result.returncode == 0:
                    return True
            except (OSError, subprocess.TimeoutExpired):
                # Tool failure is not proof that a worker is dead.
                return True
        return self._pending_alive(entry['owner'])

    def _pending_alive(self, owner):
        import fcntl
        try:
            descriptor = os.open(self.root / owner, os.O_RDONLY)
        except FileNotFoundError:
            return False
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False
            except BlockingIOError:
                return True
        finally:
            os.close(descriptor)

    def finish(self, token):
        """Drop the launcher's pending-owner lock after binding a live child."""
        descriptor = self.pending.pop(token, None)
        if descriptor is not None:
            os.close(descriptor)

    def _transaction(self, action, *, readonly=False):
        import fcntl
        import tempfile
        if readonly and not (self.root / 'ledger.json').exists():
            return action({})
        if not readonly:
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.root.chmod(0o700)
        lock_fd = os.open(self.root / 'ledger.lock', os.O_RDONLY if readonly else os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(lock_fd, 'r' if readonly else 'a+') as lock:
            if not readonly:
                os.fchmod(lock.fileno(), 0o600)
            fcntl.flock(lock, fcntl.LOCK_SH if readonly else fcntl.LOCK_EX)
            path = self.root / 'ledger.json'
            try:
                entries = json.loads(path.read_text())
                if not isinstance(entries, dict):
                    raise ValueError('invalid ledger')
            except FileNotFoundError:
                entries = {}
            except ValueError as exc:
                raise RuntimeError('usage reservation ledger is malformed; admission refused') from exc
            original = dict(entries)
            entries = {key: value for key, value in entries.items() if self._alive(value)}
            result = action(entries)
            if readonly:
                return result
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode='w', dir=self.root, delete=False) as stream:
                    temporary = Path(stream.name)
                    json.dump(entries, stream, allow_nan=False)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
                for key in original.keys() - entries.keys():
                    (self.root / original[key]['owner']).unlink(missing_ok=True)
            finally:
                if temporary:
                    temporary.unlink(missing_ok=True)
            return result

    @staticmethod
    def _totals(entries, scope, report):
        # A fresh reset window no longer owes reservations from its predecessor.
        return {window['bucket']: sum(entry['estimate'] for entry in entries.values()
                    if entry['scope'] == scope and
                    entry['windows'].get(window['bucket']) in (None, window['resets_at']))
                for window in report['windows']}

    def totals(self, report):
        return self._transaction(lambda entries: self._totals(entries, reservation_scope(report), report), readonly=True)

    def admit(self, report, config, estimate):
        import uuid
        scope = reservation_scope(report)
        def action(entries):
            gate = evaluate_gate(report, config, estimate, self._totals(entries, scope, report))
            if gate['decision'] not in ('denied', 'unknown-denied'):
                token = uuid.uuid4().hex
                import fcntl
                owner = token + '.owner'
                descriptor = os.open(self.root / owner, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.pending[token] = descriptor
                entries[token] = {'scope': scope, 'estimate': estimate,
                                  'windows': {w['bucket']: w['resets_at'] for w in report['windows']},
                                  'owner': owner}
                gate['reservation_id'] = token
            return gate
        try:
            return self._transaction(action)
        except BaseException:
            # An atomic ledger write can fail after the owner lock was taken.
            for token in list(self.pending):
                self.finish(token)
                (self.root / (token + '.owner')).unlink(missing_ok=True)
            raise

    def bind(self, token, path, name, tmux, socket):
        def action(entries):
            if token not in entries:
                raise RuntimeError('usage admission reservation disappeared before launch completed')
            entries[token]['session'] = {'path': str(Path(path).resolve()), 'name': name,
                                          'tmux': tmux, 'socket': socket}
        self._transaction(action)

    def release(self, token):
        try:
            self._transaction(lambda entries: entries.pop(token, None))
        finally:
            self.finish(token)


def _generate_statusline_wrapper(upstream_cmd):
    serialized_upstream = repr(upstream_cmd)
    return f"""#!/usr/bin/env python3
# Nogging Claude statusline capture wrapper.
# Generated automatically by `nogg usage install-statusline`.
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

UPSTREAM_COMMAND = {serialized_upstream}

def capture(raw):
    try:
        data = json.loads(raw)
        if isinstance(data, dict) and "rate_limits" in data and isinstance(data["rate_limits"], dict):
            now = dt.datetime.now(dt.timezone.utc)
            cache_dir = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "nogging/usage"
            cache_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            try:
                os.chmod(cache_dir, 0o700)
            except OSError:
                pass
            cache_file = cache_dir / "claude.json"
            record = {{
                "schema_version": 1,
                "observed_at": now.isoformat().replace("+00:00", "Z"),
                "rate_limits": data["rate_limits"]
            }}
            with tempfile.NamedTemporaryFile("w", dir=cache_dir, prefix=".claude-usage-", delete=False) as tf:
                tmp_path = Path(tf.name)
                json.dump(record, tf, sort_keys=True)
                tf.flush()
                os.fsync(tf.fileno())
            try:
                os.chmod(tmp_path, 0o600)
            except OSError:
                pass
            os.replace(tmp_path, cache_file)
    except Exception:
        pass

def main():
    if sys.stdin.isatty():
        print("Nogging Claude statusline capture wrapper. Expects Claude statusline JSON on stdin.", file=sys.stderr)
        sys.exit(0)
    raw_stdin = sys.stdin.read()
    capture(raw_stdin)
    if UPSTREAM_COMMAND:
        try:
            res = subprocess.run(
                UPSTREAM_COMMAND,
                input=raw_stdin,
                shell=True,
                text=True
            )
            sys.exit(res.returncode)
        except Exception:
            sys.exit(1)
    else:
        sys.exit(0)

if __name__ == "__main__":
    main()
"""


def install_statusline(settings_path=None, wrapper_path=None):
    """Explicitly install or compose the Claude Code statusline usage capture wrapper.

    Preserves existing user statusline through composition, or refuses with
    actionable manual instructions if composition is unsupported or conflicts.
    Preserves all unrelated user settings in settings.json.
    """
    settings_file = Path(settings_path).expanduser().resolve() if settings_path else (
        Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))) / 'settings.json'
    )
    wrapper_file = Path(wrapper_path).expanduser().resolve() if wrapper_path else (
        Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'nogging/claude-statusline'
    )

    existing_settings = {}
    if settings_file.exists():
        try:
            content = settings_file.read_text(encoding='utf-8')
            parsed = json.loads(content)
            if not isinstance(parsed, dict):
                raise ValueError('root must be a JSON object')
            existing_settings = parsed
        except Exception as exc:
            raise RuntimeError(
                f"cannot automatically compose statusline: settings file {settings_file} is malformed or unreadable ({exc}).\n"
                "Manual instructions:\n"
                f"1. Repair {settings_file} to ensure it contains valid JSON.\n"
                "2. Configure a statusLine command that captures Claude's stdin JSON to "
                "$XDG_CACHE_HOME/nogging/usage/claude.json before invoking your custom statusline."
            ) from exc

    existing_statusline = existing_settings.get('statusLine')
    upstream_cmd = None

    if existing_statusline is not None:
        if isinstance(existing_statusline, dict):
            st_type = existing_statusline.get('type')
            if st_type is not None and st_type != 'command':
                raise RuntimeError(
                    f"cannot automatically compose existing statusline: unsupported statusLine type '{st_type}'.\n"
                    "Manual instructions:\n"
                    "Nogging supports composing command-based statusLine configurations ({\"type\": \"command\", \"command\": \"...\"}).\n"
                    "To capture usage manually, configure your statusline provider to write Claude's stdin to "
                    "$XDG_CACHE_HOME/nogging/usage/claude.json (schema_version 1, observed_at UTC ISO8601, rate_limits)."
                )
            cmd = existing_statusline.get('command')
            if not isinstance(cmd, str) or not cmd.strip():
                raise RuntimeError(
                    "cannot automatically compose existing statusline: statusLine object missing non-empty 'command'.\n"
                    "Manual instructions:\n"
                    f"Ensure 'statusLine.command' in {settings_file} specifies a valid command before installing, "
                    "or remove 'statusLine' to use Nogging's standalone statusline capture."
                )
            if str(wrapper_file) in cmd or 'nogging/claude-statusline' in cmd:
                return {
                    'status': 'already_installed',
                    'wrapper_path': str(wrapper_file),
                    'settings_path': str(settings_file),
                    'message': f"statusline capture already installed at {wrapper_file} and configured in {settings_file}"
                }
            upstream_cmd = cmd.strip()
        elif isinstance(existing_statusline, str):
            if str(wrapper_file) in existing_statusline or 'nogging/claude-statusline' in existing_statusline:
                return {
                    'status': 'already_installed',
                    'wrapper_path': str(wrapper_file),
                    'settings_path': str(settings_file),
                    'message': f"statusline capture already installed at {wrapper_file} and configured in {settings_file}"
                }
            upstream_cmd = existing_statusline.strip()
        else:
            raise RuntimeError(
                f"cannot automatically compose existing statusline: unsupported statusLine configuration ({type(existing_statusline).__name__}).\n"
                "Manual instructions:\n"
                f"Configure 'statusLine' in {settings_file} as {{\"type\": \"command\", \"command\": \"...\"}} or remove it."
            )

    import tempfile
    wrapper_file.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    wrapper_content = _generate_statusline_wrapper(upstream_cmd)

    with tempfile.NamedTemporaryFile('w', dir=wrapper_file.parent, prefix='.claude-statusline-', delete=False) as tf:
        tmp_wrapper = Path(tf.name)
        tf.write(wrapper_content)
        tf.flush()
        os.fsync(tf.fileno())
    os.chmod(tmp_wrapper, 0o755)
    os.replace(tmp_wrapper, wrapper_file)

    new_settings = dict(existing_settings)
    if isinstance(existing_statusline, dict):
        new_statusline = dict(existing_statusline)
        new_statusline['type'] = 'command'
        new_statusline['command'] = str(wrapper_file)
        new_settings['statusLine'] = new_statusline
    else:
        new_settings['statusLine'] = {
            'type': 'command',
            'command': str(wrapper_file)
        }

    settings_file.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with tempfile.NamedTemporaryFile('w', dir=settings_file.parent, prefix='.claude-settings-', delete=False) as tf:
        tmp_settings = Path(tf.name)
        json.dump(new_settings, tf, indent=2, sort_keys=True)
        tf.write('\n')
        tf.flush()
        os.fsync(tf.fileno())
    os.chmod(tmp_settings, 0o600 if settings_file.exists() else 0o644)
    os.replace(tmp_settings, settings_file)

    return {
        'status': 'installed',
        'wrapper_path': str(wrapper_file),
        'settings_path': str(settings_file),
        'composed_upstream': upstream_cmd,
        'message': f"installed statusline capture at {wrapper_file}" + (
            f" (composed with existing command: {upstream_cmd})" if upstream_cmd else ""
        )
    }


def quota_freshness_notes(config=None, now=None):
    """Advisory doctor notes regarding local quota observation cache freshness.

    Distinguishes missing, stale, and fresh observation sources for Claude
    and Codex. Never raises; returns advisory lines for `doctor`.
    """
    cfg = gate_config(config)
    stale_sec = cfg['stale_seconds']
    notes = []

    # Claude observation check
    claude_cache = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'nogging/usage/claude.json'
    if not claude_cache.exists():
        notes.append("quota observation (claude): missing statusline cache — run `nogg usage install-statusline` to opt in")
    else:
        try:
            obs = inspect_usage('claude', source=claude_cache, now=now, stale_after=stale_sec)
            if obs['status'] == 'known':
                notes.append("quota observation (claude): fresh observation cache")
            else:
                reasons = '; '.join(w.get('reason') or 'unknown' for w in obs['windows'] if w.get('status') != 'known')
                if 'stale observation' in reasons:
                    notes.append(f"quota observation (claude): observation is stale (> {stale_sec}s old) — run Claude to refresh")
                else:
                    notes.append(f"quota observation (claude): cache unavailable ({reasons})")
        except Exception as exc:
            notes.append(f"quota observation (claude): unreadable cache ({exc})")

    # Antigravity observation check: cache only; doctor never spawns the runtime.
    if shutil.which('agy'):
        try:
            observed, groups, reason = agy_cache_observation(agy_cache_path())
            now_dt = now or dt.datetime.now(UTC)
            if reason == 'missing usage source':
                notes.append("quota observation (antigravity): no cached /usage observation — "
                             "the next launch or `nogg usage --agent antigravity --model <model>` refreshes it")
            elif reason is not None:
                notes.append(f"quota observation (antigravity): cache unavailable ({reason})")
            elif (now_dt - observed).total_seconds() > stale_sec:
                notes.append(f"quota observation (antigravity): observation is stale (> {stale_sec}s old) — "
                             "refreshed by the next launch or `nogg usage --agent antigravity`")
            else:
                notes.append("quota observation (antigravity): fresh /usage observation cache")
        except Exception as exc:
            notes.append(f"quota observation (antigravity): unreadable cache ({exc})")

    # Codex observation check
    codex_sessions = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'sessions'
    try:
        obs = inspect_usage('codex', source=codex_sessions, now=now, stale_after=stale_sec)
        if obs['status'] == 'known':
            notes.append("quota observation (codex): fresh observation metadata")
        else:
            reasons = '; '.join(w.get('reason') or 'unknown' for w in obs['windows'] if w.get('status') != 'known')
            if 'missing usage source' in reasons:
                notes.append("quota observation (codex): missing usage source (no rollout session metadata)")
            elif 'stale observation' in reasons:
                notes.append(f"quota observation (codex): observation is stale (> {stale_sec}s old) — run Codex to refresh")
            else:
                notes.append(f"quota observation (codex): observation unavailable ({reasons})")
    except Exception as exc:
        notes.append(f"quota observation (codex): unreadable metadata ({exc})")

    return notes
