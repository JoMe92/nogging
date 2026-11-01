#!/usr/bin/env python3
"""Small tests of the usage panels (7 to 11) of the start page: pure functions over plain
snapshots. A missing source is absent and a missing period is a gap, never a zero."""
from __future__ import annotations

import sys, unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_metrics as metrics

NOW = datetime(2026, 11, 1, 12, 0, tzinfo=timezone.utc)


def session(name, started, ended=None, agent="claude", role="lead", bead="SPEC-aaaa", **extra):
    return {"name": name, "agent": agent, "role": role, "bead_id": bead, "planning_id": None,
            "requested_model": "claude-opus-5-5", "selection_tier": "complex",
            "started_at": started, "ended_at": ended, **extra}


def sessions(*items):
    starts = [item["started_at"] for item in items if item["started_at"]]
    return {"sessions": list(items), "floor": min(starts) if starts else None}


def work(fresh=0, output=0, unknown_fresh=0, unknown_output=0):
    zero = {key: 0 for key in ("fresh_input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens", "total_tokens")}
    return {"tokens": {**zero, "fresh_input_tokens": fresh, "output_tokens": output, "total_tokens": 999999},
            "unknown_counters": {**zero, "fresh_input_tokens": unknown_fresh, "output_tokens": unknown_output}}


def usage(**snapshots):
    full = {name: None for name in ("beads", "sessions", "tests", "git", "tokens")}
    full.update(snapshots)
    return metrics.summary_view(full, NOW, "all")


class AgentHours(unittest.TestCase):
    def test_the_orchestrator_session_is_reported_apart_and_not_in_the_headline(self):
        data = usage(sessions=sessions(
            session("lead-1", "2026-10-30T08:00:00Z", "2026-10-30T10:00:00Z"),
            session("orc", "2026-10-01T00:00:00Z", "2026-10-31T00:00:00Z", role="orchestrator", bead=None)))
        block = data["agent_hours"]
        self.assertEqual(block["hours"], 2.0)
        self.assertEqual(block["orchestrator"], {"hours": 720.0, "sessions": 1, "running": 0})
        self.assertEqual(sum(v for v in block["values"] if v), 2.0)

    def test_a_running_session_is_counted_and_adds_no_hours(self):
        data = usage(sessions=sessions(
            session("lead-1", "2026-10-30T08:00:00Z", "2026-10-30T09:00:00Z"),
            session("lead-2", "2026-10-31T08:00:00Z")))
        block = data["agent_hours"]
        self.assertEqual((block["running"], block["hours"], block["sessions"]), (1, 1.0, 1))

    def test_planning_sessions_count_in_the_hours_with_no_bead(self):
        data = usage(sessions=sessions(
            session("plan", "2026-10-30T08:00:00Z", "2026-10-30T10:30:00Z", role="planning", bead=None, planning_id="demo")))
        block = data["agent_hours"]
        self.assertEqual((block["hours"], block["planning_sessions"]), (2.5, 1))

    def test_days_before_the_first_session_are_a_gap_and_later_days_without_one_are_zero(self):
        block = usage(sessions=sessions(session("a", "2026-10-30T08:00:00Z", "2026-10-30T09:00:00Z"))
                      )["agent_hours"]
        self.assertEqual(block["days"][0], "2026-10-30")             # the whole history starts at the floor
        self.assertEqual(block["values"], [1.0, 0.0, 0.0])           # from the floor on: covered
        ranged = metrics.summary_view({"sessions": sessions(session("a", "2026-10-30T08:00:00Z", "2026-10-30T09:00:00Z"))},
                                      NOW, "30d")["agent_hours"]
        self.assertEqual(ranged["days"][0], "2026-10-03")             # the window opens before the floor
        self.assertEqual(ranged["values"][:27], [None] * 27)         # ... and those days are a gap
        self.assertEqual(ranged["values"][27], 1.0)

    def test_a_backwards_or_untimed_session_is_excluded_and_counted(self):
        block = usage(sessions=sessions(
            session("a", "2026-10-30T09:00:00Z", "2026-10-30T08:00:00Z"), session("b", None)))["agent_hours"]
        self.assertEqual(block["excluded"], {"untimed": 1, "backwards": 1})
        self.assertEqual(block["hours"], 0.0)

    def test_without_the_sessions_source_every_usage_block_it_feeds_is_absent(self):
        data = usage()
        for name in ("agent_hours", "tokens", "commits", "test_cost"):
            self.assertEqual(data[name], {"state": "absent"}, name)
        self.assertEqual(data["agents"]["state"], "absent")


class Agents(unittest.TestCase):
    def test_requested_and_observed_models_stay_apart(self):
        tokens = {"by_model": {"claude-opus-5-5-20261001": work(10, 5)}, "by_day": {}, "floors": {}, "partial": []}
        block = usage(sessions=sessions(session("a", "2026-10-30T08:00:00Z", "2026-10-30T09:00:00Z")), tokens=tokens)["agents"]
        row = block["requested"]["rows"][0]
        self.assertEqual((row["agent"], row["models"], row["tiers"]),
                         ("claude", [{"model": "claude-opus-5-5", "sessions": 1}], [{"tier": "complex", "sessions": 1}]))
        self.assertEqual(block["observed"]["rows"], [{"model": "claude-opus-5-5-20261001", "known": 15, "unknown": False}])

    def test_a_missing_tier_stays_unrecorded_and_not_a_guess(self):
        block = usage(sessions=sessions(session("a", "2026-10-30T08:00:00Z", "2026-10-30T09:00:00Z",
                                                selection_tier=None, requested_model=None)))["agents"]
        row = block["requested"]["rows"][0]
        self.assertEqual((row["models"], row["tiers"]), ([{"model": None, "sessions": 1}], [{"tier": None, "sessions": 1}]))
        self.assertEqual(block["observed"], {"state": "absent"})


class Tokens(unittest.TestCase):
    def snapshot(self, **extra):
        return {"by_bead": {}, "by_model": {}, "floors": {"claude": "2026-10-30T08:00:00Z", "pi": "2026-10-31T08:00:00Z"},
                "by_day": {"2026-10-30": {"claude": work(100, 20)}, "2026-10-31": {"claude": work(50, 10), "pi": work(5, 1, unknown_output=2)}},
                "partial": ["pi"], "pending_batches": 3, **extra}

    def test_the_headline_is_fresh_input_plus_output_and_never_the_provider_total(self):
        block = usage(tokens=self.snapshot())["tokens"]
        self.assertEqual(block["headline"], {"known": 186, "unknown": True, "fresh_input": 155, "output": 31})
        self.assertNotIn("999999", repr(block))
        for forbidden in ("cost", "quota", "percent", "total_tokens"):
            self.assertNotIn(forbidden, repr(block).lower())

    def test_a_runtime_starts_at_its_own_floor_with_a_gap_before_it(self):
        block = usage(tokens=self.snapshot())["tokens"]
        by_name = {row["runtime"]: row for row in block["runtimes"]}
        self.assertEqual(block["days"], ["2026-10-30", "2026-10-31", "2026-11-01"])
        self.assertEqual(by_name["claude"]["values"], [120, 60, 0])
        self.assertEqual(by_name["pi"]["values"], [None, 6, 0])        # None is a gap, not a zero

    def test_unknown_counters_flag_the_day_and_a_partial_runtime_is_named(self):
        block = usage(tokens=self.snapshot())["tokens"]
        pi = [row for row in block["runtimes"] if row["runtime"] == "pi"][0]
        self.assertEqual((pi["unknown"], pi["unknown_days"], pi["partial"]), (True, ["2026-10-31"], True))
        self.assertEqual((block["partial"], block["pending_batches"]), (["pi"], 3))

    def test_a_store_with_no_timed_fact_is_empty_and_never_a_zero_total(self):
        block = usage(tokens={"by_bead": {}, "by_model": {}, "floors": {}, "by_day": {}, "partial": ["pi"]})["tokens"]
        self.assertEqual((block["state"], block["headline"]), ("empty", None))

    def test_tokens_start_later_than_the_range_so_the_early_days_are_a_gap(self):
        block = metrics.summary_view({"tokens": self.snapshot()}, NOW, "7d")["tokens"]
        by_name = {row["runtime"]: row for row in block["runtimes"]}
        self.assertEqual(block["days"][0], "2026-10-26")
        self.assertEqual(by_name["claude"]["values"], [None, None, None, None, 120, 60, 0])
        self.assertEqual(by_name["pi"]["values"], [None] * 5 + [6, 0])

    def test_a_range_before_every_floor_has_no_known_total(self):
        later = self.snapshot(floors={"claude": "2026-12-01T00:00:00Z"}, by_day={}, partial=[])
        block = usage(tokens=later)["tokens"]
        self.assertIsNone(block["headline"]["known"])


class Commits(unittest.TestCase):
    def git(self, *commits, tokenless=7):
        stamps = [c["at"] for c in commits]
        return {"commits": list(commits), "root_commit_at": "2026-09-01T00:00:00Z",
                "floor": min(stamps) if stamps else None, "tokenless_commits": tokenless}

    def test_lines_split_into_production_and_test_and_tokenless_commits_are_a_count(self):
        block = usage(git=self.git(
            {"sha": "a", "at": "2026-10-30T09:00:00Z", "beads": ["SPEC-a"], "production_lines": 40, "test_lines": 10},
            {"sha": "b", "at": "2026-10-31T09:00:00Z", "beads": ["SPEC-a"], "production_lines": 5, "test_lines": 30}))["commits"]
        self.assertEqual(block["totals"], {"commits": 2, "production_lines": 45, "test_lines": 40, "lines_unknown": 0})
        self.assertEqual(block["tokenless_commits"], 7)
        self.assertEqual((block["production"], block["test"], block["commits"]), ([40, 5, 0], [10, 30, 0], [1, 1, 0]))

    def test_a_repository_with_only_commits_without_a_bead_token_is_empty_with_the_count(self):
        block = usage(git=self.git(tokenless=12))["commits"]
        self.assertEqual((block["state"], block["tokenless_commits"], block["totals"]), ("empty", 12, None))

    def test_a_commit_with_unknown_lines_is_counted_and_adds_no_zero_lines(self):
        block = usage(git=self.git({"sha": "a", "at": "2026-10-30T09:00:00Z", "beads": ["SPEC-a"],
                                    "production_lines": None, "test_lines": None}))["commits"]
        self.assertEqual(block["totals"], {"commits": 1, "production_lines": 0, "test_lines": 0, "lines_unknown": 1})

    def test_the_range_leaves_out_older_commits(self):
        git = self.git({"sha": "a", "at": "2026-08-01T09:00:00Z", "beads": ["SPEC-a"], "production_lines": 9, "test_lines": 1})
        block = metrics.summary_view({"git": git}, NOW, "7d")["commits"]
        self.assertEqual(block["totals"]["commits"], 0)
        self.assertEqual((block["days"][0], block["commits"][:4]), ("2026-10-26", [0, 0, 0, 0]))   # floor in August: covered, so 0


class TestCost(unittest.TestCase):
    def snap(self, *records):
        times = [r["at"] for r in records]
        return {"records": list(records), "stage_seconds": {}, "floor": min(times) if times else None}

    def test_seconds_and_runs_per_stage_with_a_median(self):
        block = usage(tests=self.snap(
            {"bead": "SPEC-a", "stage": "commit", "at": "2026-10-30T09:00:00Z", "seconds": 10.0, "status": "passed"},
            {"bead": "SPEC-a", "stage": "commit", "at": "2026-10-30T10:00:00Z", "seconds": 30.0, "status": "failed"},
            {"bead": "SPEC-a", "stage": "bead", "at": "2026-10-31T10:00:00Z", "seconds": 60.0, "status": "passed"}))["test_cost"]
        stages = {row["stage"]: row for row in block["stages"]}
        self.assertEqual((stages["commit"]["runs"], stages["commit"]["failed"], stages["commit"]["seconds"],
                          stages["commit"]["median_seconds"]), (2, 1, 40.0, 20.0))
        self.assertEqual(stages["bead"]["values"], [0.0, 60.0, 0.0])
        self.assertEqual(block["floor"], "2026-10-30")

    def test_a_stage_with_no_run_has_no_value_and_not_zero_seconds(self):
        block = usage(tests=self.snap(
            {"bead": "SPEC-a", "stage": "commit", "at": "2026-10-30T09:00:00Z", "seconds": 10.0, "status": "passed"}))["test_cost"]
        full = [row for row in block["stages"] if row["stage"] == "full"][0]
        self.assertEqual((full["runs"], full["seconds"], full["median_seconds"]), (0, None, None))

    def test_a_run_that_did_not_run_is_counted_apart(self):
        block = usage(tests=self.snap(
            {"bead": None, "stage": "commit", "at": "2026-10-30T09:00:00Z", "seconds": None, "status": "skipped"}))["test_cost"]
        self.assertEqual(block["excluded"], {"not_run": 1, "untimed": 0})

    def test_a_consumer_repository_without_test_records_is_absent(self):
        self.assertEqual(usage()["test_cost"], {"state": "absent"})


if __name__ == "__main__":
    unittest.main()
