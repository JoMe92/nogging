#!/usr/bin/env python3
"""Tests of the Bead detail's server side (TASK-DSH-006): `dashboard_model.bead_detail` and
/api/v1/beads/<id>. Small tests run on the model; the medium tests read the route of a real
server on 127.0.0.1 with a stub `bd` and readers that return fixed snapshots, so they need no
Git, no Dolt and no sleep. How the view renders is covered by the live acceptance."""
from __future__ import annotations

import json, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_model as model
from dashboard_data_test import ADDRESS, Live, bead
from dashboard_sources import read_beads

MARKUP = "<script>alert(1)</script>"


def listed(identifier, **extra):
    return model.allow_bead(bead(identifier, **extra))


def dep(issue, on, kind="blocks"):
    return {"issue_id": issue, "depends_on_id": on, "type": kind, "created_at": "2026-10-01T10:00:00Z"}


def commit(sha, at, beads, production=10, test=5):
    return {"sha": sha, "at": at, "subject": f"feat: step [{beads[0]}]", "beads": beads,
            "production_lines": production, "test_lines": test}


def state(name, value="fresh"):
    return {name: {"state": value, "as_of": "2026-11-01T10:00:00Z", "generation": 1}}


GIT = {"commits": [commit("b" * 40, "2026-10-02T10:00:00Z", ["SPEC-aaaa"], 30, 12),
                   commit("a" * 40, "2026-10-01T10:00:00Z", ["SPEC-aaaa"], 20, 8),
                   commit("c" * 40, "2026-10-03T10:00:00Z", ["SPEC-other"], 99, 99)],
       "root_commit_at": "2026-09-01T00:00:00Z", "floor": "2026-10-01T10:00:00Z", "tokenless_commits": 3}
SESSIONS = {"sessions": [model.allow_session({"name": "nogging-lead-1", "agent": "claude", "bead_id": "SPEC-aaaa",
                                              "started_at": "2026-10-01T10:00:00Z", "ended_at": "2026-10-01T11:00:00Z",
                                              "exit_reason": "done\nlong startup log", "command": "secret --flag"}),
                         model.allow_session({"name": "nogging-lead-2", "bead_id": "SPEC-other"})],
            "floor": "2026-09-20T00:00:00Z"}
WORK = {"tokens": {"total_tokens": 1200}, "unknown_counters": {}}
TOKENS = {"by_bead": {"SPEC-aaaa": WORK}, "by_day": {}, "by_model": {}, "floors": {"claude": "2026-09-01T00:00:00Z"},
          "partial": [], "pending_batches": 0}
TESTS = {"records": [{"bead": "SPEC-aaaa", "stage": "bead", "at": "2026-10-01T10:30:00Z", "seconds": 12.5, "status": "passed"}],
         "stage_seconds": {"SPEC-aaaa": {"changed": None, "commit": None, "bead": 12.5, "full": None}}, "floor": None}


def beads(*items, ready=()):
    return {"beads": list(items), "ready": list(ready), "cycles": []}


class Detail(unittest.TestCase):
    def snapshots(self, **extra):
        base = {"beads": beads(listed("SPEC-aaaa", dependencies=[dep("SPEC-aaaa", "SPEC-up")]),
                               listed("SPEC-up", status="closed"),
                               listed("SPEC-down1", dependencies=[dep("SPEC-down1", "SPEC-aaaa")]),
                               listed("SPEC-down2", status="in_progress", dependencies=[dep("SPEC-down2", "SPEC-aaaa")]),
                               ready=["SPEC-aaaa"]),
                "git": GIT, "sessions": SESSIONS, "tokens": TOKENS, "tests": TESTS}
        return {**base, **extra}

    def statuses(self, **extra):
        found = {}
        for name in ("beads", "git", "sessions", "tokens", "tests"):
            found.update(state(name))
        return {**found, **extra}

    def test_a_bead_with_commits_lists_each_once_with_its_lines(self):
        detail = model.bead_detail(self.snapshots(), "SPEC-aaaa", self.statuses())
        block = detail["commits"]
        self.assertEqual([item["sha"][0] for item in block["commits"]], ["a", "b"])   # oldest first, no other Bead's
        self.assertEqual((block["production_lines"], block["test_lines"]), (50, 20))
        self.assertEqual(set(block["commits"][0]), {"sha", "at", "subject", "production_lines", "test_lines"})
        self.assertEqual((block["source"], block["state"], block["available"]), ("git", "fresh", True))
        self.assertEqual(detail["bead"]["id"], "SPEC-aaaa")
        self.assertTrue(detail["bead"]["ready"])
        self.assertEqual(detail["bead"]["change"], "demo")
        self.assertEqual(detail["bead"]["notes"], "ask [address] about it")

    def test_a_bead_without_sessions_says_the_records_are_host_local(self):
        sessions = {"sessions": [item for item in SESSIONS["sessions"] if item["bead_id"] != "SPEC-aaaa"], "floor": None}
        block = model.bead_detail(self.snapshots(sessions=sessions), "SPEC-aaaa", self.statuses())["sessions"]
        self.assertEqual((block["sessions"], block["scope"], block["available"]), ([], "host", True))

    def test_a_session_has_exactly_the_allow_listed_fields(self):
        block = model.bead_detail(self.snapshots(), "SPEC-aaaa", self.statuses())["sessions"]
        self.assertEqual([item["name"] for item in block["sessions"]], ["nogging-lead-1"])
        self.assertEqual(set(block["sessions"][0]), set(model.SESSION_FIELDS))
        self.assertEqual(block["sessions"][0]["exit_reason"], "done")

    def test_both_directions_are_listed_with_their_status(self):
        deps = model.bead_detail(self.snapshots(), "SPEC-aaaa", self.statuses())["dependencies"]
        self.assertEqual([(item["id"], item["status"]) for item in deps["depends_on"]], [("SPEC-up", "closed")])
        self.assertEqual([(item["id"], item["status"]) for item in deps["blocks"]],
                         [("SPEC-down1", "open"), ("SPEC-down2", "in_progress")])

    def test_a_dependency_on_a_bead_that_is_gone_keeps_its_id(self):
        snapshots = self.snapshots(beads=beads(listed("SPEC-aaaa", dependencies=[dep("SPEC-aaaa", "SPEC-gone")])))
        deps = model.bead_detail(snapshots, "SPEC-aaaa", self.statuses())["dependencies"]
        self.assertEqual(deps["depends_on"], [{"id": "SPEC-gone", "title": None, "status": None, "type": "blocks"}])

    def test_each_block_carries_the_state_of_its_own_source(self):
        statuses = self.statuses(tokens={"state": "stale", "as_of": "2026-11-01T09:00:00Z", "generation": 4})
        detail = model.bead_detail(self.snapshots(), "SPEC-aaaa", statuses)
        self.assertEqual((detail["tokens"]["state"], detail["tokens"]["as_of"]), ("stale", "2026-11-01T09:00:00Z"))
        self.assertEqual(detail["tokens"]["work"], WORK)
        for name in ("commits", "sessions", "tests"):
            self.assertEqual(detail[name]["state"], "fresh", name)

    def test_a_missing_source_is_unavailable_and_never_an_empty_list(self):
        snapshots = self.snapshots(git=None, tokens=None)
        detail = model.bead_detail(snapshots, "SPEC-aaaa", self.statuses(git={"state": "loading", "as_of": None, "generation": 0}))
        self.assertEqual(detail["commits"], {"source": "git", "state": "loading", "as_of": None, "available": False})
        self.assertEqual((detail["tokens"]["available"], "work" in detail["tokens"]), (False, False))
        self.assertEqual(model.bead_detail(snapshots, "SPEC-aaaa")["tests"]["available"], True)
        self.assertEqual(model.bead_detail(snapshots, "SPEC-aaaa")["commits"]["state"], "absent")

    def test_a_bead_with_no_usage_has_no_work_and_a_fresh_source(self):
        detail = model.bead_detail(self.snapshots(), "SPEC-up", self.statuses())
        self.assertEqual((detail["tokens"]["state"], detail["tokens"]["work"]), ("fresh", None))
        self.assertEqual((detail["tests"]["runs"], detail["tests"]["stage_seconds"]), (0, None))

    def test_the_detail_leaves_out_every_private_field(self):
        text = json.dumps(model.bead_detail(self.snapshots(), "SPEC-aaaa", self.statuses()))
        for needle in (ADDRESS, "Nogging Orchestrator", "secret --flag", "owner", "assignee", "created_by", "command"):
            self.assertNotIn(needle, text)

    def test_an_unknown_bead_and_a_missing_snapshot(self):
        self.assertIsNone(model.bead_detail(self.snapshots(), "SPEC-nope"))
        self.assertEqual(model.bead_detail({"beads": None}, "SPEC-aaaa"), {"bead": None, "dependencies": None})


class Route(Live):
    def start_with(self, **extra):
        readers = {"beads": lambda: read_beads(str(self.bd), self.home), **{name: (lambda value=value: value)
                                                                               for name, value in extra.items()}}
        refresher = self.start(readers)
        self.load(refresher, rounds=1 + len(extra))
        return refresher

    def test_an_unknown_bead_is_a_plain_404_with_no_echo(self):
        self.start_with()
        status, doc = self.get("/api/v1/beads/SPEC-nope")
        self.assertEqual((status, doc["data"]), (404, {"error": "not_found"}))
        self.assertNotIn("SPEC-nope", json.dumps(doc))

    def test_a_known_bead_is_served_with_its_blocks_and_every_source(self):
        self.start_with(git=GIT, sessions=SESSIONS)
        status, doc = self.get("/api/v1/beads/SPEC-aaaa")
        self.assertEqual((status, doc["schema"]), (200, "nogg.dashboard.bead/v1"))
        self.assertEqual(doc["data"]["bead"]["id"], "SPEC-aaaa")
        self.assertEqual([item["sha"][0] for item in doc["data"]["commits"]["commits"]], ["a", "b"])
        self.assertEqual(doc["data"]["sessions"]["sessions"][0]["name"], "nogging-lead-1")
        for name in ("tests", "tokens"):                   # no reader in this process: absent, not empty
            self.assertEqual((doc["sources"][name]["state"], doc["data"][name]["available"]), ("absent", False), name)
        self.assertEqual(doc["data"]["commits"]["state"], doc["sources"]["git"]["state"])

    def test_the_bead_before_its_list_has_loaded_is_a_200_with_the_loading_state(self):
        self.start()
        status, doc = self.get("/api/v1/beads/SPEC-aaaa")
        self.assertEqual((status, doc["data"]["bead"], doc["sources"]["beads"]["state"]), (200, None, "loading"))

    def test_a_note_with_markup_is_returned_as_raw_text(self):
        self.answer("list", [bead("SPEC-aaaa", notes=f"{MARKUP}\nsecond line", description=MARKUP, close_reason=MARKUP)])
        self.start_with()
        status, doc = self.get("/api/v1/beads/SPEC-aaaa")
        self.assertEqual(status, 200)
        self.assertEqual(doc["data"]["bead"]["notes"], f"{MARKUP}\nsecond line")
        self.assertEqual(doc["data"]["bead"]["description"], MARKUP)
        self.assertEqual(doc["data"]["bead"]["close_reason"], MARKUP)

    def test_a_request_for_a_detail_spawns_nothing(self):
        self.start_with(git=GIT)
        before = len(self.calls())
        for _ in range(5):
            self.get("/api/v1/beads/SPEC-aaaa")
            self.get("/api/v1/beads/SPEC-nope")
        self.assertEqual(len(self.calls()), before)


if __name__ == "__main__":
    unittest.main()
