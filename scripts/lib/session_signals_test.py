import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name("session_signals.py")
spec = importlib.util.spec_from_file_location("session_signals", MODULE)
sig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sig)

STAMP = "2026-10-30T10:00:00Z"


class ExcerptTests(unittest.TestCase):
    def test_single_line_control_free_bounded_and_scrubbed(self):
        text = "a\nb\t\x07c owner@example.com " + "x" * 400
        out = sig.clean_excerpt(text, lambda s: s.replace("b", "B"))
        self.assertTrue(out.startswith("a B c ***EMAIL*** "))
        self.assertLessEqual(len(out), 300)
        self.assertNotRegex(out, r"[\x00-\x1f]")

    def test_non_text_and_blank_are_none(self):
        self.assertIsNone(sig.clean_excerpt(None))
        self.assertIsNone(sig.clean_excerpt(" \n\t "))


class PayloadTests(unittest.TestCase):
    def test_junk_oversize_and_non_object_payloads_are_empty(self):
        self.assertEqual({}, sig.read_payload(b"{broken"))
        self.assertEqual({}, sig.read_payload(b"[1, 2]"))
        self.assertEqual({}, sig.read_payload(None))
        big = b'{"error": "x", "pad": "' + b"y" * sig.STDIN_LIMIT + b'"}'
        self.assertEqual({}, sig.read_payload(big))

    def test_idle_prompt_is_not_recorded_but_questions_are(self):
        self.assertFalse(sig.is_recorded("needs_input", {"notification_type": "idle_prompt"}))
        for kind in sig.QUESTION_NOTIFICATIONS:
            self.assertTrue(sig.is_recorded("needs_input", {"notification_type": kind}))
        self.assertTrue(sig.is_recorded("needs_input", {}))
        self.assertTrue(sig.is_recorded("turn_end", {"notification_type": "idle_prompt"}))

    def test_build_event_keeps_the_whitelist_only(self):
        payload = {"error": "rate_limit", "notification_type": "permission_prompt", "unknown": "x",
                   "background_tasks": [{"status": "running"}, {"status": "completed"}],
                   "last_assistant_message": "done"}
        event = sig.build_event("s1", "turn_end", payload, STAMP, "claude")
        self.assertEqual({"schema", "timestamp", "session", "event", "source", "error",
                          "notification_type", "background_tasks", "excerpt"}, set(event))
        self.assertEqual((2, "claude-hook", 1, "done"),
                         (event["schema"], event["source"], event["background_tasks"], event["excerpt"]))

    def test_build_event_survives_a_hostile_payload(self):
        event = sig.build_event("s1", "turn_end", {"error": 5, "background_tasks": "many",
                                                   "last_assistant_message": ["x"]}, STAMP)
        self.assertEqual((None, 0, None, "hook"),
                         (event["error"], event["background_tasks"], event["excerpt"], event["source"]))

    def test_signal_needs_a_known_kind_and_a_reason(self):
        self.assertEqual("session-signal", sig.build_signal("s1", "done", "PR open", STAMP)["source"])
        with self.assertRaises(ValueError):
            sig.build_signal("s1", "maybe", "x", STAMP)
        with self.assertRaises(ValueError):
            sig.build_signal("s1", "done", "  ", STAMP)


class CompletionTests(unittest.TestCase):
    CLEAN = {"dirty": False, "upstream": True, "ahead": 0}
    SESSION = {"role": "lead", "launch_prompt": "autonomous", "agent": "pi", "kickoff_sent_at": STAMP}

    def test_gaps_from_injected_facts(self):
        done = [{"event": "done"}]
        self.assertEqual([], sig.completion_gaps(self.CLEAN, done))
        self.assertEqual(["no-signal"], sig.completion_gaps(self.CLEAN, []))
        self.assertEqual(["dirty"], sig.completion_gaps(dict(self.CLEAN, dirty=True), done))
        self.assertEqual(["unpushed"], sig.completion_gaps(dict(self.CLEAN, ahead=2), done))
        self.assertEqual(["unpushed"], sig.completion_gaps(dict(self.CLEAN, upstream=False), done))
        self.assertEqual(["no-signal"], sig.completion_gaps(None, []), "unknown git proves no git gap")

    def test_the_message_is_fixed_and_names_each_gap(self):
        text = sig.guard_message(["dirty", "unpushed"])
        self.assertTrue(text.startswith("You are ending your turn with: uncommitted changes, unpushed commits. "))
        self.assertTrue(text.endswith("Do not answer with a plan."))

    def test_guard_scope(self):
        self.assertTrue(sig.guard_applies(self.SESSION, []))
        for change in ({"role": "planning"}, {"launch_prompt": "no-autonomous-claim"},
                       {"agent": "antigravity"}, {"kickoff_sent_at": None}):
            self.assertFalse(sig.guard_applies(dict(self.SESSION, **change), []), change)
        self.assertFalse(sig.guard_applies({}, []))

    def test_guard_bounds(self):
        for payload in ({"stop_hook_active": True}, {"error": "rate_limit"}, {"background_tasks": 1}):
            self.assertFalse(sig.guard_applies(self.SESSION, [], payload), payload)

    def test_a_signal_or_error_in_this_turn_excuses_the_stop(self):
        for excuse in ("blocked", "done", "turn_error"):
            self.assertFalse(sig.guard_applies(self.SESSION, [{"event": "turn_start"}, {"event": excuse}]), excuse)
            self.assertTrue(sig.guard_applies(self.SESSION, [{"event": excuse}, {"event": "turn_end"}]), excuse)
            self.assertTrue(sig.guard_applies(self.SESSION, [{"event": excuse}, {"event": "turn_start"}]), excuse)
        self.assertTrue(sig.guard_applies(self.SESSION, [{"event": "turn_start"}, {"event": "guard_continue"}]))


class StateTests(unittest.TestCase):
    def test_state_mapping(self):
        cases = {
            ("turn_start", None): "working",
            ("turn_end", None): "idle",
            ("turn_end", 2): "waiting_background",
            ("needs_input", None): "needs_input",
            ("session_end", None): "ended",
            ("mystery", None): "unknown",
        }
        for (name, background), state in cases.items():
            record = {"event": name, "background_tasks": background}
            self.assertEqual(state, sig.event_state(record), name)
        self.assertEqual("limit", sig.event_state({"event": "turn_error", "error": "rate_limit"}))
        self.assertEqual("idle", sig.event_state({"event": "turn_error", "error": "overloaded"}))

    def test_signals_are_not_states_and_are_skipped(self):
        self.assertIsNone(sig.event_state({"event": "done"}))
        state, record = sig.latest_state([{"event": "turn_end"}, {"event": "blocked"}])
        self.assertEqual(("idle", "turn_end"), (state, record["event"]))
        self.assertEqual((None, None), sig.latest_state([{"event": "done"}]))

    def test_a_signal_is_current_until_the_next_turn_starts(self):
        rows = [{"event": "turn_end"}, {"event": "blocked", "excerpt": "x"}]
        self.assertEqual("blocked", sig.current_signal(rows)["event"])
        self.assertIsNone(sig.current_signal(rows + [{"event": "turn_start"}]))

    def test_a_guard_continuation_is_not_a_state(self):
        self.assertIsNone(sig.event_state({"event": "guard_continue"}))
        state, record = sig.latest_state([{"event": "turn_start"}, {"event": "guard_continue"}])
        self.assertEqual(("working", "turn_start"), (state, record["event"]))

    def test_read_events_skips_junk_and_missing_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "s1.events.jsonl"
            path.write_text('{"event":"turn_end"}\njunk\n{"event":5}\n[1]\n{"event":"turn_start"}\n')
            self.assertEqual(["turn_end", "turn_start"], [r["event"] for r in sig.read_events(path)])
            self.assertEqual([], sig.read_events(Path(tmp) / "none.jsonl"))


class EvidenceOrderTests(unittest.TestCase):
    def test_order_event_rollout_pane_and_unknown_stays_unknown(self):
        self.assertEqual(("idle", "event"), sig.resolve_state("idle", "idle", "idle"))
        self.assertEqual(("idle", "rollout"), sig.resolve_state(None, "idle", "unknown"))
        self.assertEqual(("limit", "pane"), sig.resolve_state(None, None, "limit"))
        self.assertEqual(("unknown", "none"), sig.resolve_state(None, None, "unknown"))
        self.assertEqual(("unknown", "none"), sig.resolve_state(None, None, None))

    def test_live_working_beats_a_stale_idle(self):
        self.assertEqual(("working", "pane"), sig.resolve_state("idle", None, "working"))
        self.assertEqual(("working", "rollout"), sig.resolve_state("idle", "working", "idle"))
        self.assertEqual(("working", "pane"), sig.resolve_state(None, "idle", "working"))

    def test_stale_needs_input_yields_to_any_live_pane_state(self):
        self.assertEqual(("idle", "pane"), sig.resolve_state("needs_input", None, "idle"))
        self.assertEqual(("needs_input", "event"), sig.resolve_state("needs_input", None, "unknown"))

    def test_an_ended_event_is_final_and_waiting_is_not_overridden(self):
        self.assertEqual(("ended", "event"), sig.resolve_state("ended", "working", "working"))
        self.assertEqual(("waiting_background", "event"), sig.resolve_state("waiting_background", None, "working"))


class HerdrEvidenceTests(unittest.TestCase):
    def test_herdr_status_meaning(self):
        self.assertEqual("needs_input", sig.herdr_state("blocked"))
        self.assertEqual("idle", sig.herdr_state("done"))
        self.assertEqual("idle", sig.herdr_state("idle"))
        self.assertEqual("working", sig.herdr_state("working"))
        self.assertIsNone(sig.herdr_state("unknown"))
        self.assertIsNone(sig.herdr_state(None))
        self.assertIsNone(sig.herdr_state("surprise"))

    def test_herdr_sits_between_rollout_and_pane(self):
        self.assertEqual(("idle", "herdr"), sig.resolve_state(None, None, "working", herdr="done"))
        self.assertEqual(("needs_input", "herdr"), sig.resolve_state(None, None, "idle", herdr="blocked"))
        self.assertEqual(("idle", "rollout"), sig.resolve_state(None, "idle", "idle", herdr="done"))
        self.assertEqual(("working", "herdr"), sig.resolve_state(None, "idle", "idle", herdr="working"))
        self.assertEqual(("idle", "event"), sig.resolve_state("idle", None, "idle", herdr="done"))

    def test_unknown_herdr_proves_nothing(self):
        self.assertEqual(("working", "pane"), sig.resolve_state(None, None, "working", herdr="unknown"))
        self.assertEqual(("unknown", "none"), sig.resolve_state(None, None, None, herdr="unknown"))

    def test_a_pi_session_on_herdr_without_a_pane_adapter_is_classified(self):
        self.assertEqual(("working", "herdr"), sig.resolve_state(None, None, None, herdr="working"))
        self.assertEqual(("idle", "herdr"), sig.resolve_state(None, None, None, herdr="idle"))

    def test_live_herdr_working_beats_a_stale_idle_event(self):
        self.assertEqual(("working", "herdr"), sig.resolve_state("idle", None, None, herdr="working"))
        self.assertEqual(("idle", "herdr"), sig.resolve_state("needs_input", None, None, herdr="done"))

    def test_the_pane_still_reports_what_herdr_cannot_express(self):
        self.assertEqual(("limit", "pane"), sig.resolve_state(None, None, "limit", herdr="idle"))
        self.assertEqual(("waiting_background", "pane"),
                         sig.resolve_state(None, None, "waiting_background", herdr="working"))


if __name__ == "__main__":
    unittest.main()
