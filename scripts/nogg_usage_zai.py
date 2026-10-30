"""Z.ai coding-plan quota for `nogg usage --agent pi` (design Decisions 6 and 7).

Pure parsing, the shared snapshot cache, provider resolution and one bounded
probe, with `run` and `opener` injected. The API key is a local variable of
`probe` only: it is never written to disk, never placed on a command line, never
added to another process's environment, and never reaches a log, a record, a
report or an exception message, because every failure is reduced to one of the
fixed reasons below before it leaves this module. The endpoint is a constant.
"""
import datetime as dt
import json
import math
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

UTC = dt.timezone.utc
ENDPOINT = 'https://api.z.ai/api/monitor/usage/quota/limit'
KEY_TIMEOUT = 15
REQUEST_TIMEOUT = 10
MAX_BODY = 1 << 20
MODEL_GROUP = 'zai-coding-plan'

REASON_NO_PI = 'pi not installed'
REASON_NO_KEY = 'no Z.ai API key configured in Pi'
REASON_UNSUPPORTED = 'unsupported quota response'
HINT_NO_KEY = 'configure the ZAI Coding Plan key in Pi (/login)'
HINT_NO_PI = 'install pi'
DISABLED_HINT = 'run nogg usage --agent pi'
HINTS = {REASON_NO_KEY: HINT_NO_KEY, REASON_NO_PI: HINT_NO_PI}

_KEY = re.compile(r'^[\x21-\x7e]{1,512}$')
_LABEL = re.compile(r'^[A-Za-z0-9 ._-]{1,32}$')
_WINDOWS = {3: 'short', 6: 'weekly'}


def _number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def _iso(value):
    return value.isoformat().replace('+00:00', 'Z')


def _constant(name):
    raise ValueError('non-finite number')


def parse_quota(body):
    """{'level'?, 'short'?, 'weekly'?} with (used_percent, resets_at) windows,
    or None when the body is not a usable quota response. TIME_LIMIT entries and
    unknown units are ignored; a window that does not validate is omitted."""
    if not isinstance(body, dict) or not _number(body.get('code')) or body['code'] != 200:
        return None
    data = body.get('data')
    limits = data.get('limits') if isinstance(data, dict) else None
    if not isinstance(limits, list):
        return None
    quota = {}
    for entry in limits:
        if not isinstance(entry, dict) or entry.get('type') != 'TOKENS_LIMIT':
            continue
        key = _WINDOWS.get(entry.get('unit')) if isinstance(entry.get('unit'), int) and not isinstance(entry.get('unit'), bool) else None
        if key is None or key in quota:
            continue
        used, reset = entry.get('percentage'), entry.get('nextResetTime')
        if not _number(used) or not 0 <= used <= 100 or not _number(reset) or reset <= 0:
            continue
        try:
            quota[key] = (used, dt.datetime.fromtimestamp(reset / 1000, UTC))
        except (OverflowError, OSError, ValueError):
            continue
    if not quota:
        return None
    level = data.get('level')
    if isinstance(level, str) and _LABEL.match(level):
        quota['level'] = level
    return quota


def cache_path():
    root = os.environ.get('XDG_CACHE_HOME') or str(Path.home() / '.cache')
    return Path(root) / 'nogging/usage/pi-zai.json'


def read_cache(path):
    """(observed_at, quota, reason) for the shared snapshot, whoever wrote it."""
    try:
        row = json.loads(Path(path).read_text(), parse_constant=_constant)
    except FileNotFoundError:
        return None, None, 'missing usage source'
    except (ValueError, OSError):
        return None, None, 'malformed or unreadable source'
    if (not isinstance(row, dict) or type(row.get('schema_version')) is not int
            or row['schema_version'] != 1 or row.get('provider') != 'zai'):
        return None, None, 'unsupported cache schema'
    try:
        observed = dt.datetime.fromisoformat(row['observed_at'].replace('Z', '+00:00'))
        if observed.tzinfo is None:
            raise ValueError('timestamp needs timezone')
        observed = observed.astimezone(UTC)
        windows = row['windows']
        quota = {}
        for key in ('short', 'weekly'):
            if key not in windows:
                continue
            used = windows[key]['used_percent']
            reset = dt.datetime.fromisoformat(windows[key]['resets_at'].replace('Z', '+00:00'))
            if not _number(used) or not 0 <= used <= 100 or reset.tzinfo is None:
                raise ValueError('invalid window')
            quota[key] = (used, reset.astimezone(UTC))
        if not quota:
            raise ValueError('no windows')
        level = row.get('plan_level')
        if isinstance(level, str) and _LABEL.match(level):
            quota['level'] = level
    except (KeyError, ValueError, TypeError, AttributeError, OverflowError, OSError):
        return None, None, 'malformed or unreadable source'
    return observed, quota, None


def write_cache(path, quota, observed, source='nogg-probe'):
    """Write the key-free snapshot atomically: private directory, 0600 file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass   # not ours to tighten; the file itself stays 0600
    row = {'schema_version': 1, 'provider': 'zai', 'source': source,
           'observed_at': _iso(observed), 'windows': {}}
    if 'level' in quota:
        row['plan_level'] = quota['level']
    for key in ('short', 'weekly'):
        if key in quota:
            row['windows'][key] = {'used_percent': quota[key][0], 'resets_at': _iso(quota[key][1])}
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('w', dir=path.parent, prefix='.pi-zai-', delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(row, stream, sort_keys=True, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


def settings_path():
    """Pi's personal settings.json. auth.json is never opened."""
    return Path(os.environ.get('PI_CODING_AGENT_DIR') or Path.home() / '.pi/agent') / 'settings.json'


def resolve_provider(model, profile_provider):
    """The effective Pi provider: the model's `<provider>/` prefix, else the
    profile's provider, else `defaultProvider` in Pi's personal settings.json.
    None when none of them names one."""
    if isinstance(model, str) and model.strip().split('/', 1)[0] and '/' in model.strip():
        return model.strip().split('/', 1)[0].lower()
    if isinstance(profile_provider, str) and profile_provider.strip():
        return profile_provider.strip().lower()
    try:
        settings = json.loads(settings_path().read_text())
    except (ValueError, OSError):
        return None
    value = settings.get('defaultProvider') if isinstance(settings, dict) else None
    return value.strip().lower() if isinstance(value, str) and value.strip() else None


def provider_label(name):
    """A provider name that is safe to print: plain label characters only."""
    return re.sub(r'[^A-Za-z0-9._-]', '_', str(name))[:32] or 'unknown'


def probe_enabled(env=None):
    env = os.environ if env is None else env
    return str(env.get('PI_NOGG_USAGE_PROBE', '1')).strip().lower() not in ('0', 'false', 'no', 'off')


def hint_for(reason):
    return HINTS.get(reason)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """The key must not follow a redirect anywhere."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _default_opener(request, timeout=None):
    return urllib.request.build_opener(NoRedirect).open(request, timeout=timeout)


def _timed_out(exc):
    return isinstance(exc, (TimeoutError, socket.timeout)) or (
        isinstance(exc, urllib.error.URLError) and isinstance(exc.reason, (TimeoutError, socket.timeout)))


def probe(*, run=None, opener=None, which=None, now=None):
    """(quota, reason): one `pi auth print-api-key --provider zai` call under a
    15 s timeout with stdout captured in memory, then one GET to the constant
    endpoint under a 10 s timeout. Exactly one reason on failure; the key and
    the underlying exception text never leave this function."""
    exe = (which or shutil.which)('pi')
    if not exe:
        return None, REASON_NO_PI
    try:
        done = (run or subprocess.run)(
            [exe, 'auth', 'print-api-key', '--provider', 'zai'], capture_output=True, text=True,
            timeout=KEY_TIMEOUT, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, 'quota probe failed (timeout)'
    except OSError:
        return None, REASON_NO_PI
    except Exception:
        return None, REASON_NO_KEY
    key = done.stdout.strip() if done.returncode == 0 and isinstance(done.stdout, str) else ''
    if not _KEY.match(key):
        return None, REASON_NO_KEY
    try:
        request = urllib.request.Request(
            ENDPOINT, headers={'Authorization': f'Bearer {key}', 'Accept': 'application/json'}, method='GET')
        with (opener or _default_opener)(request, timeout=REQUEST_TIMEOUT) as response:
            status = getattr(response, 'status', 200)
            raw, deadline = b'', time.monotonic() + REQUEST_TIMEOUT
            while len(raw) <= MAX_BODY:
                chunk = response.read(1 << 16)
                if not chunk:
                    break
                raw += chunk
                if time.monotonic() > deadline:
                    raise TimeoutError()
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            return None, f'Z.ai rejected the key (HTTP {exc.code})'
        return None, 'quota probe failed (network)'
    except Exception as exc:
        return None, f'quota probe failed ({"timeout" if _timed_out(exc) else "network"})'
    finally:
        key = request = None
    if status != 200 or len(raw) > MAX_BODY:
        return None, REASON_UNSUPPORTED
    try:
        quota = parse_quota(json.loads(raw, parse_constant=_constant))
    except (ValueError, TypeError):
        quota = None
    return (quota, None) if quota else (None, REASON_UNSUPPORTED)
