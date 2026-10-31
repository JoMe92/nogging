"""Aggregation, the trend rule, budget messages and the per-Bead test changes."""
import datetime as dt
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import testing_report as t
import testing_runs as runs

NOW = dt.datetime(2026, 10, 31, 12, 0, tzinfo=dt.timezone.utc)


def rec(days_ago=0, stage="bead", seconds=100.0, status="passed", **fields):
    at = (NOW - dt.timedelta(days=days_ago, minutes=1)).isoformat()
    return runs.build_record(stage=stage, trigger=fields.pop("trigger", "stage"), status=status,
                             exit_code=1 if status == "failed" else 0, seconds=seconds, at=at, **fields)


def series(stage, days_ago, seconds, **fields):
    return [rec(d, stage, s, **fields) for d, s in zip(days_ago, seconds)]


class Aggregation(unittest.TestCase):
    def test_daily_row_counts_runs_failures_median_and_budget(self):
        records = [rec(0, "bead", 100), rec(0, "bead", 300, status="failed", over_budget=True), rec(0, "bead", 200),
                   rec(1, "commit", 10), rec(0, "commit", 5, status="skipped"), rec(0, "bead", 9, status="refused")]
        rows = t.daily_rows(records, NOW, 14)
        self.assertEqual(rows, [
            {"day": "2026-10-30", "stage": "commit", "runs": 1, "failures": 0, "median_seconds": 10.0, "over_budget": 0},
            {"day": "2026-10-31", "stage": "bead", "runs": 3, "failures": 1, "median_seconds": 200.0, "over_budget": 1}])

    def test_the_window_excludes_older_days(self):
        records = [rec(0, "bead", 1), rec(2, "bead", 1), rec(3, "bead", 1)]
        self.assertEqual([r["day"] for r in t.daily_rows(records, NOW, 3)], ["2026-10-29", "2026-10-31"])

    def test_median_of_an_even_count_is_the_mean_of_the_middle_two(self):
        self.assertEqual(t.median([1, 2, 3, 10]), 2.5)
        self.assertIsNone(t.median([]))

    def test_slowest_tests_keep_the_longest_time_per_name(self):
        slow = lambda name, s: {"slowest": [{"name": name, "seconds": s}]}
        records = [rec(0, **{"detail": slow("a::x", 3.0)}), rec(1, **{"detail": slow("a::x", 9.0)}),
                   rec(1, **{"detail": slow("b::y", 5.0)})]
        top = t.slowest_tests(records, NOW, 14, limit=2)
        self.assertEqual([(x["name"], x["seconds"]) for x in top], [("a::x", 9.0), ("b::y", 5.0)])

    def test_full_runs_list_trigger_and_reason(self):
        records = [rec(1, "full", 500, trigger="allow-full", reason="migration", session="s1", role="lead"),
                   rec(1, "bead", 50), rec(1, "full", 0, status="refused", trigger="none")]
        rows = t.full_runs(records, NOW, 14)
        self.assertEqual([(r["trigger"], r["reason"], r["session"]) for r in rows], [("allow-full", "migration", "s1")])


class Trend(unittest.TestCase):
    def grown(self, now_runs=(500, 500, 500), before_runs=(300, 300, 300)):
        return (series("bead", [1, 2, 3][:len(now_runs)], now_runs)
                + series("bead", [8, 9, 10][:len(before_runs)], before_runs))

    def test_a_suite_that_grows(self):
        notes = t.doctor_notes(self.grown(), NOW, 30)
        self.assertEqual(len(notes), 1)
        self.assertIn("bead", notes[0])
        self.assertIn("67%", notes[0])
        self.assertIn("300 s to 500 s", notes[0])

    def test_too_few_runs_print_no_trend_note(self):
        self.assertEqual(t.doctor_notes(self.grown(now_runs=(500, 500)), NOW, 30), [])
        self.assertEqual(t.doctor_notes(self.grown(before_runs=(300, 300)), NOW, 30), [])

    def test_a_rise_at_or_below_the_threshold_is_no_note(self):
        self.assertEqual(t.doctor_notes(self.grown(now_runs=(390, 390, 390)), NOW, 30), [])

    def test_week_over_week_reports_the_change_even_without_enough_runs(self):
        row = t.week_over_week(self.grown(now_runs=(500,)), NOW)["bead"]
        self.assertEqual((row["change_percent"], row["enough"]), (66.7, False))

    def test_no_earlier_window_gives_no_change(self):
        row = t.week_over_week(series("bead", [1, 2, 3], [5, 5, 5]), NOW)["bead"]
        self.assertIsNone(row["change_percent"])

    def test_the_latest_run_over_budget_is_a_note(self):
        records = [rec(0, "bead", 2000, over_budget=True, budget_seconds=1800)]
        note = t.doctor_notes(records, NOW, 30)[0]
        self.assertIn("latest bead run took 2000 s, over its 1800 s budget", note)

    def test_an_older_over_budget_run_is_not_the_latest(self):
        records = [rec(2, "bead", 2000, over_budget=True, budget_seconds=1800), rec(0, "bead", 100)]
        self.assertEqual(t.doctor_notes(records, NOW, 30), [])

    def test_a_lead_allow_full_in_the_last_week_is_a_note_and_an_operator_one_is_not(self):
        lead = rec(2, "full", 9, trigger="allow-full", reason="r", role="lead", session="lead-1")
        operator = rec(2, "full", 9, trigger="allow-full", reason="r", role=None)
        old = rec(9, "full", 9, trigger="allow-full", reason="r", role="lead", session="lead-2")
        notes = t.doctor_notes([lead, operator, old], NOW, 30)
        self.assertEqual(len(notes), 1)
        self.assertIn("1 --allow-full run from a Lead session", notes[0])
        self.assertIn("lead-1", notes[0])


class Budget(unittest.TestCase):
    LIMITS = (1, 1500)

    def test_inside_the_range_has_no_message(self):
        self.assertIsNone(t.budget_message("B-1", {"test": 40, "production": 300}, self.LIMITS))

    def test_above_the_maximum_names_the_count_and_the_budget(self):
        message = t.budget_message("B-1", {"test": 1800, "production": 300}, self.LIMITS)
        self.assertIn("1800 test lines", message)
        self.assertIn("maximum of 1500", message)

    def test_production_code_without_a_test_line_is_below_the_minimum(self):
        message = t.budget_message("B-1", {"test": 0, "production": 300}, self.LIMITS)
        self.assertIn("below", message)
        self.assertIn("minimum of 1", message)

    def test_a_documentation_only_change_needs_no_test_line(self):
        self.assertIsNone(t.budget_message("B-1", {"test": 0, "production": 0}, self.LIMITS))

    def test_bead_findings_skip_a_bead_without_commits(self):
        lines = {"B-1": {"commits": 0, "production_lines": 0, "test_lines": 0},
                 "B-2": {"commits": 2, "production_lines": 100, "test_lines": 0}}
        self.assertEqual([f["bead"] for f in t.bead_findings(lines, self.LIMITS)], ["B-2"])
        self.assertEqual(t.bead_findings(None, self.LIMITS), [])

    def test_line_counts_classify_and_ignore_binary_files(self):
        text = "10\t2\tsrc/app.py\n5\t0\tsrc/app_test.py\n-\t-\tlogo.png\n3\t1\tCHANGELOG.md\n"
        counts = t.line_counts(text)
        self.assertEqual((counts["production"], counts["test"]), (12 + 4, 5))


class Rendering(unittest.TestCase):
    def test_no_records_say_so(self):
        doc = t.build_report([], NOW, 14)
        self.assertEqual(len(t.render_report(doc)), 1)
        self.assertIn("no test runs recorded yet", t.render_report(doc)[0])

    def test_a_report_lists_rows_trend_and_beads(self):
        records = [rec(0, "bead", 100, over_budget=True), rec(9, "bead", 50)]
        doc = t.build_report(records, NOW, 14, beads=[{"message": "Bead X: 3000 test lines, above"}])
        text = "\n".join(t.render_report(doc))
        for needle in ("2026-10-31", "bead", "week over week", "Bead X: 3000 test lines"):
            self.assertIn(needle, text)

    def test_stage_seconds_sum_runs_per_bead_and_stage(self):
        records = [rec(0, "bead", 100, bead="B-1"), rec(1, "bead", 50, bead="B-1"), rec(1, "commit", 5, bead="B-1"),
                   rec(1, "bead", 7, bead="B-2", status="skipped")]
        got = t.stage_seconds(records, ["B-1", "B-2"])
        self.assertEqual(got["B-1"], {"changed": None, "commit": 5.0, "bead": 150.0, "full": None})
        self.assertEqual(got["B-2"], {"changed": None, "commit": None, "bead": None, "full": None})


class BeadChanges(unittest.TestCase):
    """bead_test_changes on a temporary repository: git is real, nothing else is."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        self.env = {**os.environ, **env}
        self.git("init", "-q", "-b", "develop")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, env=self.env)

    def commit(self, subject, **files):
        for name, text in files.items():
            (self.repo / name.replace("__", "/")).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / name.replace("__", "/")).write_text(text)
        self.git("add", "-A")
        self.git("commit", "-qm", subject)

    def test_counts_tests_added_deleted_and_skips(self):
        self.commit("chore: start", app="x")
        self.commit("test: add [B-1]", **{"tests__a_test.py": "def test_one():\n    assert 1\n\ndef test_two():\n    assert 2\n"})
        self.commit("test: weaken [B-1]", **{"tests__a_test.py":
                    "import pytest\n\ndef test_one():\n    assert 1\n\n@pytest.mark.skip\ndef test_three():\n    assert 3\n"})
        got = t.bead_test_changes(self.repo, ["B-1", "B-9"])
        self.assertEqual(got, {"B-1": {"tests_added": 2, "tests_deleted": 0, "skips_added": 1}})

    def test_a_test_moved_between_files_is_neither_added_nor_deleted(self):
        self.commit("chore: start", app="x")
        self.commit("test: add [B-2]", **{"tests__a_test.py": "def test_one():\n    assert 1\n"})
        self.git("mv", "tests/a_test.py", "tests/b_test.py")
        self.git("commit", "-qm", "refactor: move [B-2]")
        self.assertEqual(t.bead_test_changes(self.repo, ["B-2"]),
                         {"B-2": {"tests_added": 1, "tests_deleted": 0, "skips_added": 0}})

    def test_git_that_fails_gives_none_and_no_beads_gives_empty(self):
        self.assertEqual(t.bead_test_changes(self.repo, []), {})
        self.assertIsNone(t.bead_test_changes(self.repo / "missing", ["B-1"]))


if __name__ == "__main__":
    unittest.main()
