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
        self.clock[0] = datetime(2026, 1, 1, 0, 7, tzinfo=UTC)
        self.target_state[0] = "idle"
        self.runner.tick()
        self.assertEqual(len(self.sent), 1)

    def test_usage_denial_is_a_hard_skip(self):
        self.runner.usage = lambda *args: (False, "usage-gate: weekly 91%", {"decision": "denied"})
        self.runner.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.events()[-1]["event"], "skipped")
        self.assertIn("weekly", self.events()[-1]["reason"])

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
