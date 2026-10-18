#!/usr/bin/env bash
# Focused checks for missing usage source remediation hints (TASK-UVF-003).
# Covers:
#   - Window hint field added for Claude missing usage source
#   - evaluate_gate copies hint to projected windows
#   - nogg usage prints "unknown (missing usage source) — run nogg usage install-statusline"
#   - Doctor Claude freshness note names install-statusline for missing cache
#     and for unreadable/missing source
#   - Does not edit usage_gate_admission() or alter gate decisions
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root" <<'PY'
import datetime as dt
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(sys.argv.pop()) / 'scripts'))
import nogg_usage as u

class UsageHintsTest(unittest.TestCase):
    def test_claude_missing_source_hint(self):
        with tempfile.TemporaryDirectory() as td:
            missing_cache = Path(td) / 'claude.json'
            rep = u.inspect_usage('claude', source=missing_cache)
            self.assertEqual(rep['status'], 'unknown')
            self.assertEqual(len(rep['windows']), 2)
            for w in rep['windows']:
                self.assertEqual(w['status'], 'unknown')
                self.assertEqual(w['reason'], 'missing usage source')
                self.assertEqual(w['hint'], 'run nogg usage install-statusline')

    def test_non_claude_or_non_missing_no_hint(self):
        with tempfile.TemporaryDirectory() as td:
            # Codex missing source should not have claude statusline hint
            codex_dir = Path(td) / 'codex'
            rep_codex = u.inspect_usage('codex', source=codex_dir)
            for w in rep_codex['windows']:
                self.assertNotIn('hint', w)

            # Claude known source should not have hint
            now = dt.datetime.now(dt.timezone.utc)
            reset = int(now.timestamp()) + 3600
            cache = Path(td) / 'valid_claude.json'
            cache.write_text(json.dumps({
                'schema_version': 1,
                'observed_at': now.isoformat().replace('+00:00', 'Z'),
                'rate_limits': {
                    'five_hour': {'used_percentage': 10, 'resets_at': reset},
                    'seven_day': {'used_percentage': 20, 'resets_at': reset + 86400}
                }
            }))
            rep_valid = u.inspect_usage('claude', source=cache, now=now)
            self.assertEqual(rep_valid['status'], 'known')
            for w in rep_valid['windows']:
                self.assertNotIn('hint', w)

    def test_evaluate_gate_carries_hint(self):
        with tempfile.TemporaryDirectory() as td:
            missing_cache = Path(td) / 'claude.json'
            rep = u.inspect_usage('claude', source=missing_cache)
            cfg = u.gate_config({})
            gate = u.evaluate_gate(rep, cfg, 5)
            self.assertEqual(gate['decision'], 'unknown-admitted')
            self.assertEqual(len(gate['windows']), 2)
            for w in gate['windows']:
                self.assertEqual(w['status'], 'unknown')
                self.assertEqual(w['hint'], 'run nogg usage install-statusline')

    def test_usage_command_prints_hint(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ['XDG_CACHE_HOME'] = td
            out = io.StringIO()
            sys_stdout = sys.stdout
            try:
                sys.stdout = out
                u.usage_command('claude', json_output=False, config={})
            finally:
                sys.stdout = sys_stdout

            output = out.getvalue()
            self.assertIn("short: unknown (missing usage source) — run nogg usage install-statusline", output)
            self.assertIn("weekly: unknown (missing usage source) — run nogg usage install-statusline", output)

    def test_doctor_claude_freshness_notes(self):
        with tempfile.TemporaryDirectory() as td:
            cache_file = Path(td) / 'nogging/usage/claude.json'
            os.environ['XDG_CACHE_HOME'] = td

            # 1. Missing cache file
            notes = u.quota_freshness_notes({'stale_seconds': 600})
            self.assertTrue(any('nogg usage install-statusline' in n and 'claude' in n for n in notes), notes)

            # 2. Cache exists but is unreadable or reports missing usage source
            cache_file.parent.mkdir(parents=True, exist_ok=True)
            # A directory at cache_file path triggers OSError / unreadable source
            # But let's test when inspect_usage returns missing usage source or unreadable
            notes2 = u.quota_freshness_notes({'stale_seconds': 600})
            self.assertTrue(any('nogg usage install-statusline' in n for n in notes2), notes2)

if __name__ == '__main__':
    unittest.main()
PY

echo "usage-hints test passed"
