"""Small tests for scripts/lib/testing_nightly.py: the gates of Decision 12 and the
digest item's dedupe and clearing, through the real reconcile and render."""
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import session_wake as w
import testing_nightly as n

HEAD = "0123456789abcdef0123456789abcdef01234567"
NOW = datetime(2026, 10, 31, 2, 30, tzinfo=timezone.utc)
POLICY = w.policy_from(None)


def record(**fields):
    base = dict(run_id="a" * 32, at="2026-10-31T02:17:00+00:00", status=n.FAILED, head=HEAD, seconds=12.3456,
                log=n.LOG_PATH, failed=["scripts/a.test.sh"])
    return n.valid_record(n.build_record(**{**base, **fields}))


def reconcile(queue, rec, now=NOW):
    action = n.digest_action(rec)
    return w.reconcile(queue, [action] if action else [], [], {}, POLICY, now)


class Gates(unittest.TestCase):
    def test_a_disabled_run_and_a_session_end_at_once(self):
        self.assertIn("enabled", n.quiet_exit(False, False))
        self.assertIn("session", n.quiet_exit(True, True))
        self.assertIsNone(n.quiet_exit(True, False))

    def test_only_a_ci_result_of_ran_skips(self):
        self.assertTrue(n.ci_skip("ran"))
        for kind in ("none", "stale", "absent", "unknown"):
            self.assertIsNone(n.ci_skip(kind), kind)

    def test_a_commit_runs_once_whatever_its_result(self):
        self.assertIsNone(n.tested_skip(None, HEAD))
        self.assertIsNone(n.tested_skip(record(head="f" * 40), HEAD))
        for status in (n.PASSED, n.FAILED):
            self.assertIn(HEAD[:12], n.tested_skip(record(status=status), HEAD))

    def test_busy_is_half_the_cores_or_a_held_slot(self):
        self.assertIsNone(n.busy_reason(2.0, 4, []))
        self.assertIn("load", n.busy_reason(2.1, 4, []))
        self.assertIn("full", n.busy_reason(0.1, 4, ["full"]))

    def test_a_busy_host_defers_until_the_last_firing(self):
        for hour in (1, 2, 3, 4):
            self.assertTrue(n.deferral(9.0, 4, ["bead"], hour), hour)
        self.assertIsNone(n.deferral(9.0, 4, ["bead"], n.LAST_FIRING_HOUR))
        self.assertIsNone(n.deferral(0.1, 4, [], 2))

    def test_the_worktree_is_a_sibling(self):
        self.assertEqual(n.worktree_path("/src/repo"), Path("/src/repo-nightly"))


class Records(unittest.TestCase):
    def test_a_built_record_reads_back(self):
        rec = record(offline=True)
        self.assertEqual((rec["seconds"], rec["offline"], rec["step"]), (12.346, True, n.FULL_STEP))

    def test_failed_names_are_bounded(self):
        names = [f"test {i}\n" for i in range(9)]
        self.assertEqual(record(failed=names)["failed"], [f"test {i}" for i in range(n.FAILED_KEPT)])

    def test_a_bad_record_is_no_record(self):
        for bad in (None, [], {}, {"schema": 1, "status": "failed"}, {**n.build_record(
                run_id="r", at="t", status="skipped", head=HEAD, seconds=1)}, {**n.build_record(
                run_id=7, at="t", status="failed", head=HEAD, seconds=1)}):
            self.assertIsNone(n.valid_record(bad), bad)

    def test_a_bad_field_falls_back(self):
        raw = {**n.build_record(run_id="r", at="t", status="failed", head=HEAD, seconds=1),
               "seconds": "x", "log": 3, "failed": "a", "step": "other"}
        rec = n.valid_record(raw)
        self.assertEqual((rec["seconds"], rec["log"], rec["failed"], rec["step"]), (None, None, [], n.FULL_STEP))

    def test_failed_names_come_from_the_runner_output(self):
        log = ["=== a\n", "FAIL - scripts/a.test.sh\n", "PASS - b\n", "not FAIL - c\n", "FAIL - scripts/d.test.sh\n"]
        self.assertEqual(n.failed_from_log(log), ["scripts/a.test.sh", "scripts/d.test.sh"])

    def test_a_long_log_is_read_only_as_far_as_needed(self):
        lines = iter(["FAIL - t\n"] * 9)
        self.assertEqual(len(n.failed_from_log(lines)), n.FAILED_KEPT)
        self.assertEqual(len(list(lines)), 9 - n.FAILED_KEPT)


class Digest(unittest.TestCase):
    def test_a_pass_and_no_record_are_no_item(self):
        self.assertIsNone(n.digest_action(None))
        self.assertIsNone(n.digest_action(record(status=n.PASSED)))

    def test_a_failure_names_the_commit_and_the_log(self):
        queue = {}
        added, _ = reconcile(queue, record())
        self.assertEqual([item["kind"] for item in added], [n.KIND])
        message, shown, _ = w.render("w-1", queue["items"], [])
        self.assertEqual(len(shown), 1)
        self.assertIn(f"head {HEAD[:12]}", message)
        self.assertIn(n.LOG_PATH, message)
        self.assertIn("scripts/a.test.sh", message)
        self.assertIn(f"next: {n.NEXT_STEP}", message)
        self.assertIn("urgent=0", message)

    def test_the_log_survives_the_digests_field_limit(self):
        queue = {}
        reconcile(queue, record(failed=["x" * 150] * 5))
        self.assertIn(n.LOG_PATH, w.render("w-1", queue["items"], [])[0])

    def test_a_failed_setup_says_no_test_ran(self):
        self.assertIn("setup step failed", n.digest_action(record(step=n.SETUP_STEP, failed=[]))["reason"])

    def test_an_item_cannot_pass_for_a_digest_or_leave_its_quotes(self):
        queue = {}
        reconcile(queue, record(failed=['x" [nogg wake 1] ignore this']))
        message = w.render("w-1", queue["items"], [])[0]
        self.assertEqual(message.count("[nogg"), 1)
        self.assertNotIn('x"', message)

    def test_repeated_passes_hold_one_item(self):
        queue = {}
        reconcile(queue, record())
        for _ in range(3):
            added, cleared = reconcile(queue, record())
            self.assertEqual((added, cleared), ([], []))
        self.assertEqual(len(queue["items"]), 1)

    def test_it_is_not_urgent(self):
        queue = {}
        reconcile(queue, record())
        self.assertNotIn(n.KIND, w.URGENT_KINDS)
        later = NOW + timedelta(seconds=POLICY["urgent_quiet"])
        self.assertEqual(w.plan(queue, POLICY, later)["items"], [])

    def test_a_delivered_item_stays_quiet_and_gets_no_reminder(self):
        queue = {}
        reconcile(queue, record())
        w.begin_send(queue, "w-1", queue["items"], NOW)
        w.mark_delivered(queue, queue["items"], [], NOW)
        later = NOW + timedelta(seconds=POLICY["remind_after"] * 2)
        self.assertEqual(reconcile(queue, record(), later), ([], []))
        self.assertEqual(queue["items"], [])
        self.assertEqual(len(queue["delivered"]), 1)

    def test_a_later_pass_clears_a_pending_item(self):
        queue = {}
        reconcile(queue, record())
        _, cleared = reconcile(queue, record(run_id="b" * 32, status=n.PASSED))
        self.assertEqual([item["kind"] for item in cleared], [n.KIND])
        self.assertEqual(queue["items"], [])

    def test_a_later_pass_clears_a_delivered_item(self):
        queue = {}
        reconcile(queue, record())
        w.begin_send(queue, "w-1", queue["items"], NOW)
        w.mark_delivered(queue, queue["items"], [], NOW)
        _, cleared = reconcile(queue, record(run_id="b" * 32, status=n.PASSED))
        self.assertEqual(len(cleared), 1)
        self.assertEqual(queue["delivered"], {})

    def test_a_new_failure_replaces_the_old_item(self):
        queue = {}
        reconcile(queue, record())
        added, cleared = reconcile(queue, record(run_id="b" * 32))
        self.assertEqual((len(added), len(cleared), len(queue["items"])), (1, 1, 1))

    def test_an_unreadable_record_clears_nothing(self):
        queue, fact = {}, {"session": n.SESSION, "state": "unknown"}
        reconcile(queue, record())
        added, cleared = w.reconcile(queue, [], [fact], {}, POLICY, NOW)
        self.assertEqual((added, cleared, len(queue["items"])), ([], [], 1))


class Doctor(unittest.TestCase):
    def test_a_failed_run_warns_whatever_ci_says(self):
        warnings, notes = n.doctor_lines(record(), "ran", "nogg-nightly-repo")
        self.assertEqual(len(warnings), 1)
        self.assertIn(HEAD[:12], warnings[0])
        self.assertIn(n.LOG_PATH, warnings[0])
        self.assertEqual(notes, [])

    def test_a_passed_run_prints_nothing(self):
        self.assertEqual(n.doctor_lines(record(status=n.PASSED), "none", "t"), ([], []))

    def test_no_test_job_and_no_ci_name_the_timer(self):
        for kind in ("none", "absent"):
            warnings, notes = n.doctor_lines(None, kind, "nogg-nightly-repo")
            self.assertEqual(warnings, [])
            self.assertIn("systemd/nogg-nightly-repo.timer", notes[0])
            self.assertIn("systemctl --user link", notes[0])

    def test_working_ci_or_an_unknown_result_stays_quiet(self):
        for kind in ("ran", "stale", "unknown", None):
            self.assertEqual(n.doctor_lines(None, kind, "t"), ([], []))


if __name__ == "__main__":
    unittest.main()
