"""TASK-PXG-003: the Z.ai quota module. Pure parsing over the shared glm-usage
fixtures, the cache, provider resolution and the key-safe probe, all with
injected run and opener callables, so no `pi`, network or real key is involved."""
import datetime as dt
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.dont_write_bytecode = True
import nogg_usage_zai as z

FIXTURES = HERE.parent / '.pi/nogging/extensions/glm-usage/test/fixtures'
UTC = dt.timezone.utc
NOW = dt.datetime(2026, 10, 27, 16, 0, tzinfo=UTC)
SENTINEL = 'sk-SENTINEL-do-not-leak-0123456789'


def fixture(name):
    return json.loads((FIXTURES / f'{name}.json').read_text())


def fixture_bytes(name):
    return (FIXTURES / f'{name}.json').read_bytes()


class Response:
    def __init__(self, body, status=200):
        self.body, self.status = body, status
        self.sent = False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, limit=-1):
        # A stream: the body once, then empty. A slow server is `Slow` below.
        if self.sent:
            return b''
        self.sent = True
        return self.body


def pi_ok(key=SENTINEL):
    def run(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 0, stdout=key + '\n', stderr='')
    return run


def opener_ok(body=None):
    seen = []

    def opener(request, timeout=None):
        seen.append((request, timeout))
        return Response(body if body is not None else fixture_bytes('both-windows'))
    opener.seen = seen
    return opener


def which_pi(name):
    return '/usr/bin/pi' if name == 'pi' else None


class ParseTest(unittest.TestCase):
    def test_both_windows(self):
        quota = z.parse_quota(fixture('both-windows'))
        self.assertEqual(quota['level'], 'placeholder-level')
        self.assertEqual(quota['short'], (37, dt.datetime.fromtimestamp(1792000000, UTC)))
        self.assertEqual(quota['weekly'], (21, dt.datetime.fromtimestamp(1792200000, UTC)))

    def test_time_limit_is_ignored(self):
        quota = z.parse_quota(fixture('time-limit-unit5'))
        self.assertEqual(sorted(k for k in quota if k in ('short', 'weekly')), ['short', 'weekly'])

    def test_weekly_absent_is_omitted(self):
        quota = z.parse_quota(fixture('weekly-absent'))
        self.assertIn('short', quota)
        self.assertNotIn('weekly', quota)

    def test_unsupported_shapes(self):
        for name in ('code-500', 'missing-limits', 'non-finite', 'out-of-range'):
            self.assertIsNone(z.parse_quota(fixture(name)), name)
        for body in (None, [], 'x', {'code': 200}, {'code': '200', 'data': {'limits': []}},
                     {'code': 200, 'data': {'limits': 'x'}}):
            self.assertIsNone(z.parse_quota(body))

    def test_level_is_a_plain_label_or_dropped(self):
        body = fixture('both-windows')
        body['data']['level'] = 'x\x1b[31m'
        self.assertNotIn('level', z.parse_quota(body))


class CacheTest(unittest.TestCase):
    def test_round_trip_is_atomic_and_private(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'usage' / 'pi-zai.json'
            quota = z.parse_quota(fixture('both-windows'))
            z.write_cache(path, quota, NOW, 'nogg-probe')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertEqual([p.name for p in path.parent.iterdir()], ['pi-zai.json'])
            row = json.loads(path.read_text())
            self.assertEqual((row['schema_version'], row['provider'], row['source']), (1, 'zai', 'nogg-probe'))
            observed, got, reason = z.read_cache(path)
            self.assertIsNone(reason)
            self.assertEqual((observed, got['short'], got['weekly']), (NOW, quota['short'], quota['weekly']))

    def test_reads_the_extension_snapshot(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'pi-zai.json'
            path.write_text(json.dumps({
                'schema_version': 1, 'provider': 'zai', 'source': 'pi-extension',
                'observed_at': '2026-10-27T16:00:00Z', 'plan_level': 'pro',
                'windows': {'short': {'used_percent': 37, 'resets_at': '2026-10-27T18:14:00Z'}}}))
            observed, quota, reason = z.read_cache(path)
            self.assertIsNone(reason)
            self.assertEqual(quota['short'][0], 37)
            self.assertNotIn('weekly', quota)

    def test_missing_malformed_and_foreign_caches(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'pi-zai.json'
            self.assertEqual(z.read_cache(path)[2], 'missing usage source')
            for text, reason in (('{', 'malformed or unreadable source'),
                                 ('[]', 'unsupported cache schema'),
                                 (json.dumps({'schema_version': 2, 'provider': 'zai'}), 'unsupported cache schema'),
                                 (json.dumps({'schema_version': 1, 'provider': 'other', 'observed_at': '2026-10-27T16:00:00Z',
                                              'windows': {}}), 'unsupported cache schema'),
                                 (json.dumps({'schema_version': 1, 'provider': 'zai', 'observed_at': 'nope',
                                              'windows': {}}), 'malformed or unreadable source'),
                                 (json.dumps({'schema_version': 1, 'provider': 'zai', 'observed_at': '2026-10-27T16:00:00Z',
                                              'windows': {'short': {'used_percent': 120, 'resets_at': '2026-10-27T18:14:00Z'}}}),
                                  'malformed or unreadable source')):
                path.write_text(text)
                self.assertEqual(z.read_cache(path)[2], reason, text)


class ProviderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = os.environ.get('PI_CODING_AGENT_DIR')
        os.environ['PI_CODING_AGENT_DIR'] = self.tmp.name
        self.addCleanup(lambda: os.environ.pop('PI_CODING_AGENT_DIR', None) if self.old is None
                        else os.environ.__setitem__('PI_CODING_AGENT_DIR', self.old))

    def settings(self, text):
        (Path(self.tmp.name) / 'settings.json').write_text(text)

    def test_model_prefix_wins(self):
        self.settings(json.dumps({'defaultProvider': 'anthropic'}))
        self.assertEqual(z.resolve_provider('zai/glm-5', 'openai'), 'zai')
        self.assertEqual(z.resolve_provider('/x', 'openai'), 'openai')

    def test_profile_then_default(self):
        self.settings(json.dumps({'defaultProvider': 'anthropic'}))
        self.assertEqual(z.resolve_provider('glm-5', 'zai'), 'zai')
        self.assertEqual(z.resolve_provider(None, None), 'anthropic')

    def test_unresolved(self):
        self.assertIsNone(z.resolve_provider(None, None))
        self.settings('{')
        self.assertIsNone(z.resolve_provider(None, None))
        self.settings('[]')
        self.assertIsNone(z.resolve_provider(None, None))

    def test_auth_json_is_never_read(self):
        (Path(self.tmp.name) / 'auth.json').write_text(json.dumps({'zai': {'key': SENTINEL}}))
        self.assertIsNone(z.resolve_provider(None, None))

    def test_label_is_sanitised(self):
        self.assertEqual(z.provider_label('anthropic'), 'anthropic')
        self.assertEqual(z.provider_label('a b\x1b[0m' * 20), z.provider_label('a b\x1b[0m' * 20))
        self.assertRegex(z.provider_label('a b\x1b[0m'), r'^[A-Za-z0-9._-]+$')


class ProbeTest(unittest.TestCase):
    def probe(self, run=None, opener=None, which=which_pi):
        return z.probe(run=run or pi_ok(), opener=opener or opener_ok(), which=which, now=NOW)

    def test_success(self):
        opener = opener_ok()
        quota, reason = self.probe(opener=opener)
        self.assertIsNone(reason)
        self.assertEqual(quota['short'][0], 37)
        request, timeout = opener.seen[0]
        self.assertEqual(request.full_url, z.ENDPOINT)
        self.assertEqual(request.get_method(), 'GET')
        self.assertEqual(timeout, 10)

    def test_the_key_command_has_no_key_and_a_bounded_timeout(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            return subprocess.CompletedProcess(argv, 0, stdout=SENTINEL + '\n', stderr='')
        self.probe(run=run)
        argv, kwargs = calls[0]
        self.assertEqual(argv, ['/usr/bin/pi', 'auth', 'print-api-key', '--provider', 'zai'])
        self.assertEqual(kwargs['timeout'], 15)
        self.assertTrue(kwargs['capture_output'])
        self.assertNotIn('env', kwargs)
        self.assertNotIn(SENTINEL, repr(calls))

    def test_pi_not_installed(self):
        quota, reason = self.probe(which=lambda name: None)
        self.assertEqual((quota, reason), (None, 'pi not installed'))

        def run(argv, **kwargs):
            raise FileNotFoundError(2, 'gone')
        self.assertEqual(self.probe(run=run)[1], 'pi not installed')

    def test_no_key_makes_no_request(self):
        for run in (lambda argv, **k: subprocess.CompletedProcess(argv, 1, stdout='', stderr='x'),
                    lambda argv, **k: subprocess.CompletedProcess(argv, 0, stdout='  \n', stderr=''),
                    lambda argv, **k: subprocess.CompletedProcess(argv, 0, stdout='two\nlines\n', stderr=''),
                    lambda argv, **k: subprocess.CompletedProcess(argv, 0, stdout='bad key', stderr='')):
            opener = opener_ok()
            self.assertEqual(self.probe(run=run, opener=opener), (None, 'no Z.ai API key configured in Pi'))
            self.assertEqual(opener.seen, [])

    def test_key_command_timeout(self):
        def run(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 15, output=SENTINEL)
        quota, reason = self.probe(run=run)
        self.assertEqual(reason, 'quota probe failed (timeout)')

    def test_rejected_key(self):
        for status in (401, 403):
            def opener(request, timeout=None, status=status):
                raise urllib.error.HTTPError(request.full_url, status, 'no', {}, None)
            self.assertEqual(self.probe(opener=opener)[1], f'Z.ai rejected the key (HTTP {status})')

    def test_other_failures(self):
        def timeout(request, timeout=None):
            raise TimeoutError()

        def urlerr(request, timeout=None):
            raise urllib.error.URLError(TimeoutError())

        def network(request, timeout=None):
            raise urllib.error.URLError('connection refused')

        def server(request, timeout=None):
            raise urllib.error.HTTPError(request.full_url, 503, 'x', {}, None)
        self.assertEqual(self.probe(opener=timeout)[1], 'quota probe failed (timeout)')
        self.assertEqual(self.probe(opener=urlerr)[1], 'quota probe failed (timeout)')
        self.assertEqual(self.probe(opener=network)[1], 'quota probe failed (network)')
        self.assertEqual(self.probe(opener=server)[1], 'quota probe failed (network)')

    def test_unsupported_responses(self):
        for body in (b'not json', b'[]', fixture_bytes('code-500'), fixture_bytes('missing-limits'),
                     fixture_bytes('out-of-range'), b'{"code":200,"data":{"limits":[]}}',
                     b'{"code": NaN}', b'x' * (2 << 20)):
            self.assertEqual(self.probe(opener=opener_ok(body)),
                             (None, 'unsupported quota response'), body[:40])

    def test_non_200_success_status_is_unsupported(self):
        def opener(request, timeout=None):
            return Response(fixture_bytes('both-windows'), status=204)
        self.assertEqual(self.probe(opener=opener)[1], 'unsupported quota response')

    def test_the_key_never_reaches_a_reason_or_an_exception(self):
        def leaky(request, timeout=None):
            raise RuntimeError(f"boom {request.get_header('Authorization')} {SENTINEL}")

        def leaky_http(request, timeout=None):
            raise urllib.error.HTTPError(request.full_url, 401, SENTINEL, {}, None)

        def leaky_run(argv, **kwargs):
            raise OSError(13, SENTINEL)
        for kwargs in ({'opener': leaky}, {'opener': leaky_http}, {'run': leaky_run}):
            quota, reason = self.probe(**kwargs)
            self.assertIsNone(quota)
            self.assertNotIn(SENTINEL, reason)

    def test_a_slow_body_is_cut_off_by_a_wall_clock_deadline(self):
        class Slow(Response):
            def read(self, limit=-1):
                return b'x'

        clock = iter([0.0, 0.0] + [11.0] * 50)
        original = z.time.monotonic
        z.time.monotonic = lambda: next(clock)
        try:
            quota, reason = self.probe(opener=lambda request, timeout=None: Slow(b''))
        finally:
            z.time.monotonic = original
        self.assertEqual((quota, reason), (None, 'quota probe failed (timeout)'))

    def test_an_existing_loose_directory_is_tightened(self):
        with tempfile.TemporaryDirectory() as td:
            directory = Path(td) / 'usage'
            directory.mkdir(mode=0o755)
            os.chmod(directory, 0o755)
            z.write_cache(directory / 'pi-zai.json', z.parse_quota(fixture('both-windows')), NOW)
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)

    def test_default_opener_refuses_redirects(self):
        handler = z.NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, 'Found', {}, 'http://elsewhere.invalid/'))


class ReportHintTest(unittest.TestCase):
    def test_hints(self):
        self.assertEqual(z.hint_for('no Z.ai API key configured in Pi'), 'configure the ZAI Coding Plan key in Pi (/login)')
        self.assertEqual(z.hint_for('pi not installed'), 'install pi')
        self.assertIsNone(z.hint_for('quota probe failed (network)'))
        self.assertEqual(z.DISABLED_HINT, 'run nogg usage --agent pi')

    def test_probe_enabled_follows_the_environment(self):
        for value, expected in (('0', False), ('false', False), ('', True), ('1', True)):
            self.assertEqual(z.probe_enabled({'PI_NOGG_USAGE_PROBE': value}), expected, value)
        self.assertTrue(z.probe_enabled({}))


if __name__ == '__main__':
    unittest.main()
