"""The table of Decision 11, from captured `gh` JSON. Pure, no subprocess."""
import json
import os
import sys
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import testing_ci as c

CI = {"branch": "develop", "job_pattern": "test", "max_age_days": 7, "cache_seconds": 21600}
NOW = datetime(2026, 10, 31, 12, 0, tzinfo=timezone.utc).timestamp()


def iso(days_ago):
    return datetime.fromtimestamp(NOW - days_ago * 86400, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(run_id, days_ago, branch="develop", event="push"):
    return {"databaseId": run_id, "headBranch": branch, "event": event, "createdAt": iso(days_ago)}


def gh_for(runs, jobs_by_id):
    """A run_gh over captured JSON; records every call."""
    calls = []

    def run_gh(argv):
        calls.append(argv)
        if argv[:2] == ["run", "list"]:
            return json.dumps(runs)
        if argv[:2] == ["run", "view"]:
            jobs = jobs_by_id.get(int(argv[2]))
            return None if jobs is None else json.dumps({"jobs": jobs})
        raise AssertionError(argv)

    run_gh.calls = calls
    return run_gh


def job(name, conclusion="success"):
    return {"name": name, "conclusion": conclusion}


class Table(unittest.TestCase):
    def refreshed(self, runs, jobs):
        return c.refresh(CI, gh_for(runs, jobs), NOW)["result"]

    def test_ran_on_the_branch(self):
        self.assertEqual(self.refreshed([run(1, 1)], {1: [job("Unit tests")]}), c.RAN)

    def test_ran_from_a_pull_request_on_another_branch(self):
        self.assertEqual(self.refreshed([run(1, 2, "feat/x", "pull_request")], {1: [job("test")]}), c.RAN)

    def test_a_red_test_job_still_ran(self):
        self.assertEqual(self.refreshed([run(1, 1)], {1: [job("test", "failure")]}), c.RAN)

    def test_skipped_and_cancelled_jobs_do_not_count(self):
        for conclusion in ("skipped", "cancelled"):
            self.assertEqual(self.refreshed([run(1, 1)], {1: [job("test", conclusion)]}), c.NONE)

    def test_no_test_job_is_none(self):
        self.assertEqual(self.refreshed([run(1, 1)], {1: [job("lint"), job("build")]}), c.NONE)

    def test_no_run_at_all_is_none(self):
        self.assertEqual(self.refreshed([], {}), c.NONE)

    def test_a_run_on_an_unrelated_push_branch_is_not_a_candidate(self):
        self.assertEqual(self.refreshed([run(1, 1, "other")], {1: [job("test")]}), c.NONE)

    def test_the_pattern_is_case_insensitive(self):
        self.assertEqual(self.refreshed([run(1, 1)], {1: [job("PyTest matrix")]}), c.RAN)

    def test_an_old_test_job_only_is_stale_with_its_age(self):
        result = c.refresh(CI, gh_for([run(1, 20)], {1: [job("test")]}), NOW)
        self.assertEqual(result["result"], c.STALE)
        self.assertEqual(NOW - result["last_test_at"], 20 * 86400)

    def test_at_most_three_runs_are_inspected(self):
        runs = [run(i, i) for i in range(1, 8)]
        gh = gh_for(runs, {i: [job("lint")] for i in range(1, 8)})
        self.assertEqual(c.refresh(CI, gh, NOW)["result"], c.NONE)
        self.assertEqual(len([a for a in gh.calls if a[1] == "view"]), 3)

    def test_the_first_run_with_a_test_job_stops_the_search(self):
        gh = gh_for([run(1, 1), run(2, 2), run(3, 3)], {1: [job("test")]})
        c.refresh(CI, gh, NOW)
        self.assertEqual(len([a for a in gh.calls if a[1] == "view"]), 1)

    def test_a_gh_failure_is_unknown(self):
        self.assertEqual(c.refresh(CI, lambda argv: None, NOW)["result"], c.UNKNOWN)
        self.assertEqual(c.refresh(CI, lambda argv: "not json", NOW)["result"], c.UNKNOWN)
        self.assertEqual(c.refresh(CI, gh_for([run(1, 1)], {}), NOW)["result"], c.UNKNOWN)


class Lines(unittest.TestCase):
    def test_ran_and_unknown_print_nothing(self):
        for kind in (c.RAN, c.UNKNOWN):
            self.assertIsNone(c.doctor_line({"result": kind}, CI, NOW))

    def test_stale_is_a_note_with_the_age(self):
        level, text = c.doctor_line({"result": c.STALE, "last_test_at": NOW - 20 * 86400}, CI, NOW)
        self.assertEqual(level, "NOTE")
        self.assertIn("20 d", text)

    def test_none_is_a_warn_naming_branch_pattern_and_fallback(self):
        level, text = c.doctor_line({"result": c.NONE}, CI, NOW)
        self.assertEqual(level, "WARN")
        for part in ("develop", "'test'", "nightly fallback"):
            self.assertIn(part, text)

    def test_absent_is_a_note_unless_a_nightly_record_exists(self):
        self.assertEqual(c.doctor_line({"result": c.ABSENT}, CI, NOW)[0], "NOTE")
        self.assertIsNone(c.doctor_line({"result": c.ABSENT}, CI, NOW, nightly_recorded=True))


class Check(unittest.TestCase):
    def cached(self, result, age):
        return c.entry({"result": result, "last_test_at": None}, CI, NOW - age)

    def test_no_ci_calls_no_gh_and_caches_nothing(self):
        gh = gh_for([], {})
        line, new = c.check(CI, False, gh, NOW)
        self.assertEqual(line[0], "NOTE")
        self.assertIsNone(new)
        self.assertEqual(gh.calls, [])

    def test_a_fresh_cache_calls_no_gh(self):
        gh = gh_for([], {})
        line, new = c.check(CI, True, gh, NOW, cache=self.cached(c.NONE, 60))
        self.assertEqual(line[0], "WARN")
        self.assertEqual((new, gh.calls), (None, []))

    def test_an_expired_cache_refreshes_and_stores(self):
        gh = gh_for([run(1, 1)], {1: [job("test")]})
        line, new = c.check(CI, True, gh, NOW, cache=self.cached(c.NONE, 7 * 3600))
        self.assertIsNone(line)
        self.assertEqual(new["result"], c.RAN)

    def test_a_cache_for_another_branch_is_ignored(self):
        other = dict(self.cached(c.NONE, 60), branch="main")
        self.assertFalse(c.cache_usable(other, CI, NOW))

    def test_offline_without_a_cache_prints_nothing(self):
        self.assertEqual(c.check(CI, True, lambda argv: None, NOW), (None, None))

    def test_offline_keeps_a_stale_cached_line_with_its_age(self):
        line, new = c.check(CI, True, lambda argv: None, NOW, cache=self.cached(c.NONE, 2 * 86400))
        self.assertEqual(line[0], "WARN")
        self.assertIn("2 d ago", line[1])
        self.assertIsNone(new)

    def test_offline_with_a_cached_ran_prints_nothing(self):
        self.assertEqual(c.check(CI, True, lambda argv: None, NOW, cache=self.cached(c.RAN, 2 * 86400)),
                         (None, None))


if __name__ == "__main__":
    unittest.main()
