#!/usr/bin/env python3
"""Medium tests of the usage panels (7 to 11) in /api/v1/summary: a real server on 127.0.0.1
port 0, the real Bead loader and a stub `bd`. The statistics themselves are tested in
dashboard_usage_metrics_test.py."""
from __future__ import annotations

import ast, json, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_cache as cache
import dashboard_data_test as data
import dashboard_sources as sources

PATH = "/api/v1/summary?range=all"
NOGG = Path(__file__).resolve().parents[1] / "nogg"
WORK = {"tokens": {"fresh_input_tokens": 100, "cache_read_tokens": 0, "cache_write_tokens": 0, "output_tokens": 20, "total_tokens": 120},
        "unknown_counters": {"fresh_input_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0, "output_tokens": 0, "total_tokens": 0}}
TOKENS = {"by_bead": {}, "by_model": {"claude-opus-5-5": WORK}, "by_day": {"2026-10-30": {"claude": WORK}},
          "floors": {"claude": "2026-10-30T08:00:00Z"}, "partial": [], "pending_batches": 0}
GIT = {"commits": [{"sha": "a1", "at": "2026-10-30T09:00:00Z", "subject": "feat: x [SPEC-aaaa]", "beads": ["SPEC-aaaa"],
                    "production_lines": 12, "test_lines": 7}],
       "root_commit_at": "2026-09-01T00:00:00Z", "floor": "2026-10-30T09:00:00Z", "tokenless_commits": 4}
SESSIONS = {"sessions": [{"name": "s1", "agent": "claude", "role": "lead", "bead_id": "SPEC-aaaa", "planning_id": None,
                          "requested_model": "claude-opus-5-5", "selection_tier": "complex",
                          "started_at": "2026-10-30T08:00:00Z", "ended_at": "2026-10-30T10:00:00Z"}],
            "floor": "2026-10-30T08:00:00Z"}


class UsagePanels(data.Live):
    def readers(self, **overrides):
        return {"beads": lambda: sources.read_beads(str(self.bd), self.home),
                "sessions": lambda: SESSIONS, "git": lambda: GIT, "tokens": lambda: TOKENS, **overrides}

    def loaded(self, **overrides):
        refresher = self.start(self.readers(**overrides))
        self.load(refresher, rounds=6)
        return refresher

    def test_every_usage_block_arrives_with_its_sources_fresh(self):
        self.loaded()
        status, doc = self.get(PATH)
        result = doc["data"]
        self.assertEqual(status, 200)
        self.assertEqual(result["agent_hours"]["hours"], 2.0)
        self.assertEqual(result["tokens"]["headline"]["known"], 120)
        self.assertEqual(result["commits"]["totals"]["production_lines"], 12)
        self.assertEqual(result["agents"]["observed"]["rows"][0]["model"], "claude-opus-5-5")
        for name in ("sessions", "git", "tokens"):
            self.assertEqual(doc["sources"][name]["state"], "fresh", name)

    def test_a_consumer_repository_without_test_records_reads_absent_not_zero(self):
        self.loaded(tests=lambda: (_ for _ in ()).throw(cache.Absent()))
        _, doc = self.get(PATH)
        self.assertEqual(doc["sources"]["tests"]["state"], "absent")
        self.assertEqual(doc["data"]["test_cost"], {"state": "absent"})

    def test_stale_tokens_keep_the_last_values_and_the_source_says_stale(self):
        calls = []

        def tokens():
            calls.append(1)
            if len(calls) > 1:
                raise cache.Busy()
            return TOKENS
        refresher = self.loaded(tokens=tokens)
        refresher.cells["tokens"].due = 0
        refresher.step()
        _, doc = self.get(PATH)
        self.assertEqual(len(calls), 2)
        self.assertEqual(doc["sources"]["tokens"]["state"], "stale")
        self.assertEqual(doc["sources"]["tokens"]["generation"], 1)
        self.assertEqual(doc["data"]["tokens"]["headline"]["known"], 120)     # the last values, not a gap

    def test_while_a_slow_source_loads_its_blocks_are_absent_and_the_state_says_loading(self):
        refresher = self.start(self.readers())
        status, doc = self.get(PATH)
        self.assertEqual(doc["sources"]["tokens"]["state"], "loading")
        self.assertEqual(doc["data"]["tokens"], {"state": "absent"})
        self.assertEqual(doc["data"]["commits"], {"state": "absent"})

    def test_no_private_field_reaches_the_usage_blocks(self):
        self.loaded()
        result = self.get(PATH)[1]["data"]
        text = json.dumps(result)
        for needle in (data.ADDRESS, "Nogging Orchestrator"):
            self.assertNotIn(needle, text)
        for needle in ("cost", "quota", "percent", "provider_total"):          # tokens carry no price or share
            self.assertNotIn(needle, json.dumps(result["tokens"]).lower())


class Wiring(unittest.TestCase):
    def test_the_dashboard_command_wires_every_reader_to_its_real_loader(self):
        tree = ast.parse(NOGG.read_text())
        function = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and node.name == "dashboard_readers")
        returned = next(node for node in ast.walk(function) if isinstance(node, ast.Return)).value
        wired = {key.value: ast.unparse(value) for key, value in zip(returned.keys, returned.values)}
        self.assertEqual(sorted(wired), ["beads", "git", "sessions", "tests", "tokens"])
        self.assertIn("read_git(", wired["git"])
        self.assertIn("read_tokens(", wired["tokens"])


if __name__ == "__main__":
    unittest.main()
