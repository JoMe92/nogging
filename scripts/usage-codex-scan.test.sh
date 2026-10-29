#!/usr/bin/env bash
# Incremental Codex rollout scan: the per-root index under the usage cache must
# parse only appended bytes and still return exactly what a full scan returns.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$root" <<'PY'
import datetime as dt
import hashlib
import json
import multiprocessing
import os
import random
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(sys.argv.pop()) / 'scripts'))
import nogg_usage as usage

BASE = dt.datetime(2026, 10, 11, 12, tzinfo=dt.timezone.utc)


def reference(root):
    """The full scan that preceded the index, verbatim: (result, damaged)."""
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
                        observed = usage.timestamp(row.get('timestamp'))
                    except (ValueError, TypeError, OverflowError, OSError):
                        damaged = True
                        continue
                    if best is None or observed >= best[0]:
                        best = (observed, payload['rate_limits'])
        except OSError:
            damaged = True
    if best is None:
        return (None, None, 'malformed or unreadable source' if damaged else 'missing usage source'), damaged
    return (*best, None), damaged


def comparable(result):
    observed, limits, reason = result
    return (usage.iso(observed) if observed else None, json.dumps(limits, sort_keys=True), reason)


def token(n, when=None, used=40):
    when = BASE + dt.timedelta(seconds=n) if when is None else when
    return (json.dumps({'type': 'event_msg', 'timestamp': usage.iso(when),
                        'payload': {'type': 'token_count', 'rate_limits': {
                            'n': n, 'primary': {'used_percent': used, 'window_minutes': 300,
                                                'resets_at': int(BASE.timestamp()) + 3600},
                            'secondary': {'used_percent': 10, 'window_minutes': 10080,
                                          'resets_at': int(BASE.timestamp()) + 600000}}}})
            + '\n').encode()


def _hammer(sessions, cache, rounds):
    os.environ['XDG_CACHE_HOME'] = cache
    for _ in range(rounds):
        usage.codex_observation(Path(sessions))


class CodexScanIndexTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.cache = self.tmp / 'cache'
        self.sessions = self.tmp / 'codex' / 'sessions'
        self.day = self.sessions / '2026/10/11'
        self.day.mkdir(parents=True)
        patcher = mock.patch.dict(os.environ, {'XDG_CACHE_HOME': str(self.cache),
                                               'CODEX_HOME': str(self.tmp / 'codex')})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.parsed = []
        real = usage._codex_fold
        def counting(region, best, damaged):
            self.parsed.append(len(region))
            return real(region, best, damaged)
        patcher = mock.patch.object(usage, '_codex_fold', counting)
        patcher.start()
        self.addCleanup(patcher.stop)

    def index_path(self):
        digest = hashlib.sha256(os.fsencode(str(self.sessions.resolve()))).hexdigest()[:16]
        return self.cache / 'nogging/usage' / f'codex-scan-{digest}.json'

    def index(self):
        return json.loads(self.index_path().read_text())

    def scan(self):
        """Incremental result and the damaged flag codex_observation computed."""
        flags = []
        real = usage._codex_scan_file
        def spy(path, entry):
            out = real(path, entry)
            flags.append(out[1])
            return out
        self.parsed.clear()
        with mock.patch.object(usage, '_codex_scan_file', spy):
            result = usage.codex_observation(self.sessions)
        return result, any(flags)

    def assertMatchesFullScan(self):
        got, damaged = self.scan()
        want, want_damaged = reference(self.sessions)
        self.assertEqual(comparable(got), comparable(want))
        self.assertEqual(damaged, want_damaged)
        return got, damaged

    def append(self, path, data):
        with path.open('ab') as stream:
            stream.write(data)

    def test_index_location_mode_and_content(self):
        path = self.day / 'rollout-a.jsonl'
        path.write_bytes(token(1) + b'{"type":"response_item","payload":{"text":"TRANSCRIPT SECRET"}}\n')
        self.assertMatchesFullScan()
        self.assertEqual(stat.S_IMODE(self.index_path().parent.stat().st_mode) & 0o077, 0)
        claude = self.cache / 'nogging/usage/claude.json'
        claude.write_text('{"keep": true}')
        self.append(path, token(2))
        self.assertMatchesFullScan()
        self.assertEqual(claude.read_text(), '{"keep": true}')
        index = self.index()
        self.assertEqual(index['schema_version'], 1)
        self.assertEqual(index['root'], str(self.sessions.resolve()))
        entry = index['files']['2026/10/11/rollout-a.jsonl']
        self.assertEqual(entry['offset'], path.stat().st_size)
        self.assertEqual(entry['inode'], path.stat().st_ino)
        self.assertNotIn('TRANSCRIPT', self.index_path().read_text())
        self.assertNotIn(str(self.tmp), json.dumps(index['files']))
        self.assertEqual(stat.S_IMODE(self.index_path().stat().st_mode), 0o600)
        self.assertEqual(sorted(p.name for p in self.index_path().parent.iterdir()),
                         sorted(['claude.json', self.index_path().name]))   # no temporary left

    def test_no_source_writes_no_index(self):
        for child in sorted(self.sessions.rglob('*'), reverse=True):
            child.rmdir()
        self.assertEqual(self.assertMatchesFullScan()[0][2], 'missing usage source')
        self.assertFalse(self.cache.exists())

    def test_append_parses_only_new_bytes(self):
        path = self.day / 'rollout-a.jsonl'
        path.write_bytes(token(1) + token(2))
        self.assertMatchesFullScan()
        self.assertEqual(sum(self.parsed), path.stat().st_size)
        before = self.index_path().stat().st_mtime_ns
        self.assertMatchesFullScan()
        self.assertEqual(sum(self.parsed), 0)
        self.assertEqual(self.index_path().stat().st_mtime_ns, before)   # unchanged: not rewritten
        extra = token(3) + token(4, used=55)
        self.append(path, extra)
        got, _ = self.assertMatchesFullScan()
        self.assertEqual(sum(self.parsed), len(extra))
        self.assertEqual(got[1]['n'], 4)
        self.assertEqual(self.index()['files']['2026/10/11/rollout-a.jsonl']['offset'], path.stat().st_size)

    def test_same_size_and_larger_rewrites_are_reparsed(self):
        path = self.day / 'rollout-a.jsonl'
        meta = (json.dumps({'type': 'session_meta', 'payload': {'pad': 'x' * 400}}) + '\n').encode()
        path.write_bytes(meta + token(1, used=40))
        self.assertMatchesFullScan()
        inode = path.stat().st_ino
        # Same inode, same size, same first 256 bytes: only the tail fingerprint differs.
        with path.open('r+b') as stream:
            stream.write(meta + token(1, used=41))
        self.assertEqual(path.stat().st_ino, inode)
        got, _ = self.assertMatchesFullScan()
        self.assertEqual(sum(self.parsed), path.stat().st_size)
        self.assertEqual(got[1]['primary']['used_percent'], 41)
        # Same inode, larger, different head.
        size = path.stat().st_size
        path.write_bytes(token(7, used=12) + meta + token(6))
        self.assertEqual(path.stat().st_ino, inode)
        self.assertGreater(path.stat().st_size, size)
        got, _ = self.assertMatchesFullScan()
        self.assertEqual(sum(self.parsed), path.stat().st_size)
        self.assertEqual(got[1]['n'], 7)
        # Replaced by a new inode with an identical prefix: reparsed too.
        replacement = self.day / 'rollout-a.tmp'
        replacement.write_bytes(token(7, used=12) + meta + token(6) + token(8))
        os.replace(replacement, path)
        got, _ = self.assertMatchesFullScan()
        self.assertEqual(sum(self.parsed), path.stat().st_size)
        self.assertEqual(got[1]['n'], 8)

    def test_truncation_is_reparsed(self):
        path = self.day / 'rollout-a.jsonl'
        first = token(1)
        path.write_bytes(first + token(2, used=90))
        self.assertEqual(self.assertMatchesFullScan()[0][1]['n'], 2)
        with path.open('r+b') as stream:
            stream.truncate(len(first))
        got, _ = self.assertMatchesFullScan()
        self.assertEqual(got[1]['n'], 1)
        self.assertEqual(sum(self.parsed), len(first))
        path.write_bytes(b'')
        self.assertEqual(self.assertMatchesFullScan()[0][2], 'missing usage source')

    def test_deleted_file_is_dropped(self):
        a, b = self.day / 'rollout-a.jsonl', self.day / 'rollout-b.jsonl'
        a.write_bytes(token(1))
        b.write_bytes(token(5))
        self.assertEqual(self.assertMatchesFullScan()[0][1]['n'], 5)
        self.assertEqual(set(self.index()['files']), {'2026/10/11/rollout-a.jsonl', '2026/10/11/rollout-b.jsonl'})
        b.unlink()
        self.assertEqual(self.assertMatchesFullScan()[0][1]['n'], 1)
        self.assertEqual(set(self.index()['files']), {'2026/10/11/rollout-a.jsonl'})
        a.unlink()
        self.assertEqual(self.assertMatchesFullScan()[0][2], 'missing usage source')
        self.assertEqual(self.index()['files'], {})

    def test_trailing_partial_line_is_damaged_then_completed(self):
        path = self.day / 'rollout-a.jsonl'
        line = token(3)
        path.write_bytes(line[:40])
        got, damaged = self.assertMatchesFullScan()
        self.assertEqual(got[2], 'malformed or unreadable source')
        self.assertTrue(damaged)
        self.assertFalse(self.index_path().exists())   # nothing committed yet
        self.append(path, line[40:-1])                   # complete JSON, still no newline
        got, damaged = self.assertMatchesFullScan()
        self.assertEqual(got[1]['n'], 3)
        self.assertFalse(damaged)
        self.assertFalse(self.index_path().exists())
        self.append(path, b'\n' + token(4)[:25])
        got, damaged = self.assertMatchesFullScan()
        self.assertEqual(got[1]['n'], 3)
        self.assertTrue(damaged)
        self.assertEqual(self.index()['files']['2026/10/11/rollout-a.jsonl']['offset'], len(line))
        self.assertFalse(self.index()['files']['2026/10/11/rollout-a.jsonl']['damaged'])
        self.append(path, token(4)[25:])
        got, damaged = self.assertMatchesFullScan()
        self.assertEqual(got[1]['n'], 4)
        self.assertFalse(damaged)
        self.assertEqual(sum(self.parsed), len(token(4)))

    def test_damaged_prefix_is_sticky(self):
        path = self.day / 'rollout-a.jsonl'
        path.write_bytes(b'invalid\xff\n' + token(1))
        self.assertTrue(self.assertMatchesFullScan()[1])
        self.append(path, token(2))
        got, damaged = self.assertMatchesFullScan()
        self.assertTrue(damaged)
        self.assertEqual(sum(self.parsed), len(token(2)))
        # A bad timestamp is damage, and an invalid newer sample never wins.
        bad = json.loads(token(9))
        bad['timestamp'] = '2026-10-11T13:00:00'
        self.append(path, (json.dumps(bad) + '\n').encode())
        got, damaged = self.assertMatchesFullScan()
        self.assertEqual(got[1]['n'], 2)
        self.assertTrue(damaged)

    def test_equal_timestamps_resolve_like_a_full_scan(self):
        same = BASE + dt.timedelta(seconds=30)
        a = self.day / 'rollout-a.jsonl'
        b = self.sessions / '2026/10/12/rollout-b.jsonl'
        b.parent.mkdir(parents=True)
        a.write_bytes(token(1, when=same))
        b.write_bytes(token(2, when=same))
        self.assertMatchesFullScan()
        self.append(a, token(3, when=same))
        self.assertMatchesFullScan()
        self.assertEqual(sum(self.parsed), len(token(3, when=same)))
        self.append(b, token(4, when=same - dt.timedelta(seconds=1)))
        self.assertMatchesFullScan()
        # Within one file the later of two equal samples wins across the
        # committed/appended boundary.
        c = self.sessions / '2026/10/13/rollout-c.jsonl'
        c.parent.mkdir(parents=True)
        later = same + dt.timedelta(seconds=5)
        c.write_bytes(token(5, when=later))
        self.assertEqual(self.assertMatchesFullScan()[0][1]['n'], 5)
        self.append(c, token(6, when=later))
        self.assertEqual(self.assertMatchesFullScan()[0][1]['n'], 6)

    def test_corrupt_foreign_and_unwritable_index_fall_back(self):
        path = self.day / 'rollout-a.jsonl'
        path.write_bytes(token(1) + token(2))
        self.assertMatchesFullScan()
        for bad in [b'{not json', b'[]', b'{"schema_version": 2, "files": {}}',
                    json.dumps({'schema_version': 1, 'root': '/elsewhere', 'files': {}}).encode(),
                    json.dumps({'schema_version': True, 'root': str(self.sessions.resolve()), 'files': {}}).encode(),
                    json.dumps({'schema_version': 1, 'root': str(self.sessions.resolve()), 'files': {
                        '2026/10/11/rollout-a.jsonl': {'offset': 'x', 'inode': [], 'best': 7}}}).encode(),
                    json.dumps({'schema_version': 1, 'root': str(self.sessions.resolve()), 'files': {
                        '2026/10/11/rollout-a.jsonl': dict(self.index()['files']['2026/10/11/rollout-a.jsonl'],
                                                           best=['not a time', {}])}}).encode(),
                    b'\xff\xfe']:
            with self.subTest(bad=bad[:40]):
                self.index_path().write_bytes(bad)
                self.assertMatchesFullScan()
                self.assertEqual(sum(self.parsed), path.stat().st_size)
                self.assertEqual(self.index()['schema_version'], 1)   # rebuilt
        # A forged fingerprint match with a wrong inode is not trusted either.
        index = self.index()
        index['files']['2026/10/11/rollout-a.jsonl']['inode'] += 1
        self.index_path().write_text(json.dumps(index))
        self.assertMatchesFullScan()
        self.assertEqual(sum(self.parsed), path.stat().st_size)
        if os.geteuid() != 0:
            folder = self.index_path().parent
            self.index_path().unlink()
            folder.chmod(0o500)
            self.addCleanup(folder.chmod, 0o700)
            self.append(path, token(3))
            self.assertMatchesFullScan()
            self.assertMatchesFullScan()
            self.assertEqual(list(folder.iterdir()), [])
            folder.chmod(0o700)
        # Cache root is a file, or relative: full scan, nothing written.
        for value in [str(self.tmp / 'plain-file'), 'relative-cache']:
            with self.subTest(cache=value):
                (self.tmp / 'plain-file').write_text('')
                with mock.patch.dict(os.environ, {'XDG_CACHE_HOME': value}):
                    cwd = os.getcwd()
                    os.chdir(self.tmp)
                    try:
                        self.assertMatchesFullScan()
                    finally:
                        os.chdir(cwd)
                self.assertFalse((self.tmp / 'relative-cache').exists())

    def test_unreadable_file_is_damaged_and_not_indexed(self):
        if os.geteuid() == 0:
            self.skipTest('root reads every file')
        path = self.day / 'rollout-a.jsonl'
        path.write_bytes(token(1))
        self.assertMatchesFullScan()
        path.chmod(0)
        self.addCleanup(path.chmod, 0o600)
        got, damaged = self.assertMatchesFullScan()
        self.assertEqual(got[2], 'malformed or unreadable source')
        self.assertTrue(damaged)
        self.assertEqual(self.index()['files'], {})

    def test_report_is_identical_to_full_scan(self):
        path = self.day / 'rollout-a.jsonl'
        path.write_bytes(token(1) + token(2, used=77))
        now = BASE + dt.timedelta(seconds=900)
        with mock.patch.object(usage, 'codex_observation', lambda root: reference(root)[0]):
            want = usage.inspect_usage('codex', source=self.sessions, now=now)
        for _ in range(2):   # cold, then warm
            self.assertEqual(usage.inspect_usage('codex', source=self.sessions, now=now), want)
        self.assertEqual(usage.inspect_usage('codex', now=now), want)   # default CODEX_HOME root

    def test_concurrent_callers_never_leave_a_half_index(self):
        path = self.day / 'rollout-a.jsonl'
        path.write_bytes(token(0))
        context = multiprocessing.get_context('fork')
        workers = [context.Process(target=_hammer, args=(str(self.sessions), str(self.cache), 15))
                   for _ in range(4)]
        for worker in workers:
            worker.start()
        for n in range(1, 40):
            self.append(path, token(n))
        for worker in workers:
            worker.join(60)
            self.assertEqual(worker.exitcode, 0)
        self.assertEqual(self.index()['schema_version'], 1)
        self.assertMatchesFullScan()
        self.assertEqual(self.assertMatchesFullScan()[0][1]['n'], 39)
        self.assertEqual([p.name for p in self.index_path().parent.iterdir()], [self.index_path().name])

    def test_differential_against_full_scan(self):
        seed = int(os.environ.get('NOGG_SCAN_SEED', '20261029'))
        rng = random.Random(seed)
        stamps = [BASE + dt.timedelta(seconds=s) for s in range(0, 40, 3)]
        counter = [0]

        def line():
            counter[0] += 1
            kind = rng.random()
            end = rng.choice([b'\n'] * 6 + [b'\r\n', b'\r'])
            if kind < 0.45:
                when = rng.choice(stamps)
                stamp = usage.iso(when) if rng.random() < 0.8 else when.timestamp()
                body = json.dumps({'type': 'event_msg', 'timestamp': stamp,
                                   'payload': {'type': 'token_count',
                                               'rate_limits': {'n': counter[0], 'é': 'ü'}}},
                                  ensure_ascii=rng.random() < 0.5).encode()
            elif kind < 0.55:
                body = json.dumps({'type': 'event_msg', 'timestamp': '2026-10-11T12:00:00',
                                   'payload': {'type': 'token_count', 'rate_limits': {'n': counter[0]}}}).encode()
            elif kind < 0.62:
                body = json.dumps({'type': 'event_msg', 'timestamp': usage.iso(BASE),
                                   'payload': {'type': 'token_count', 'rate_limits': None}}).encode()
            elif kind < 0.75:
                body = b'{"type":"response_item","payload":"\xff\xe2\x82 transcript"}'
            elif kind < 0.82:
                body = rng.choice([b'garbage', b'\xff{}', b'', b'{"type": "event_msg"'])
            else:
                body = json.dumps({'type': 'response_item', 'payload': {'text': 'x' * rng.randrange(600)}}).encode()
            return body + end

        files = {}
        created = 0
        for chunk in [7, 64, 1 << 20]:
            with self.subTest(chunk=chunk), mock.patch.object(usage, 'CODEX_SCAN_CHUNK', chunk):
                for _ in range(30):
                    action = rng.random()
                    if action < 0.12 or not files:
                        folder = self.sessions / f'2026/10/{rng.randrange(11, 14)}'
                        folder.mkdir(parents=True, exist_ok=True)
                        created += 1
                        path = folder / f'rollout-{created}.jsonl'
                        files[path] = None
                        path.write_bytes(b'')
                    path = rng.choice(sorted(files))
                    if not path.exists():
                        path.write_bytes(b'')
                    if action < 0.70:
                        data = b''.join(line() for _ in range(rng.randrange(1, 6)))
                        if rng.random() < 0.3:
                            data = data[:rng.randrange(1, len(data) + 1)]   # partial line
                        self.append(path, data)
                    elif action < 0.78:
                        with path.open('r+b') as stream:
                            stream.truncate(rng.randrange(0, max(path.stat().st_size, 1)))
                    elif action < 0.86:
                        content = path.read_bytes()
                        with path.open('r+b') as stream:   # in-place same-size edit
                            stream.write(bytes(reversed(content)))
                    elif action < 0.92:
                        temporary = path.with_suffix('.tmp')
                        temporary.write_bytes(b''.join(line() for _ in range(3)))
                        os.replace(temporary, path)
                    else:
                        path.unlink()
                        del files[path]
                    self.assertMatchesFullScan()
                    self.assertMatchesFullScan()   # warm and unchanged: only trailing partial lines
                    partial = 0
                    for each in files:
                        content = each.read_bytes()
                        partial += len(content) - (content.rfind(b'\n') + 1)
                    self.assertEqual(sum(self.parsed), partial)


unittest.main(verbosity=1)
PY
