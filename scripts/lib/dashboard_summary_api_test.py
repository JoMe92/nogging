#!/usr/bin/env python3
"""Medium tests of /api/v1/summary: a real server on 127.0.0.1 port 0, the real Bead loader
and a stub `bd`. The statistics themselves are tested in dashboard_metrics_test.py."""
from __future__ import annotations

import json, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_cache as cache
import dashboard_data_test as data
import dashboard_sources as sources

PATH = "/api/v1/summary?range=all"


class Summary(data.Live):
    def loaded(self, readers=None):
        refresher = self.start(readers)
        self.load(refresher, rounds=5)
        return refresher

    def test_with_only_the_beads_source_the_others_are_absent_and_no_zero_appears(self):
        self.loaded()
        status, doc = self.get(PATH)
        self.assertEqual((status, doc["schema"]), (200, "nogg.dashboard.summary/v1"))
        self.assertEqual(doc["sources"]["beads"]["state"], "fresh")
        for name in ("sessions", "tests", "git", "tokens"):
            self.assertEqual(doc["sources"][name], {"state": "absent", "as_of": None, "generation": 0}, name)
        result = doc["data"]
        self.assertEqual(result["status"]["counts"]["open"], 2)
        self.assertEqual(result["status"]["counts"]["closed"], 1)
        self.assertEqual(result["project"]["root_commit_at"], None)
        self.assertEqual(result["project"]["basis"], "first_bead")
        series = result["activity"]["series"]
        for name in ("commits", "sessions", "tests"):
            self.assertEqual(series[name], {"state": "absent"}, name)
        self.assertEqual(series["created"]["state"], "ready")

    def test_an_absent_reader_is_absent_and_a_loaded_one_has_its_floor(self):
        self.answer("list", [data.bead("SPEC-aaaa", created_at="2026-10-30T10:00:00Z")])
        refresher = self.loaded({
            "beads": lambda: sources.read_beads(str(self.bd), self.home),
            "tests": lambda: (_ for _ in ()).throw(cache.Absent()),
            "sessions": lambda: {"sessions": [{"started_at": "2026-10-31T08:00:00Z"}], "floor": "2026-10-31T08:00:00Z"}})
        status, doc = self.get(PATH)
        self.assertEqual(doc["sources"]["tests"]["state"], "absent")
        self.assertEqual(doc["sources"]["sessions"]["state"], "fresh")
        series = doc["data"]["activity"]["series"]
        self.assertEqual(series["sessions"]["floor"], "2026-10-31")
        self.assertEqual(series["sessions"]["values"][0], None)           # before the floor: a gap
        self.assertEqual(series["tests"], {"state": "absent"})

    def test_while_loading_the_data_is_absent_and_the_state_says_loading(self):
        self.start()
        status, doc = self.get(PATH)
        self.assertEqual((status, doc["sources"]["beads"]["state"], doc["data"]["status"]), (200, "loading", {"state": "absent"}))

    def test_each_range_gets_its_own_answer_and_a_bad_one_is_refused(self):
        self.loaded()
        self.assertEqual(self.get("/api/v1/summary?range=7d")[1]["data"]["range"], "7d")
        self.assertEqual(self.get("/api/v1/summary")[1]["data"]["range"], "30d")
        for query in ("?range=forever", "?range=7d&range=30d", "?range=7d&x=1", "?range="):
            status, doc = self.get("/api/v1/summary" + query)
            self.assertEqual((status, doc["data"]), (400, {"error": "bad_request"}), query)

    def test_no_private_field_reaches_the_summary(self):
        self.loaded()
        text = json.dumps(self.get(PATH)[1])
        self.assertNotIn(data.ADDRESS, text)
        self.assertNotIn("Nogging Orchestrator", text)
        self.assertNotIn("Title of", text)

    def test_a_summary_request_spawns_nothing(self):
        self.loaded()
        before = len(self.calls())
        self.get(PATH)
        self.assertEqual(len(self.calls()), before)


if __name__ == "__main__":
    unittest.main()
