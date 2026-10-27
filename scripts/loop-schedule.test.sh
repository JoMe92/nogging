#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONPATH="$ROOT/scripts/lib${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
from datetime import datetime, timezone
import unittest

from loop_schedule import deadline, due, next_slots, parse_schedule

UTC = timezone.utc


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def schedule(**values):
    return {"timezone": "UTC", **values}


class ScheduleTests(unittest.TestCase):
    def slots(self, spec, after, count):
        return [value.isoformat().replace("+00:00", "Z")
                for value in next_slots(spec, instant(after), count)]

    def test_minute_hour_intervals_restart_at_daily_anchor(self):
        self.assertEqual(self.slots(schedule(every="5h", start="02:07"),
                                    "2026-01-01T02:07:00Z", 5), [
            "2026-01-01T07:07:00Z", "2026-01-01T12:07:00Z",
            "2026-01-01T17:07:00Z", "2026-01-01T22:07:00Z",
            "2026-01-02T02:07:00Z"])
        self.assertEqual(self.slots(schedule(every="15m", start="09:10"),
                                    "2026-01-01T09:10:00Z", 2), [
            "2026-01-01T09:25:00Z", "2026-01-01T09:40:00Z"])

    def test_day_and_week_intervals_keep_phase(self):
        spec = schedule(every="3d", start="2026-01-01T08:30")
        self.assertEqual(self.slots(spec, "2026-01-01T08:30:00Z", 3), [
            "2026-01-04T08:30:00Z", "2026-01-07T08:30:00Z",
            "2026-01-10T08:30:00Z"])
        week = schedule(every="1w", start="2026-01-05T08:30")
        self.assertEqual(self.slots(week, "2026-01-05T08:30:00Z", 2), [
            "2026-01-12T08:30:00Z", "2026-01-19T08:30:00Z"])

    def test_daily_at_are_sorted_and_days_filter_local_weekdays(self):
        spec = schedule(at=["09:00", "17:00"], days=["mon", "wed"])
        self.assertEqual(self.slots(spec, "2026-01-05T09:00:00Z", 3), [
            "2026-01-05T17:00:00Z", "2026-01-07T09:00:00Z",
            "2026-01-07T17:00:00Z"])

    def test_windows_are_start_inclusive_end_exclusive_and_cross_midnight(self):
        spec = schedule(at=["01:00", "07:00", "22:00"],
                        windows=["22:00-07:00"])
        self.assertEqual(self.slots(spec, "2026-01-02T00:00:00Z", 2), [
            "2026-01-02T01:00:00Z", "2026-01-02T22:00:00Z"])

    def test_overnight_window_day_filter_uses_opening_day(self):
        spec = schedule(at=["01:00"], windows=["22:00-07:00"], days=["fri"])
        self.assertEqual(self.slots(spec, "2026-01-03T00:00:00Z", 1),
                         ["2026-01-03T01:00:00Z"])

    def test_berlin_gap_moves_to_first_valid_instant(self):
        spec = {"timezone": "Europe/Berlin", "at": ["02:30"]}
        self.assertEqual(self.slots(spec, "2027-03-27T23:00:00Z", 1),
                         ["2027-03-28T01:00:00Z"])

    def test_berlin_overlap_uses_first_occurrence(self):
        spec = {"timezone": "Europe/Berlin", "at": ["02:30"]}
        self.assertEqual(self.slots(spec, "2026-10-24T23:00:00Z", 1),
                         ["2026-10-25T00:30:00Z"])
        self.assertEqual(self.slots(spec, "2026-10-25T00:30:00Z", 1),
                         ["2026-10-26T01:30:00Z"])

    def test_due_reports_latest_and_older_missed_bounds(self):
        result = due(schedule(every="1h", start="00:00"),
                     instant("2026-01-01T00:30:00Z"),
                     instant("2026-01-01T03:30:00Z"))
        self.assertEqual(result, {
            "slot": instant("2026-01-01T03:00:00Z"), "count": 3,
            "missed_first": instant("2026-01-01T01:00:00Z"),
            "missed_last": instant("2026-01-01T02:00:00Z")})

    def test_deadline_is_earliest_grace_next_slot_and_window_end(self):
        spec = schedule(every="1h", start="00:00", grace=7200)
        self.assertEqual(deadline(spec, instant("2026-01-01T01:00:00Z")),
                         instant("2026-01-01T02:00:00Z"))
        windowed = schedule(at=["06:00"], windows=["05:00-06:30"], grace=7200)
        self.assertEqual(deadline(windowed, instant("2026-01-01T06:00:00Z")),
                         instant("2026-01-01T06:30:00Z"))

    def test_validation_names_the_invalid_key(self):
        cases = [
            (schedule(every="2m"), "every"),
            (schedule(every="2d", start="08:00"), "start"),
            (schedule(at=["09:00", "09:00"]), "at"),
            (schedule(at=["09:00"], windows=["10:00-10:00"]), "windows"),
            ({"timezone": "Not/AZone", "at": ["09:00"]}, "timezone"),
        ]
        for spec, key in cases:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, rf"^{key}:"):
                parse_schedule(spec)


if __name__ == "__main__":
    unittest.main()
PY
