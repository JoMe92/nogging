#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONPATH="$ROOT/scripts/lib${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import contextlib
import io
import json
import tempfile
from types import SimpleNamespace
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import loop_cli
import loop_config
import loop_runner
import loop_state

UTC = timezone.utc


class FakeSessions:
    """The launch-mode operations, recording calls instead of starting sessions."""

    def __init__(self):
        self.starts, self.retired = [], []
        self.failure, self.retire_failure, self.adopted, self.on_start = None, None, None, None
        self.states = {}

    def model(self, run):
        return run.get("model", "stub-model")

    def start(self, name, run, run_id, message):
        self.starts.append(run_id)
        if self.on_start:
            self.on_start()
        if self.failure:
            raise self.failure
        return f"sf-loop-{name}"

    def state(self, session):
        return self.states.get(session, "working")

    def retire(self, run_id, reason, session=None):
        if self.retire_failure:
            raise self.retire_failure
        self.retired.append(run_id)
        return "/archive/run.log"

    def adopt(self, run_id):
        return self.adopted


def transient_error(text="kickoff refused"):
    exc = RuntimeError(text)
    exc.transient = True
    return exc


class LaunchPolicyTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.defs = self.root / ".nogging/loops.json"
        self.clock = [datetime(2026, 1, 1, 0, 6, tzinfo=UTC)]
        self.sessions = FakeSessions()
        self.runner = loop_runner.LoopRunner(
            self.root, self.defs, target=lambda: (None, "ended"), sessions=self.sessions,
            usage=lambda *args: (True, None, {"decision": "admitted", "windows": []}),
            send=lambda rec, msg: None, now=lambda: self.clock[0], host="test-host")

    def define(self, loops, scheduler=None):
        self.defs.parent.mkdir(parents=True, exist_ok=True)
        (self.root / ".nogging/loops").mkdir(exist_ok=True)
        raw = {"schema_version": 1, "timezone": "UTC", "loops": loops}
        if scheduler:
            raw["scheduler"] = scheduler
        self.defs.write_text(json.dumps(raw))
        config = loop_config.load(self.defs)
        for name in loops:
            (self.root / f".nogging/loops/{name}.md").write_text("Report the queue.\n")
            loop_state.approve(self.root, self.defs, config, name, at="2026-01-01T00:00:00Z", user="operator")

    def loop(self, schedule=None, **run):
        return {"schedule": schedule or {"at": ["00:05"], "grace": 3600},
                "run": {"mode": "launch", "agent": "codex", "tier": "routine", **run}}

    def at(self, minute):
        self.clock[0] = datetime(2026, 1, 1, tzinfo=UTC) + timedelta(minutes=minute)

    def events(self, name):
        path = loop_runner.event_path(self.root)
        rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [row for row in rows if row["loop"] == name]

    def kinds(self, name):
        return [row["event"] for row in self.events(name)]

    def item(self, name):
        return loop_state.read_state(self.root)["loops"].get(name, {})

    def command(self, action, name):
        loop_cli.command(SimpleNamespace(loop_command=action, name=name), main_checkout=self.root,
                         definitions_path=self.defs, session_record=None)

    def test_a_deferred_slot_keeps_the_retry_bound_and_backoff(self):
        self.define({"alpha": self.loop(), "beta": self.loop()}, {"max_active_launch_runs": 1})
        self.runner.tick()
        self.assertEqual(self.kinds("beta"), ["deferred"])
        self.sessions.states["sf-loop-alpha"] = "idle"
        self.sessions.failure = transient_error()
        self.sessions.starts.clear()
        for minute in range(7, 25):
            self.at(minute)
            self.runner.tick()
        self.assertEqual(len(self.sessions.starts), 3, self.sessions.starts)
        self.assertEqual(self.kinds("beta").count("retry-scheduled"), 2)
        self.assertEqual(self.kinds("beta")[-1], "failed")
        self.assertEqual(self.item("beta")["consecutive_failures"], 1)

    def test_a_permanent_failure_on_a_deferred_slot_is_not_repeated(self):
        self.define({"alpha": self.loop(), "beta": self.loop()}, {"max_active_launch_runs": 1})
        self.runner.tick()
        self.sessions.states["sf-loop-alpha"] = "idle"
        self.sessions.failure = RuntimeError("refused: authority")
        self.sessions.starts.clear()
        for minute in range(7, 20):
            self.at(minute)
            self.runner.tick()
        self.assertEqual(len(self.sessions.starts), 1)

    def test_a_retirement_interrupted_by_a_crash_keeps_its_outcome(self):
        self.define({"scan": self.loop()})
        self.runner.tick()
        self.sessions.states["sf-loop-scan"] = "idle"
        self.at(7); self.runner.tick()

        class Crash(BaseException):
            pass

        self.sessions.retire_failure = Crash()
        self.at(8)
        with self.assertRaises(Crash):
            self.runner.tick()
        self.assertEqual(self.item("scan")["active_run"]["finishing"]["event"], "completed")
        self.sessions.retire_failure = None
        self.sessions.states["sf-loop-scan"] = "ended"
        self.at(9); self.runner.tick()
        self.assertEqual(self.kinds("scan")[-1], "completed")

    def test_one_loops_error_leaves_the_others_and_the_state_intact(self):
        self.define({"alpha": self.loop(), "zeta": self.loop()})
        self.runner.tick()
        self.sessions.states["sf-loop-alpha"] = "idle"
        self.sessions.states["sf-loop-zeta"] = "idle"
        self.at(7); self.runner.tick()
        real = self.sessions.state

        def broken(session):
            if "alpha" in session:
                raise ValueError("boom")
            return real(session)

        self.sessions.state = broken
        self.at(8)
        with self.assertRaises(RuntimeError):
            self.runner.tick()
        self.assertEqual(self.kinds("zeta")[-1], "completed", "a later loop was not evaluated")
        self.assertIsNone(self.item("zeta")["active_run"])
        self.assertEqual(loop_state.read_state(self.root)["tick_errors"], {"alpha": "boom"})
        self.sessions.state = real
        self.at(9); self.runner.tick()
        self.assertEqual(loop_state.read_state(self.root)["tick_errors"], {})

    def test_usage_that_cannot_be_observed_admits_nothing(self):
        self.define({"scan": self.loop()})

        def broken(*args):
            raise ValueError("invalid usage_gate")

        self.runner.usage = broken
        self.runner.tick()
        self.assertEqual(self.kinds("scan"), ["skipped"])
        self.assertEqual(self.events("scan")[-1]["reason"], "usage-gate: invalid usage_gate")
        self.assertEqual(self.sessions.starts, [])

    def test_a_definitions_file_that_vanishes_leaves_the_run_to_finish(self):
        self.define({"scan": self.loop(max_runtime="5m")})
        self.runner.tick()
        self.defs.unlink()
        self.at(7); self.runner.tick()
        self.assertEqual(self.kinds("scan")[-1], "started", "a brief gap must not kill a healthy run")
        self.assertEqual(self.sessions.retired, [])
        self.at(13); self.runner.tick()
        self.assertEqual(self.kinds("scan")[-2:], ["stale", "stopped-stale"])

    def test_operator_remove_stops_the_run_and_clears_the_state(self):
        self.define({"scan": self.loop(), "other": self.loop()})
        self.runner.tick()
        self.command("remove", "scan")
        self.at(7); self.runner.tick()
        self.assertEqual(self.events("scan")[-1]["reason"], "loop removed")
        self.assertEqual(self.sessions.retired, ["scan-20260101T000500Z"])
        self.assertNotIn("scan", loop_state.read_state(self.root)["loops"])

    def test_a_remove_during_a_launch_still_stops_the_run(self):
        self.define({"scan": self.loop()})
        self.sessions.on_start = lambda: self.command("remove", "scan")
        self.runner.tick()
        self.assertTrue(self.item("scan")["removed"])
        self.at(7); self.runner.tick()
        self.assertEqual(self.events("scan")[-1]["reason"], "loop removed")
        self.assertNotIn("scan", loop_state.read_state(self.root)["loops"])

    def test_a_loop_missing_for_one_tick_keeps_its_safety_state(self):
        self.define({"scan": self.loop(), "other": self.loop()})
        state = loop_state.read_state(self.root)
        state["loops"] = {"scan": {"paused": True, "suspended": True, "consecutive_failures": 3}}
        loop_state.write_state(self.root, state)
        definitions = self.defs.read_text()
        self.define({"other": self.loop()})
        self.runner.tick()
        self.defs.write_text(definitions)
        self.at(7); self.runner.tick()
        self.assertEqual(self.kinds("scan")[-1:], ["skipped"])
        self.assertTrue(self.item("scan")["paused"])
        self.assertEqual(self.item("scan")["consecutive_failures"], 3)

    def test_a_send_run_of_a_missing_loop_still_ends(self):
        self.define({"note": {"schedule": {"at": ["00:05"], "grace": 3600},
                              "run": {"mode": "send", "target": "orchestrator"}}})
        record = {"name": "orchestrator", "agent": "claude"}
        self.runner.target = lambda: (record, "idle")
        self.runner.tick()
        self.runner.target = lambda: (record, "working")
        self.define({})
        self.at(7); self.runner.tick()
        self.assertIsNotNone(self.item("note").get("active_run"))
        self.at(120); self.runner.tick()
        self.assertEqual(self.kinds("note")[-2:], ["stale", "unconfirmed"])
        self.assertIsNone(self.item("note")["active_run"])

    def test_an_invalid_file_keeps_the_configured_suspend_threshold(self):
        self.define({"scan": self.loop(max_runtime="5m")}, {"suspend_after_failures": 5})
        state = loop_state.read_state(self.root)
        state["loops"] = {"scan": {"consecutive_failures": 2}}
        loop_state.write_state(self.root, state)
        self.runner.tick()
        self.defs.write_text("{broken")
        self.at(13)
        with self.assertRaises(ValueError):
            self.runner.tick()
        state = self.item("scan")
        self.assertEqual(state["consecutive_failures"], 3)
        self.assertNotIn("suspended", state)

    def test_an_invalid_file_clears_the_last_ticks_loop_errors(self):
        self.define({"scan": self.loop()})
        state = loop_state.read_state(self.root)
        state["tick_errors"] = {"scan": "old"}
        loop_state.write_state(self.root, state)
        self.defs.write_text("{broken")
        with self.assertRaises(ValueError):
            self.runner.tick()
        self.assertEqual(loop_state.read_state(self.root)["tick_errors"], {})

    def test_an_invalid_definitions_file_still_stops_a_hung_run(self):
        self.define({"scan": self.loop(max_runtime="5m")})
        self.runner.tick()
        self.defs.write_text("{broken")
        self.at(13)
        with self.assertRaises(ValueError):
            self.runner.tick()
        self.assertEqual(self.kinds("scan")[-2:], ["stale", "stopped-stale"])
        self.assertIsNone(self.item("scan")["active_run"])

    def test_a_loop_moved_to_another_host_ends_its_run_here(self):
        self.define({"scan": self.loop()})
        self.runner.tick()
        self.define({"scan": {**self.loop(), "host": "another-host"}})
        self.at(7); self.runner.tick()
        self.assertEqual(self.events("scan")[-1]["reason"], "loop moved to another host")
        self.assertEqual(self.sessions.retired, ["scan-20260101T000500Z"])

    def test_an_operator_change_during_a_launch_is_not_undone(self):
        self.define({"scan": self.loop()})
        self.sessions.on_start = lambda: self.command("pause", "scan")
        self.runner.tick()
        state = self.item("scan")
        self.assertTrue(state["paused"], "the tick wrote over the pause")
        self.assertEqual(state["active_run"]["session"], "sf-loop-scan")

    def test_a_resume_during_a_tick_clears_the_suspension(self):
        self.define({"scan": self.loop(), "other": self.loop()})
        state = loop_state.read_state(self.root)
        state["loops"] = {"scan": {"suspended": True, "paused": True, "consecutive_failures": 3,
                                   "last_evaluated": "2026-01-01T00:06:00Z"}}
        loop_state.write_state(self.root, state)
        self.sessions.on_start = lambda: self.command("resume", "scan")
        self.runner.tick()
        state = self.item("scan")
        self.assertNotIn("suspended", state)
        self.assertNotIn("consecutive_failures", state)
        self.assertFalse(state["paused"])

    def test_resume_starts_the_failure_count_again(self):
        self.define({"scan": self.loop()})
        state = loop_state.read_state(self.root)
        state["loops"] = {"scan": {"suspended": True, "consecutive_failures": 3}}
        loop_state.write_state(self.root, state)
        self.command("resume", "scan")
        self.assertNotIn("consecutive_failures", self.item("scan"))

    def test_a_deferred_slot_is_skipped_at_its_deadline_while_a_run_is_active(self):
        self.define({"scan": self.loop(schedule={"at": ["00:05", "02:00"], "grace": 300}, max_runtime="12h")})
        self.runner.tick()
        self.at(121); self.runner.tick()
        self.assertEqual(self.kinds("scan")[-1], "deferred")
        self.at(125); self.runner.tick()
        self.assertEqual(self.kinds("scan")[-1], "skipped")
        self.assertEqual(self.events("scan")[-1]["reason"], "previous-run-active")

    def test_run_now_prints_why_it_did_not_start(self):
        self.define({"scan": self.loop()})
        self.runner.tick()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.runner.run_now("scan")
        self.assertEqual(output.getvalue().strip(), "skipped: previous-run-active")

    def test_reasons_are_redacted_and_bounded(self):
        self.define({"scan": self.loop()})
        self.runner.redact = lambda text: text.replace("hunter2", "<redacted>")
        self.sessions.failure = RuntimeError("token hunter2 refused\nstartup log: " + "x" * 9000)
        self.runner.tick()
        self.assertEqual(self.events("scan")[-1]["reason"], "token <redacted> refused")

    def test_a_retire_error_with_no_text_still_keeps_the_run(self):
        self.define({"scan": self.loop()})
        failure = transient_error()
        failure.unretired = ""
        self.sessions.failure = failure
        self.runner.tick()
        self.assertEqual(self.item("scan")["active_run"]["finishing"]["event"], "failed")

    def test_a_kickoff_failure_with_an_unretired_session_stays_tracked(self):
        self.define({"scan": self.loop()})
        failure = transient_error()
        failure.unretired = "cleanup refused"
        self.sessions.failure = failure
        self.runner.tick()
        state = self.item("scan")
        self.assertEqual(state["active_run"]["finishing"]["event"], "failed")
        self.assertFalse(state.get("retry"))
        self.at(7); self.runner.tick()
        self.assertEqual(self.kinds("scan")[-1], "failed")
        self.assertEqual(self.item("scan")["consecutive_failures"], 1)


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

    def test_waiting_background_target_is_deliverable_like_idle(self):
        self.target_state[0] = "waiting_background"
        self.runner.tick()
        self.assertEqual(len(self.sent), 1)
        self.assertEqual([row["event"] for row in self.events()], ["starting", "delivered"])

    def test_unknown_target_state_is_logged_as_a_target_reason_not_raw(self):
        self.target_state[0] = "some_future_state"
        self.runner.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.events()[-1]["reason"], "target-unavailable")

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

# --- TASK-SWK-006: the dispatch pass of a real tick, in a checkout with no sessions ---
source "$ROOT/scripts/lib/test-fixture-config.sh"
while IFS= read -r inherited; do
  case "$inherited" in
    NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_*|GIT_*) unset "$inherited" ;;
  esac
done < <(compgen -e)
work=$(mktemp -d); trap 'rm -rf "${work:?}"' EXIT
root="$work/root"; mkdir -p "$root/.nogging/state" "$root/scripts"
ln -s "$ROOT/scripts/lib" "$root/scripts/lib"
copy_host_config "$ROOT/.nogging/config.json" "$root/.nogging/config.json"
git -C "$root" init -q -b develop
export NOGGING_ROOT="$root"
nogg="$ROOT/scripts/nogg"
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
dispatch_block() { # dispatch_block <json>: set the block, or remove it with `null`
  python3 - "$root/.nogging/config.json" "$1" <<'PY'
import json, sys
path, block = sys.argv[1], json.loads(sys.argv[2])
config = json.load(open(path))
config.pop("session_dispatch", None)
if block is not None:
    config["session_dispatch"] = block
json.dump(config, open(path, "w"), indent=2)
PY
}
last_tick() { python3 -c '
import sys
sys.path.insert(0, sys.argv[2])
import loop_state
from pathlib import Path
print(loop_state.read_state(Path(sys.argv[1])).get("last_tick") or "none")' "$root" "$ROOT/scripts/lib"; }
passes() { [[ -f "$root/.nogging/state/dispatch/state.json" ]] && echo ran || echo none; }

dispatch_block null
out=$("$nogg" loop tick 2>&1) && ok "tick: a config with no block exits 0" || bad "tick: failed: $out"
[[ "$(passes)" == ran ]] && ok "tick: a missing block reads as on and a pass runs" || bad "tick: no pass ran"
[[ -z "$out" ]] && ok "tick: a pass with nothing to do prints nothing" || bad "tick: printed: $out"
grep -q last_pass_at "$root/.nogging/state/dispatch/state.json" && ok "tick: the pass is recorded" || bad "tick: no last pass"

rm -r "${root:?}/.nogging/state/dispatch"
dispatch_block '{"max_nudges": 1}'
"$nogg" loop tick >/dev/null
[[ "$(passes)" == ran ]] && ok "tick: a block with no enabled key reads as on" || bad "tick: no pass ran"

rm -r "${root:?}/.nogging/state/dispatch"
dispatch_block '{"enabled": false}'
"$nogg" loop tick >/dev/null
[[ "$(passes)" == none ]] && ok "tick: an explicit false runs no pass" || bad "tick: a pass ran"

before=$(last_tick); sleep 1.1
dispatch_block '{"max_nudge": 1}'
out=$("$nogg" loop tick 2>&1) && ok "tick: a failed pass does not fail the tick" || bad "tick: failed: $out"
case "$out" in *"the dispatch pass failed"*max_nudge*) ok "tick: the failure is logged" ;; *) bad "tick: no log in: $out" ;; esac
[[ "$(last_tick)" != "$before" ]] && ok "tick: the loops still ran" || bad "tick: the loops did not run"
[[ $fail -eq 0 ]] || { echo "loop-tick: checks failed" >&2; exit 1; }
