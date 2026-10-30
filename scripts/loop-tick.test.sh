#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONPATH="$ROOT/scripts/lib${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import loop_runner
import loop_state

UTC = timezone.utc


class LoopTickTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.defs = self.root / ".nogging/loops.json"
        self.prompt = self.root / ".nogging/loops/night-work.md"
        self.prompt.parent.mkdir(parents=True)
        self.prompt.write_text("Review the work queue and report briefly.")
        self.defs.parent.mkdir(parents=True, exist_ok=True)
        self.defs.write_text(json.dumps({
            "schema_version": 1, "timezone": "UTC",
            "loops": {"night-work": {"schedule": {"every": "5m", "start": "00:00"},
                                      "run": {"mode": "send", "target": "orchestrator"}}}}))
        self.config = __import__("loop_config").load(self.defs)
        self.anchor = datetime(2026, 1, 1, tzinfo=UTC)
        loop_state.approve(self.root, self.defs, self.config, "night-work",
                           at=self.anchor.isoformat(), user="operator")
        self.clock = [datetime(2026, 1, 1, 0, 6, tzinfo=UTC)]
        self.target_record = {"name": "orchestrator", "role": "orchestrator",
                              "agent": "claude", "state": "running"}
        self.target_state = ["idle"]
        self.sent = []

        def usage(agent, model, options):
            if options.get("deny"):
                return False, "usage-gate: weekly 91% (cap 90%), resets tomorrow", {
                    "decision": "denied", "windows": []}
            return True, None, {"decision": "admitted", "windows": []}

        self.runner = loop_runner.LoopRunner(
            self.root, self.defs, target=lambda: (self.target_record, self.target_state[0]),
            usage=usage, send=lambda rec, msg: self.sent.append((rec, msg)),
            now=lambda: self.clock[0], host="test-host")

    def events(self):
        path = loop_runner.event_path(self.root)
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_idle_target_gets_one_verified_send_then_completes_after_two_idle_ticks(self):
        self.runner.tick()
        self.assertEqual(len(self.sent), 1)
        self.assertIn("[nogg loop night-work run night-work-20260101T000500Z]", self.sent[0][1])
        self.assertEqual([row["event"] for row in self.events()], ["starting", "delivered"])
        self.clock[0] = datetime(2026, 1, 1, 0, 7, tzinfo=UTC)
        self.runner.tick()
        self.assertEqual(self.events()[-1]["event"], "delivered")
        self.clock[0] = datetime(2026, 1, 1, 0, 8, tzinfo=UTC)
        self.runner.tick()
        self.assertEqual(self.events()[-1]["event"], "completed")

    def test_busy_defers_without_sending_and_later_retries_before_deadline(self):
        self.target_state[0] = "working"
        self.runner.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.events()[-1]["reason"], "target-busy")
        self.assertEqual(self.events()[-1]["run_id"], "night-work-20260101T000500Z")
        self.clock[0] = datetime(2026, 1, 1, 0, 7, tzinfo=UTC)
        self.runner.tick()
        self.assertEqual(sum(row["event"] == "deferred" for row in self.events()), 1)
        self.clock[0] = datetime(2026, 1, 1, 0, 7, tzinfo=UTC)
        self.target_state[0] = "idle"
        self.runner.tick()
        self.assertEqual(len(self.sent), 1)

    def test_run_now_bypasses_schedule_but_still_skips_a_busy_target(self):
        self.clock[0] = datetime(2026, 1, 1, 0, 1, tzinfo=UTC)
        self.target_state[0] = "working"
        self.runner.run_now("night-work")
        self.assertEqual(self.sent, [])
        self.assertEqual(self.events()[-1]["trigger"], "manual")
        self.assertEqual(self.events()[-1]["event"], "skipped")
        self.assertEqual(self.events()[-1]["reason"], "target-busy")
        self.assertNotIn("deferred", loop_state.read_state(self.root)["loops"]["night-work"])

    def test_run_now_can_start_before_the_next_scheduled_slot(self):
        self.clock[0] = datetime(2026, 1, 1, 0, 1, tzinfo=UTC)
        self.runner.run_now("night-work")
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.events()[-1]["trigger"], "manual")
        self.assertEqual(self.events()[-1]["event"], "delivered")

    def test_transient_failure_retries_at_two_minutes_and_keeps_the_slot_id(self):
        raw = json.loads(self.defs.read_text())
        raw["loops"]["night-work"]["schedule"] = {"at": ["00:05"]}
        self.defs.write_text(json.dumps(raw))
        config = __import__("loop_config").load(self.defs)
        loop_state.approve(self.root, self.defs, config, "night-work",
                           at=self.anchor.isoformat(), user="operator")
        calls = []

        class TemporarySendError(RuntimeError):
            transient = True

        def send(record, message):
            calls.append(message)
            if len(calls) == 1:
                raise TemporarySendError("delivery timed out")

        self.runner.send = send
        self.runner.tick()
        self.assertEqual(self.events()[-1]["event"], "retry-scheduled")
        self.assertEqual(self.events()[-1]["run_id"], "night-work-20260101T000500Z")
        self.clock[0] = datetime(2026, 1, 1, 0, 7, tzinfo=UTC)
        self.runner.tick()
        self.assertEqual(len(calls), 1)
        self.clock[0] = datetime(2026, 1, 1, 0, 8, tzinfo=UTC)
        self.runner.tick()
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.events()[-1]["event"], "delivered")

    def test_transient_start_attempts_are_bounded_and_do_not_restart_forever(self):
        raw = json.loads(self.defs.read_text())
        raw["loops"]["night-work"]["schedule"] = {"at": ["00:05"]}
        self.defs.write_text(json.dumps(raw))
        config = __import__("loop_config").load(self.defs)
        loop_state.approve(self.root, self.defs, config, "night-work",
                           at=self.anchor.isoformat(), user="operator")
        calls = []

        class TemporarySendError(RuntimeError):
            transient = True

        def send(record, message):
            calls.append(message)
            raise TemporarySendError("delivery timeout")

        self.runner.send = send
        for minute in (6, 8, 12):
            self.clock[0] = datetime(2026, 1, 1, 0, minute, tzinfo=UTC)
            self.runner.tick()
        self.assertEqual(len(calls), 3)
        self.assertEqual([row["event"] for row in self.events()].count("retry-scheduled"), 2)
        self.assertEqual(self.events()[-1]["event"], "failed")
        state = loop_state.read_state(self.root)["loops"]["night-work"]
        self.assertFalse(state.get("retry"))
        self.assertEqual(state["consecutive_failures"], 1)

    def test_stale_send_run_is_unconfirmed_and_the_orchestrator_keeps_running(self):
        self.runner.tick()
        self.target_state[0] = "working"
        self.clock[0] = datetime(2026, 1, 1, 1, 7, tzinfo=UTC)
        self.runner.tick()
        events = [row["event"] for row in self.events()]
        self.assertEqual(events[events.index("stale") + 1], "unconfirmed")
        self.assertNotIn("stopped-stale", events)
        self.assertFalse(loop_state.read_state(self.root)["loops"]["night-work"].get("consecutive_failures"))

    def test_run_now_does_not_record_a_scheduler_tick(self):
        self.runner.run_now("night-work")
        self.assertNotIn("last_tick", loop_state.read_state(self.root))

    def test_failed_slots_suspend_at_the_configured_threshold(self):
        raw = json.loads(self.defs.read_text())
        raw["scheduler"] = {"suspend_after_failures": 2}
        self.defs.write_text(json.dumps(raw))
        base = {"loop": "night-work", "run_id": "night-work-test",
                "slot": "2026-01-01T00:05:00Z", "trigger": "scheduled",
                "mode": "send"}
        item = {}
        self.runner._failure(item, "night-work", base, self.clock[0], "failed one")
        self.assertNotIn("suspended", item)
        self.runner._failure(item, "night-work", base, self.clock[0], "failed two")
        self.assertTrue(item["suspended"])
        self.assertEqual(self.events()[-1]["event"], "suspended")

    def test_due_slots_coalesce_to_one_latest_candidate(self):
        self.clock[0] = datetime(2026, 1, 1, 0, 16, tzinfo=UTC)
        self.runner.tick()
        missed = [row for row in self.events() if row["event"] == "missed"]
        self.assertEqual(len(missed), 1)
        self.assertEqual(missed[0]["count"], 2)
        self.assertEqual(self.events()[-1]["slot"], "2026-01-01T00:15:00Z")

    def test_slot_past_its_grace_deadline_is_not_sent(self):
        self.clock[0] = datetime(2026, 1, 1, 0, 8, tzinfo=UTC)
        self.runner.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.events()[-1]["event"], "missed")
        self.assertEqual(self.events()[-1]["reason"], "deadline")

    def test_usage_denial_is_a_hard_skip(self):
        self.runner.usage = lambda *args: (False, "usage-gate: weekly 91%", {"decision": "denied"})
        self.runner.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.events()[-1]["event"], "skipped")
        self.assertIn("weekly", self.events()[-1]["reason"])
        self.assertEqual(self.events()[-1]["run_id"], "night-work-20260101T000500Z")

    def test_missing_target_is_not_started(self):
        self.target_record = None
        self.target_state[0] = "ended"
        self.runner.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.events()[-1]["reason"], "target-not-running")

    def test_tick_lock_is_nonblocking_and_event_log_rotates(self):
        path = loop_runner.event_path(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * (loop_runner.LOG_MAX - 2))
        loop_runner.append_event(self.root, {"at": "now", "loop": "x", "event": "skipped"})
        self.assertTrue(path.with_name(path.name + ".1").exists())
        self.assertLessEqual(path.stat().st_size, loop_runner.LOG_MAX)


unittest.main()
PY
