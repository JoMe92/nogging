#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$root" <<'PY'
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(sys.argv.pop())/'scripts'))
import nogg_usage as usage

class UsageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.now = dt.datetime(2026, 10, 11, 12, tzinfo=dt.timezone.utc)
        self.reset = int(self.now.timestamp()) + 3600
        self.row = {'type':'event_msg', 'timestamp':usage.iso(self.now),
                    'payload':{'type':'token_count', 'rate_limits':{
                        'limit_id':'codex',
                        'primary':{'used_percent':40, 'window_minutes':300, 'resets_at':self.reset},
                        'secondary':{'used_percent':99, 'window_minutes':10080, 'resets_at':self.reset+600000}}}}
        self.path = self.root/'2026/10/11/rollout-test.jsonl'
        self.path.parent.mkdir(parents=True)
        self.write()
    def write(self):
        self.path.write_text(json.dumps(self.row)+'\n')
    def inspect(self, **kwargs):
        return usage.inspect_usage('codex', source=self.root, now=self.now, **kwargs)
    def test_both_windows_and_no_leaks(self):
        self.row['payload']['rate_limits']['credits']={'token':'SECRET'}
        self.write()
        with self.path.open('a') as stream:
            stream.write(json.dumps({'type':'response_item','payload':{'text':'TRANSCRIPT SECRET'}})+'\n')
        report = self.inspect()
        self.assertEqual(report['status'], 'known')
        self.assertEqual([w['used_percent'] for w in report['windows']], [40,99])
        self.assertNotIn('SECRET', json.dumps(report))
        self.assertNotIn(str(self.root), json.dumps(report))
        self.assertIsNone(report['account'])
    def test_timezone_stale_future_and_reset(self):
        self.row['timestamp']='2026-10-11T14:00:00+02:00'; self.write()
        self.assertEqual(self.inspect()['status'],'known')
        self.now += dt.timedelta(seconds=601)
        self.assertEqual(self.inspect()['windows'][0]['reason'],'stale observation')
        self.now -= dt.timedelta(seconds=602)
        self.assertEqual(self.inspect()['status'],'unknown')
        self.now += dt.timedelta(seconds=3601)
        self.assertIn('reset elapsed',self.inspect(stale_after=7200)['windows'][0]['reason'])
    def test_invalid_windows_and_partial(self):
        for invalid in [-1,101,True,'0',float('nan'),float('inf'),None]:
            with self.subTest(invalid=invalid):
                self.row['payload']['rate_limits']['primary']['used_percent']=invalid;self.write()
                report=self.inspect()
                self.assertEqual(report['windows'][0]['status'],'unknown')
                self.assertIsNone(report['windows'][0]['used_percent'])
                self.assertEqual(report['windows'][1]['status'],'known')
        del self.row['payload']['rate_limits']['primary']; self.write()
        self.assertEqual(self.inspect()['status'],'unknown')
    def test_newest_metadata_wins(self):
        newer=json.loads(json.dumps(self.row))
        newer['timestamp']=usage.iso(self.now+dt.timedelta(seconds=1))
        newer['payload']['rate_limits']['secondary']={}
        other=self.path.with_name('rollout-new.jsonl');other.write_text(json.dumps(newer)+'\n')
        os.utime(self.path,(2000000000,2000000000))
        self.now+=dt.timedelta(seconds=1)
        self.assertEqual(self.inspect()['windows'][1]['status'],'unknown')
    def test_missing_malformed_and_non_utf8_transcript(self):
        self.path.unlink()
        self.assertEqual(self.inspect()['windows'][0]['reason'],'missing usage source')
        self.path.write_bytes(b'invalid\xff\n')
        self.assertEqual(self.inspect()['status'],'unknown')
        self.write()
        with self.path.open('ab') as stream:stream.write(b'{"type":"response_item","payload":"\xff"}\n')
        self.assertEqual(self.inspect()['status'],'known')
    def test_claude_cache(self):
        cache=self.root/'claude.json'
        row={'schema_version':1,'observed_at':usage.iso(self.now),'rate_limits':{
            'five_hour':{'used_percentage':25,'resets_at':self.reset},
            'seven_day':{'used_percentage':100,'resets_at':self.reset+600000}},
            'transcript':'SECRET'}
        cache.write_text(json.dumps(row))
        report=usage.inspect_usage('claude',source=cache,now=self.now)
        self.assertEqual(report['status'],'known')
        self.assertEqual(report['windows'][1]['used_percent'],100)
        self.assertNotIn('SECRET',json.dumps(report))
        for bad in [{},[],{'schema_version':2}, {'schema_version':1,'observed_at':'2026-10-11T12:00:00'}]:
            cache.write_text(json.dumps(bad))
            self.assertEqual(usage.inspect_usage('claude',source=cache,now=self.now)['status'],'unknown')
    def test_installed_payload(self):
        repo=Path(usage.__file__).parents[1]
        manifest=(repo/'bin/lib/manifest.js').read_text()
        self.assertIn("'scripts/nogg_usage.py'",manifest)
        installed=self.root/'consumer'
        (installed/'scripts').mkdir(parents=True)
        (installed/'.nogging').mkdir()
        (installed/'.nogging/config.json').write_text('{}')
        for name in ['nogg','nogg_usage.py']:
            shutil.copy2(repo/'scripts'/name,installed/'scripts'/name)
        env=dict(os.environ,CODEX_HOME=str(self.root/'absent'))
        env.pop('NOGGING_ROOT',None)
        env.pop('PYTHONDONTWRITEBYTECODE',None)
        result=subprocess.run([str(installed/'scripts/nogg'),'usage','--json'],env=env,text=True,capture_output=True,check=True)
        self.assertEqual(json.loads(result.stdout)['status'],'unknown')
        self.assertFalse((installed/'scripts/__pycache__').exists())

    def test_cli_read_only(self):
        # Real CLI, isolated local sources, no session/lock/cache creation.
        repo=Path(usage.__file__).parents[1]
        env=dict(os.environ,CODEX_HOME=str(self.root/'missing'),XDG_CACHE_HOME=str(self.root/'missing'))
        before=sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
        for agent in ['claude','codex']:
            result=subprocess.run([str(repo/'scripts/nogg'),'usage','--agent',agent,'--json'],env=env,text=True,capture_output=True,check=True)
            self.assertEqual(json.loads(result.stdout)['status'],'unknown')
            self.assertNotIn('SECRET',result.stdout+result.stderr)
        self.assertEqual(before,sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*')))

unittest.main()
PY
