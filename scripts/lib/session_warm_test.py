"""Decision 15 with an injected clock: quiet hours, warm_plan() and the transcript tail."""
import json
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import session_dispatch as d
import session_warm as warm

UTC = timezone.utc
T0 = datetime(2026, 10, 30, 12, 0, tzinfo=UTC)
POLICY = warm.policy_from(None)


def idle_for(**delta):
    return (T0 - timedelta(**delta)).isoformat()


def facts(minutes=50, **changes):
    """An idle Claude orchestrator with a large context and a live Lead."""
    return {"agent": "claude", "state": "idle", "idle_since": idle_for(minutes=minutes), "active": True, "paused": False,
            "context_tokens": 180000, "warmed_at": None, "compacted_at": None, **changes}


def policy(**changes):
    return {**POLICY, **changes}


def local(hour, minute=0):
    """The wall clock of this host, whatever zone the test runs in."""
    return datetime(2026, 10, 30, hour, minute).astimezone()


def usage(total=180000):
    return {"input_tokens": 2, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": total - 1002,
            "output_tokens": 500}


def assistant(total=180000, **fields):
    return {"type": "assistant", "isSidechain": False, "message": {"model": "claude-opus-5-5", "usage": usage(total)},
            **fields}


def boundary(post=17809):
    return {"type": "system", "subtype": "compact_boundary", "isSidechain": False,
            "compactMetadata": {"trigger": "manual", "preTokens": 180000, "postTokens": post}}


def tail(*rows):
    return b"".join(json.dumps(row).encode() + b"\n" for row in rows)


class Windows(unittest.TestCase):
    def test_a_window_parses_to_minutes(self):
        self.assertEqual(warm.parse_window("22:00-07:00"), (1320, 420))
        self.assertEqual(warm.parse_window("09:15-17:45"), (555, 1065))

    def test_a_malformed_window_is_refused(self):
        for bad in ("25:00-07:00", "22:60-07:00", "22:00", "22:00-07", "7:00-08:00", "22:00-07:00\n", " 22:00-07:00",
                    "22:00 - 07:00", "١٢:٠٠-٠٧:٠٠", "07:00-07:00", "", None, 2200, True):
            self.assertFalse(warm.is_window(bad), bad)
            with self.assertRaises(ValueError, msg=bad) as caught:
                warm.parse_window(bad)
            self.assertIn(repr(bad), str(caught.exception))

    def test_a_window_across_midnight(self):
        windows = ["22:00-07:00"]
        for hour, minute, inside in ((21, 59, False), (22, 0, True), (23, 30, True), (0, 0, True), (6, 59, True),
                                     (7, 0, False), (12, 0, False)):
            self.assertEqual(warm.quiet_window(windows, local(hour, minute)) == "22:00-07:00", inside, (hour, minute))

    def test_a_window_within_a_day(self):
        windows = ["12:30-13:30"]
        for hour, minute, inside in ((12, 29, False), (12, 30, True), (13, 29, True), (13, 30, False)):
            self.assertEqual(warm.quiet_window(windows, local(hour, minute)) == "12:30-13:30", inside, (hour, minute))

    def test_the_first_matching_window_is_named_and_none_is_quiet(self):
        self.assertEqual(warm.quiet_window(["01:00-02:00", "12:00-13:00"], local(12, 5)), "12:00-13:00")
        self.assertIsNone(warm.quiet_window([], local(12, 5)))

    def test_an_aware_moment_is_read_on_the_local_wall_clock(self):
        moment = local(23, 30).astimezone(UTC)
        self.assertEqual(warm.quiet_window(["22:00-07:00"], moment), "22:00-07:00")


class Config(unittest.TestCase):
    def test_a_malformed_window_is_named_by_validate(self):
        errors = d.config_errors({"session_dispatch": {"wake": {"quiet_hours": ["22:00-07:00", "25:00-07:00"]}}})
        self.assertEqual(len(errors), 1)
        self.assertIn("session_dispatch.wake.quiet_hours", errors[0])
        self.assertIn("'25:00-07:00'", errors[0])

    def test_a_list_is_required(self):
        errors = d.config_errors({"session_dispatch": {"wake": {"quiet_hours": "22:00-07:00"}}})
        self.assertIn("'22:00-07:00'", errors[0])

    def test_the_defaults(self):
        self.assertEqual(POLICY, {"keep_warm": True, "keep_warm_after": 3000, "quiet_hours": [],
                                  "precompact_after": 3000, "precompact_min_tokens": 100000})

    def test_the_block_sets_the_policy(self):
        value = warm.policy_from({"precompact_after": "40m", "precompact_min_tokens": 5,
                                  "wake": {"keep_warm": False, "keep_warm_after": "30m", "quiet_hours": ["01:00-02:00"]}})
        self.assertEqual(value, {"keep_warm": False, "keep_warm_after": 1800, "quiet_hours": ["01:00-02:00"],
                                 "precompact_after": 2400, "precompact_min_tokens": 5})


class Decision15Table(unittest.TestCase):
    """Every row of the table, at noon outside any window."""

    def test_active_keeps_the_cache_warm_and_does_not_compact(self):
        self.assertEqual(warm.warm_plan(facts(), POLICY, T0), warm.KEEP_WARM)

    def test_nothing_active_compacts(self):
        self.assertEqual(warm.warm_plan(facts(active=False), POLICY, T0), warm.COMPACT)

    def test_quiet_hours_compact_even_with_active_work(self):
        now = local(23, 0)
        self.assertEqual(warm.warm_plan(facts(idle_since=(now - timedelta(minutes=50)).isoformat()),
                                        policy(quiet_hours=["22:00-07:00"]), now), warm.COMPACT)

    def test_a_pause_forces_the_compaction_branch(self):
        self.assertEqual(warm.warm_plan(facts(paused=True), POLICY, T0), warm.COMPACT)


class KeepWarm(unittest.TestCase):
    def test_not_before_the_interval(self):
        self.assertIsNone(warm.warm_plan(facts(minutes=49), POLICY, T0))

    def test_inside_the_margin_a_refused_send_can_retry(self):
        self.assertEqual(warm.warm_plan(facts(minutes=59), POLICY, T0), warm.KEEP_WARM)

    def test_a_lapsed_cache_is_left_alone(self):
        self.assertIsNone(warm.warm_plan(facts(minutes=60), POLICY, T0))

    def test_once_per_interval(self):
        self.assertIsNone(warm.warm_plan(facts(minutes=55, warmed_at=idle_for(minutes=2)), POLICY, T0))

    def test_a_turn_after_the_keep_warm_starts_a_new_interval(self):
        turn = facts(minutes=50, warmed_at=idle_for(minutes=100))
        self.assertEqual(warm.warm_plan(turn, POLICY, T0), warm.KEEP_WARM)

    def test_a_real_wake_resets_the_interval(self):
        self.assertIsNone(warm.warm_plan(facts(minutes=18), POLICY, T0))

    def test_keep_warm_can_be_turned_off(self):
        off = policy(keep_warm=False)
        self.assertIsNone(warm.warm_plan(facts(), off, T0))
        self.assertEqual(warm.warm_plan(facts(active=False), off, T0), warm.COMPACT)

    def test_an_unknown_activity_sends_nothing(self):
        self.assertIsNone(warm.warm_plan(facts(active=None), POLICY, T0))

    def test_the_interval_is_configured(self):
        self.assertEqual(warm.warm_plan(facts(minutes=30), policy(keep_warm_after=1800), T0), warm.KEEP_WARM)


class Compaction(unittest.TestCase):
    def test_a_lapsed_cache_is_not_compacted(self):
        self.assertIsNone(warm.warm_plan(facts(minutes=70, active=False), POLICY, T0))

    def test_not_before_precompact_after(self):
        self.assertIsNone(warm.warm_plan(facts(minutes=49, active=False), POLICY, T0))

    def test_once_per_idle_period(self):
        done = facts(active=False, compacted_at=idle_for(minutes=1))
        self.assertIsNone(warm.warm_plan(done, POLICY, T0))

    def test_a_new_idle_period_may_compact_again(self):
        again = facts(active=False, compacted_at=idle_for(minutes=120))
        self.assertEqual(warm.warm_plan(again, POLICY, T0), warm.COMPACT)

    def test_a_small_context_is_left_alone(self):
        self.assertIsNone(warm.warm_plan(facts(active=False, context_tokens=100000), POLICY, T0))
        self.assertEqual(warm.warm_plan(facts(active=False, context_tokens=100001), POLICY, T0), warm.COMPACT)

    def test_an_unreadable_size_skips_it(self):
        for size in (None, "180000", True, -1, 1.5):
            self.assertIsNone(warm.warm_plan(facts(active=False, context_tokens=size), POLICY, T0), size)


class NeverSent(unittest.TestCase):
    def test_only_an_idle_session(self):
        for state in ("working", "waiting_background", "needs_input", "limit", "unknown", None):
            self.assertIsNone(warm.warm_plan(facts(state=state), POLICY, T0), state)
            self.assertIsNone(warm.warm_plan(facts(state=state, active=False), POLICY, T0), state)

    def test_only_a_claude_orchestrator(self):
        for agent in ("codex", "pi", "antigravity", None):
            self.assertIsNone(warm.warm_plan(facts(agent=agent), POLICY, T0), agent)
            self.assertIsNone(warm.warm_plan(facts(agent=agent, active=False), POLICY, T0), agent)

    def test_an_unreadable_or_future_turn(self):
        for stamp in (None, "soon", idle_for(minutes=-5)):
            self.assertIsNone(warm.warm_plan(facts(idle_since=stamp), POLICY, T0), stamp)


class Latest(unittest.TestCase):
    def test_the_newest_readable_stamp(self):
        old, new = idle_for(minutes=9), idle_for(minutes=1)
        self.assertEqual(warm.latest(old, None, "junk", new, 7), new)
        self.assertIsNone(warm.latest(None, "junk"))


class ContextTokens(unittest.TestCase):
    def test_the_last_assistant_turn(self):
        self.assertEqual(warm.context_tokens(tail(assistant(90000), assistant(120000), {"type": "system"})), 120000)

    def test_the_output_tokens_do_not_count(self):
        self.assertEqual(warm.context_tokens(tail(assistant(50000))), 50000)

    def test_a_subagent_turn_is_not_this_context(self):
        self.assertEqual(warm.context_tokens(tail(assistant(90000), assistant(5000, isSidechain=True))), 90000)

    def test_a_synthetic_turn_with_no_usage_is_skipped(self):
        empty = {"type": "assistant", "message": {"model": "<synthetic>", "usage": {"input_tokens": 0}}}
        self.assertEqual(warm.context_tokens(tail(assistant(90000), empty)), 90000)

    def test_a_compaction_ends_the_older_turns(self):
        self.assertEqual(warm.context_tokens(tail(assistant(180000), boundary(17809))), 17809)
        self.assertEqual(warm.context_tokens(tail(boundary(17809), assistant(60000))), 60000)

    def test_a_boundary_without_a_size_is_unreadable(self):
        broken = {"type": "system", "subtype": "compact_boundary", "compactMetadata": {}}
        self.assertIsNone(warm.context_tokens(tail(assistant(180000), broken)))

    def test_a_cut_first_line_and_junk_lines_are_skipped(self):
        data = b'ge":{"input_tokens":1}}}\n' + tail(assistant(90000)) + b"{not json\n" + b"[" * 200000 + b"\n[1]\n"
        self.assertEqual(warm.context_tokens(data), 90000)

    def test_nothing_usable_is_none(self):
        for data in (b"", b"\n\n", tail({"type": "user"}), b"\xff\xfe\n",
                     tail({"type": "assistant", "message": {"usage": {"input_tokens": "9"}}}),
                     tail({"type": "assistant", "message": {"usage": {"input_tokens": True}}}),
                     tail({"type": "assistant", "message": "text"})):
            self.assertIsNone(warm.context_tokens(data), data)


class Doctor(unittest.TestCase):
    def line(self, value, active_policy=POLICY, now=T0):
        return warm.status_line(value, active_policy, now)

    def test_the_settings_are_stated(self):
        self.assertIn("keep-warm after 50m", self.line(facts(minutes=10)))
        self.assertIn("keep-warm off", self.line(facts(minutes=10), policy(keep_warm=False)))
        self.assertIn("quiet hours none", self.line(facts(minutes=10)))

    def test_a_window_says_whether_it_applies(self):
        windows = policy(quiet_hours=["22:00-07:00"])
        self.assertIn("quiet hours 22:00-07:00;", self.line(facts(minutes=10), windows, local(12)))
        self.assertIn("quiet hours 22:00-07:00 (in force);", self.line(facts(minutes=10), windows, local(23)))

    def test_the_next_compaction_has_a_time(self):
        line = self.line(facts(minutes=10))
        self.assertIn("next compaction", line)
        self.assertIn((T0 + timedelta(minutes=40)).astimezone().strftime("%H:%M"), line)

    def test_each_reason_for_no_compaction(self):
        for value, reason in ((facts(agent="pi"), "not a Claude orchestrator"),
                              (facts(state="working"), "orchestrator working"),
                              (facts(minutes=70), "the cache has lapsed"),
                              (facts(context_tokens=None), "context size unknown"),
                              (facts(context_tokens=5000), "context 5000 is below 100000"),
                              (facts(idle_since=None), "no turn end recorded"),
                              (facts(compacted_at=idle_for(minutes=1)), "already compacted")):
            self.assertIn(f"no compaction due ({reason})", self.line(value), reason)


if __name__ == "__main__":
    unittest.main()
