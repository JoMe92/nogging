#!/usr/bin/env python3
"""Small tests of the start-page statistics: pure functions over plain snapshots."""
from __future__ import annotations

import sys, unittest
from datetime import date, datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_metrics as metrics

NOW = datetime(2026, 11, 1, 12, 0, tzinfo=timezone.utc)


def bead(identifier, status="open", **extra):
    return {"id": identifier, "status": status, "labels": [], "created_at": "2026-10-01T10:00:00Z", **extra}


def snapshot(*beads, ready=()):
    return {"beads": list(beads), "ready": list(ready), "cycles": []}


def view(beads=None, range_name="all", **others):
    return metrics.summary_view({"beads": beads, **others}, NOW, range_name)


class Statistics(unittest.TestCase):
    def test_the_median_of_an_odd_even_and_empty_input(self):
        self.assertEqual(metrics.median([5, 1, 3]), 3)
        self.assertEqual(metrics.median([4, 1, 3, 2]), 2.5)
        self.assertEqual(metrics.median([7]), 7)
        self.assertIsNone(metrics.median([]))

    def test_the_p90_is_the_nearest_rank(self):
        self.assertEqual(metrics.percentile(range(1, 11), 0.9), 9)
        self.assertEqual(metrics.percentile(range(1, 12), 0.9), 10)
        self.assertEqual(metrics.percentile([42], 0.9), 42)
        self.assertEqual(metrics.percentile([3, 1, 2], 0.9), 3)
        self.assertIsNone(metrics.percentile([], 0.9))

    def test_the_histogram_lists_every_bin_and_a_boundary_goes_up(self):
        bins = metrics.histogram([0, 3599, 3600, 86400, 20 * 86400])
        self.assertEqual([item["count"] for item in bins], [2, 1, 0, 0, 1, 0, 0, 1])
        self.assertEqual(sum(item["count"] for item in metrics.histogram([])), 0)


class BeadsByStatus(unittest.TestCase):
    def test_the_counts_match_the_beads_and_an_unknown_status_stands_apart(self):
        data = view(snapshot(bead("a"), bead("b", "in_progress"), bead("c", "blocked"), bead("d", "closed"),
                             bead("e", "closed"), bead("f", "deferred"), bead("g", "weird"), ready=["a"]))
        status = data["status"]
        self.assertEqual(status["counts"], {"open": 1, "in_progress": 1, "blocked": 1, "closed": 2, "deferred": 1})
        self.assertEqual((status["other"], status["total"], status["ready"]), (1, 7, 1))

    def test_no_beads_is_empty_and_a_missing_source_is_absent(self):
        self.assertEqual(view(snapshot())["status"]["state"], "empty")
        self.assertEqual(view(snapshot())["status"]["counts"]["open"], 0)      # a source with no Bead: a real 0
        data = view(None)
        for block in ("status", "closed", "by_change", "cycle", "lead"):
            self.assertEqual(data[block], {"state": "absent"}, block)
        self.assertEqual(data["project"]["state"], "absent")
        self.assertEqual(data["activity"]["state"], "absent")


class Durations(unittest.TestCase):
    def closed(self, identifier, start, end, created="2026-09-01T00:00:00Z"):
        return bead(identifier, "closed", created_at=created, started_at=start, closed_at=end)

    def test_lead_time_with_a_missing_start(self):
        data = view(snapshot(self.closed("a", "2026-10-01T00:00:00Z", "2026-10-01T10:00:00Z"),
                             self.closed("b", None, "2026-10-03T00:00:00Z"),
                             self.closed("c", None, "2026-10-04T00:00:00Z"),
                             bead("d", "open", started_at="2026-10-05T00:00:00Z")))
        cycle, lead = data["cycle"], data["lead"]
        self.assertEqual((cycle["count"], cycle["excluded"]["no_start"]), (1, 2))
        self.assertEqual(cycle["median_seconds"], 36000)
        self.assertEqual(lead["count"], 3)                                  # an open Bead is excluded
        self.assertEqual(lead["excluded"], {"no_start": 0, "backwards": 0})
        self.assertGreater(lead["median_seconds"], cycle["median_seconds"])

    def test_every_closed_bead_without_a_start_leaves_no_number_at_all(self):
        data = view(snapshot(self.closed("a", None, "2026-10-01T10:00:00Z")))
        self.assertEqual((data["cycle"]["state"], data["cycle"]["median_seconds"], data["cycle"]["p90_seconds"]),
                         ("empty", None, None))
        self.assertEqual(data["cycle"]["excluded"]["no_start"], 1)
        self.assertEqual(data["cycle"]["bins"], [])

    def test_a_negative_duration_is_counted_and_left_out(self):
        data = view(snapshot(self.closed("a", "2026-10-02T00:00:00Z", "2026-10-01T00:00:00Z")))
        self.assertEqual((data["cycle"]["count"], data["cycle"]["excluded"]["backwards"]), (0, 1))

    def test_the_window_keeps_the_beads_that_closed_inside_it(self):
        beads = snapshot(self.closed("a", "2026-10-30T00:00:00Z", "2026-10-31T00:00:00Z"),
                         self.closed("b", "2026-08-01T00:00:00Z", "2026-08-02T00:00:00Z"))
        self.assertEqual(view(beads, "7d")["cycle"]["count"], 1)
        self.assertEqual(view(beads, "all")["cycle"]["count"], 2)


class ProjectAge(unittest.TestCase):
    def test_the_root_commit_the_first_bead_and_the_age(self):
        data = view(snapshot(bead("a", created_at="2026-10-10T00:00:00Z"), bead("b", created_at="2026-10-05T00:00:00Z")),
                    git={"commits": [], "root_commit_at": "2026-09-01T08:00:00Z", "floor": None})
        self.assertEqual(data["project"], {"state": "ready", "root_commit_at": "2026-09-01T08:00:00Z",
                                           "first_bead_at": "2026-10-05T00:00:00Z", "age_days": 61,
                                           "basis": "root_commit"})

    def test_without_git_the_age_comes_from_the_first_bead_and_says_so(self):
        project = view(snapshot(bead("a", created_at="2026-10-22T00:00:00Z")))["project"]
        self.assertEqual((project["root_commit_at"], project["age_days"], project["basis"]), (None, 10, "first_bead"))

    def test_with_nothing_there_is_no_age_and_no_zero(self):
        project = view(snapshot())["project"]
        self.assertEqual((project["state"], project["age_days"]), ("absent", None))


class ClosedOverTime(unittest.TestCase):
    def test_closed_beads_are_raw_events_and_a_bead_without_a_time_is_counted(self):
        data = view(snapshot(bead("a", "closed", closed_at="2026-10-30T09:00:00Z", labels=["openspec:change:x"]),
                             bead("b", "closed")), "30d")
        closed = data["closed"]
        self.assertEqual(closed["events"], [{"at": "2026-10-30T09:00:00Z", "change": "x"}])
        self.assertEqual((closed["without_time"], closed["floor"]), (1, "2026-10-01T10:00:00Z"))
        self.assertEqual(closed["since"], "2026-10-03T00:00:00Z")

    def test_closed_by_change_keeps_ten_and_folds_the_rest_into_other(self):
        beads = [bead(f"c{n}-{k}", "closed", closed_at="2026-10-30T09:00:00Z", labels=[f"openspec:change:ch{n:02d}"])
                 for n in range(12) for k in range(n + 1)]
        beads.append(bead("loose", "closed", closed_at="2026-10-30T09:00:00Z"))
        block = view(snapshot(*beads))["by_change"]
        self.assertEqual([row["change"] for row in block["rows"][:3]], ["ch11", "ch10", "ch09"])
        self.assertEqual(len(block["rows"]), 11)
        self.assertEqual(block["rows"][-1], {"change": None, "closed": 1})
        self.assertEqual(block["other"], {"changes": 2, "closed": 3})

    def test_no_closed_bead_is_empty_not_a_row_of_zeros(self):
        block = view(snapshot(bead("a")))["by_change"]
        self.assertEqual((block["state"], block["rows"], block["other"]), ("empty", [], None))


class GapsInTheActivity(unittest.TestCase):
    def test_tokens_start_later_than_beads_as_gap_output(self):
        first, last = date(2026, 10, 1), date(2026, 10, 5)
        rows = metrics.daily({"2026-10-03": 4000}, date(2026, 10, 3), first, last)
        self.assertEqual([row["value"] for row in rows], [None, None, 4000, 0, 0])
        self.assertEqual(rows[0]["day"], "2026-10-01")

    def test_a_source_without_a_floor_is_a_gap_over_the_whole_span(self):
        rows = metrics.daily({}, None, date(2026, 10, 1), date(2026, 10, 3))
        self.assertEqual([row["value"] for row in rows], [None, None, None])

    def test_each_series_has_its_own_floor_and_an_absent_source_is_named(self):
        data = view(snapshot(bead("a", created_at="2026-10-29T10:00:00Z"), bead("b", "closed", created_at="2026-10-30T00:00:00Z",
                                                                               closed_at="2026-10-31T00:00:00Z")),
                    git={"commits": [{"at": "2026-10-31T09:00:00Z"}, {"at": "2026-10-31T10:00:00Z"}],
                         "root_commit_at": "2026-01-01T00:00:00Z", "floor": "2026-10-31T09:00:00Z"})
        activity = data["activity"]
        self.assertEqual(activity["days"], ["2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"])
        self.assertEqual(activity["series"]["created"]["values"], [1, 1, 0, 0])
        self.assertEqual(activity["series"]["closed"]["values"], [0, 0, 1, 0])
        self.assertEqual(activity["series"]["commits"]["values"], [None, None, 2, 0])
        self.assertEqual(activity["series"]["commits"]["floor"], "2026-10-31")
        self.assertEqual(activity["series"]["sessions"], {"state": "absent"})
        self.assertEqual(activity["series"]["tests"], {"state": "absent"})

    def test_the_window_cuts_the_span_but_not_the_floors(self):
        data = view(snapshot(bead("a", created_at="2026-01-01T00:00:00Z")), "7d")
        self.assertEqual(data["activity"]["days"][0], "2026-10-26")
        self.assertEqual(data["activity"]["series"]["created"]["values"], [0] * 7)

    def test_an_unknown_range_is_refused(self):
        with self.assertRaises(ValueError):
            metrics.summary_view({}, NOW, "forever")


if __name__ == "__main__":
    unittest.main()
