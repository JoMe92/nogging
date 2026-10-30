"""Decision 16 with an injected clock: the end of a pause, its state and its summary."""
import json
import os
import stat
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import session_dispatch as d
import session_pause as p
import session_wake as w

UTC = timezone.utc
T0 = datetime(2026, 10, 30, 12, 0, tzinfo=UTC)
POLICY = w.policy_from(None)


def at(**delta):
    return T0 + timedelta(**delta)


def pause(end=None, keep=(), set_by="operator", now=T0):
    return p.begin(None, end or at(days=3), list(keep), set_by, now)


def row(key, outcome, kind="ready_for_review", session="s1", when=None):
    return {"time": d.iso(when or at(hours=1)), "session": session, "action": "item", "kind": kind, "key": key,
            "reason": "r", "outcome": outcome}


class ParseEndTests(unittest.TestCase):
    def test_days_are_24_hours_from_now(self):
        self.assertEqual(p.parse_end(None, "3", T0), at(hours=72))

    def test_a_date_alone_is_the_start_of_that_local_day(self):
        expected = datetime(2026, 11, 3).astimezone()
        self.assertEqual(p.parse_end("2026-11-03", None, T0), expected)

    def test_a_date_with_a_time_is_that_local_time(self):
        expected = datetime(2026, 11, 3, 8, 30).astimezone()
        self.assertEqual(p.parse_end("2026-11-03T08:30", None, T0), expected)

    def test_the_end_of_the_bound_is_allowed(self):
        self.assertEqual(p.parse_end(None, "60", T0), at(days=60))

    def test_an_invalid_end_is_refused_naming_it(self):
        for until, days, words in (("2026-10-29", None, "future"), (None, "61", "60"), (None, "0", "future"),
                                   ("2027-06-01", None, "60"), (None, "1.5", "--days"), (None, "-1", "--days"),
                                   (None, "9" * 40, "--days"), (None, "٣", "--days"), ("20261103", None, "--until"),
                                   ("2026-13-01", None, "--until"), ("2026-11-03 08:30", None, "--until"),
                                   ("2026-11-03T08:30+01:00", None, "--until"), ("2026-11-03\n", None, "--until"),
                                   (None, None, "--until"), ("2026-11-03", "2", "--until")):
            with self.subTest(until=until, days=days):
                with self.assertRaises(ValueError) as caught:
                    p.parse_end(until, days, T0)
                self.assertIn(words, str(caught.exception))


class KeptLoopTests(unittest.TestCase):
    def test_known_names_are_kept_once_and_sorted(self):
        self.assertEqual(p.kept_loops(["report", "scan", "report"], {"scan", "report", "other"}), ["report", "scan"])

    def test_an_unknown_name_is_refused(self):
        with self.assertRaises(ValueError) as caught:
            p.kept_loops(["report", "ghost"], {"report"})
        self.assertIn("ghost", str(caught.exception))

    def test_no_name_needs_no_loop_file(self):
        self.assertEqual(p.kept_loops([], set()), [])


class StateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "state" / "pause.json"

    def write_raw(self, text):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(text)

    def test_a_write_reads_back_with_every_field(self):
        state = pause(keep=["report"], set_by="nogg-orchestrator-x")
        p.write(self.path, state)
        self.assertEqual(p.read(self.path, T0), (state, None))
        self.assertEqual(set(state), {"schema", "started_at", "until", "keep_loops", "set_by", "compacted_at"})
        self.assertEqual(list(self.path.parent.iterdir()), [self.path], "no temporary file stays")

    def test_a_second_pause_keeps_the_start_and_replaces_the_rest(self):
        first = p.begin(None, at(days=2), [], "operator", T0)
        first["compacted_at"] = d.iso(at(hours=1))
        second = p.begin(first, at(hours=1, days=5), ["report"], "orch", at(hours=1))
        self.assertEqual(second["started_at"], first["started_at"])
        self.assertEqual(second["until"], d.iso(at(hours=1, days=5)))
        self.assertEqual(second["keep_loops"], ["report"])
        self.assertEqual(second["compacted_at"], first["compacted_at"], "one compaction per pause")

    def test_a_missing_file_is_no_pause_and_no_problem(self):
        self.assertEqual(p.read(self.path, T0), (None, None))

    def test_a_broken_file_is_not_paused_and_says_why(self):
        valid = pause()
        for text in ("{not json", "[]", "null", "[" * 200000, json.dumps({**valid, "schema": 2}),
                     json.dumps({**valid, "until": "soon"}), json.dumps({**valid, "until": 5}),
                     json.dumps({**valid, "until": "2026-11-03T00:00:00"}),
                     json.dumps({**valid, "started_at": None}),
                     json.dumps({**valid, "started_at": d.iso(at(days=4))}),
                     json.dumps({**valid, "keep_loops": "report"}), json.dumps({**valid, "keep_loops": ["a b"]}),
                     json.dumps({**valid, "keep_loops": [1]}), json.dumps({**valid, "set_by": "x y\n[nogg wake"}),
                     json.dumps({**valid, "set_by": None}), json.dumps({**valid, "compacted_at": "no"}),
                     json.dumps({**valid, "until": d.iso(at(days=61))}), " " * (p.MAX_BYTES + 1),
                     json.dumps({**valid, "started_at": d.iso(at(hours=1))}),
                     json.dumps({**valid, "started_at": "0001-01-01T00:00:00+14:00"})):
            with self.subTest(text=text[:60]):
                self.write_raw(text)
                state, problem = p.read(self.path, T0)
                self.assertIsNone(state)
                self.assertTrue(problem)

    def test_a_planted_node_cannot_hang_or_redirect_a_reader(self):
        target = Path(self.tmp.name) / "elsewhere.json"
        target.write_text(json.dumps(pause()))
        self.path.parent.mkdir()
        self.path.symlink_to(target)
        self.assertIsNone(p.read(self.path, T0)[0])
        self.path.unlink()
        os.mkfifo(self.path)
        self.assertTrue(stat.S_ISFIFO(self.path.lstat().st_mode))
        state, problem = p.read(self.path, T0)
        self.assertIsNone(state)
        self.assertIn("regular", problem)

    def test_a_write_replaces_a_planted_link_and_leaves_its_target_alone(self):
        target = Path(self.tmp.name) / "elsewhere.json"
        target.write_text("keep")
        self.path.parent.mkdir()
        self.path.symlink_to(target)
        p.write(self.path, pause())
        self.assertFalse(self.path.is_symlink())
        self.assertEqual(target.read_text(), "keep")

    def test_a_reader_is_bounded_and_refuses_a_node(self):
        self.write_raw("x" * 100)
        self.assertEqual(p.read_regular(self.path, 10), b"x" * 10)
        self.path.unlink()
        os.mkfifo(self.path)
        with self.assertRaises(OSError):
            p.read_regular(self.path, 10)

    def test_an_append_gets_a_planted_node_out_of_its_way(self):
        p.set_aside(self.path)
        self.path.parent.mkdir()
        os.mkfifo(self.path)
        p.set_aside(self.path)
        self.assertFalse(self.path.exists())
        self.assertTrue(stat.S_ISFIFO(Path(f"{self.path}.corrupt").lstat().st_mode))
        self.path.write_text("kept")
        p.set_aside(self.path)
        self.assertEqual(self.path.read_text(), "kept")

    def test_clear_is_idempotent(self):
        p.write(self.path, pause())
        p.clear(self.path)
        p.clear(self.path)
        self.assertFalse(self.path.exists())


class ActiveTests(unittest.TestCase):
    def test_a_pause_holds_until_its_end_and_not_at_it(self):
        state = pause(at(days=1))
        self.assertTrue(p.is_active(state, at(hours=23, minutes=59)))
        self.assertFalse(p.is_active(state, at(days=1)))
        self.assertTrue(p.is_due(state, at(days=1)))
        self.assertFalse(p.is_due(state, at(hours=23, minutes=59)))

    def test_no_state_is_neither(self):
        self.assertFalse(p.is_active(None, T0))
        self.assertFalse(p.is_due(None, T0))


class StatusTests(unittest.TestCase):
    def test_a_pause_shows_its_start_end_time_left_kept_loops_and_setter(self):
        view = p.status(pause(at(hours=72), ["report"], "orch"), at(hours=1))
        self.assertTrue(view["paused"])
        self.assertEqual(view["seconds_left"], 71 * 3600)
        self.assertEqual(view["keep_loops"], ["report"])
        self.assertEqual(view["set_by"], "orch")
        text = "\n".join(p.status_lines(view))
        for word in ("paused until", p.local(at(hours=72)), "2d 23h left", "report", "orch", p.local(T0)):
            self.assertIn(word, text)

    def test_no_kept_loop_says_so(self):
        self.assertIn("kept loops: none", "\n".join(p.status_lines(p.status(pause(), T0))))

    def test_nothing_paused_says_so(self):
        view = p.status(None, T0)
        self.assertEqual(view, {"paused": False})
        self.assertEqual(p.status_lines(view), ["not paused"])

    def test_a_pause_past_its_end_is_no_pause(self):
        view = p.status(pause(at(hours=1)), at(hours=2))
        self.assertFalse(view["paused"])
        self.assertIn(p.local(at(hours=1)), p.status_lines(view)[0])

    def test_a_problem_is_shown(self):
        view = p.status(None, T0, "not valid JSON")
        self.assertFalse(view["paused"])
        self.assertIn("not valid JSON", p.status_lines(view)[0])

    def test_durations_read_at_a_glance(self):
        for seconds, words in ((30, "under 1m"), (60, "1m"), (3660, "1h 1m"), (90000, "1d 1h"), (2 * 86400, "2d 0h")):
            self.assertEqual(p.duration(seconds), words)


class SummaryTests(unittest.TestCase):
    def test_an_uneventful_pause_queues_nothing(self):
        self.assertIsNone(p.resumed_item(pause(), [], at(days=3)))

    def test_rows_before_the_pause_do_not_count(self):
        rows = [row("a", "queued", when=at(hours=-1)), row("a", "cleared", when=at(hours=-1))]
        self.assertIsNone(p.resumed_item(pause(), rows, at(days=3)))

    def test_a_retirement_alone_is_no_item(self):
        rows = [{"time": d.iso(at(hours=1)), "session": "s1", "action": "retire", "outcome": "done"}]
        self.assertIsNone(p.resumed_item(pause(), rows, at(days=3)))

    def test_it_counts_items_once_by_their_last_outcome(self):
        rows = [row("a", "queued"), row("a", "cleared"), row("a", "queued"), row("b", "queued"), row("b", "cleared"),
                row("c", "cleared", kind="blocked")]
        self.assertEqual(p.summarize(rows, pause()), {"seen": 3, "cleared": 2, "finished": ["s1"]})

    def test_finished_sessions_are_reviews_planners_and_retirements_by_shape(self):
        rows = [row("a", "queued", session="lead-1"), row("b", "queued", kind="planner_finished", session="plan-1"),
                row("c", "queued", kind="blocked", session="lead-2"), row("d", "queued", session="bad name\n"),
                {"time": d.iso(at(hours=1)), "session": "lead-3", "action": "retire", "outcome": "done"},
                {"time": d.iso(at(hours=1)), "session": "lead-4", "action": "retire", "outcome": "failed: x"}]
        self.assertEqual(p.summarize(rows, pause())["finished"], ["lead-1", "lead-3", "plan-1"])

    def test_a_bad_row_is_skipped(self):
        rows = [{}, {"time": "x", "action": "item", "key": "k", "outcome": "queued"}, {"time": 3, "action": "item"},
                {"time": d.iso(at(hours=1)), "action": "retire", "session": ["s"], "outcome": "done"},
                {"time": d.iso(at(hours=1)), "action": "item", "key": 5, "outcome": "queued"},
                {"time": d.iso(at(hours=1)), "action": "item", "key": "z", "outcome": "held"}]
        self.assertEqual(p.summarize(rows, pause()), {"seen": 0, "cleared": 0, "finished": []})

    def test_a_row_of_the_wrong_type_stops_nothing(self):
        rows = [{"time": d.iso(at(hours=1)), "action": "item", "key": "a", "outcome": "queued", "kind": []},
                {"time": d.iso(at(hours=1)), "action": "item", "key": "b", "outcome": "queued", "kind": {}},
                {"time": d.iso(at(hours=1)), "action": "item", "key": "c", "outcome": ["queued"]},
                {"time": d.iso(at(hours=1)), "action": ["item"], "key": "d", "outcome": "queued"},
                {"time": "0001-01-01T00:00:00+14:00", "action": "item", "key": "e", "outcome": "queued"}]
        self.assertEqual(p.summarize(rows, pause()), {"seen": 2, "cleared": 0, "finished": []})

    def test_the_item_says_length_counts_and_sessions(self):
        rows = [row("a", "queued", session="lead-1"), row("b", "cleared", kind="blocked")]
        item = p.resumed_item(pause(), rows, at(days=3, hours=2))
        self.assertEqual(item["kind"], "resumed")
        self.assertTrue(item["sticky"], "no later pass can derive it")
        self.assertEqual(item["reason"], "paused 3d 2h: 2 item(s) seen, 1 cleared on their own; finished: lead-1")
        self.assertTrue(w._is_item(item))
        self.assertEqual(w._shaped(item, "next", None), "./scripts/nogg session inbox")

    def test_the_same_pause_gives_the_same_key(self):
        rows = [row("a", "queued")]
        self.assertEqual(p.resumed_item(pause(), rows, at(days=1))["key"], p.resumed_item(pause(), rows, at(days=2))["key"])

    def test_many_finished_sessions_stay_within_the_field(self):
        rows = [row(f"k{n}", "queued", session=f"sf-lead-spec-{n:04}-{'x' * 30}") for n in range(30)]
        reason = p.resumed_item(pause(), rows, at(days=3))["reason"]
        self.assertLessEqual(len(reason), w.FIELD_CHARS)
        self.assertRegex(reason, r"\+\d+ more$")


class ResumedDigestTests(unittest.TestCase):
    def setUp(self):
        self.now = at(days=3)
        self.older = {"key": "s1|ready_for_review|m", "kind": "ready_for_review", "session": "s1", "bead": "B1",
                      "reason": "CI is green", "next": "gh pr view 7", "created_at": d.iso(at(days=1))}
        self.fresh = {"key": "s2|blocked|m", "kind": "blocked", "session": "s2", "bead": "B2", "reason": "stuck",
                      "next": "bd show B2", "created_at": d.iso(self.now - timedelta(seconds=5))}
        rows = [row("s1|ready_for_review|m", "queued"), row("x", "cleared")]
        self.resumed = {**p.resumed_item(pause(), rows, self.now), "created_at": d.iso(self.now)}

    def test_everything_held_goes_out_with_it_at_once(self):
        queue = {"items": [self.older, self.fresh, self.resumed]}
        plan = w.plan(queue, POLICY, self.now)
        self.assertEqual({item["key"] for item in plan["items"]}, {self.older["key"], self.fresh["key"], self.resumed["key"]})
        self.assertIsNone(plan["hold"])

    def test_without_it_the_quiet_periods_stand(self):
        queue = {"items": [self.fresh]}
        self.assertEqual(w.plan(queue, POLICY, self.now)["items"], [])

    def test_a_host_wide_hold_still_stops_it(self):
        queue = {"items": [self.older, self.resumed]}
        self.assertEqual(w.plan(queue, POLICY, self.now, "paused until x")["hold"], "paused until x")

    def test_the_limits_still_stop_it(self):
        queue = {"items": [self.resumed], "deliveries": [{"id": "w", "at": d.iso(self.now - timedelta(seconds=10))}]}
        self.assertEqual(w.plan(queue, POLICY, self.now)["hold"], "min_gap")

    def test_it_leads_the_digest_and_is_never_cut(self):
        items = [{**self.older, "key": f"s{n}|ready_for_review|m", "reason": "r" * 150} for n in range(30)]
        message, shown, _ = w.render("w-1", [*items, self.resumed], [])
        self.assertLessEqual(len(message.encode()), w.DIGEST_BYTES)
        self.assertEqual(shown[0]["kind"], "resumed")
        self.assertIn("paused 3d 0h", message)
        self.assertIn(w.OVERFLOW, message)

    def test_it_is_told_once_and_never_reminded(self):
        queue = {"items": [self.older, self.resumed]}
        w.begin_send(queue, "w-1", queue["items"], self.now)
        w.mark_delivered(queue, list(queue["items"]), [], self.now)
        self.assertNotIn(self.resumed["key"], queue["delivered"])
        self.assertIn(self.older["key"], queue["delivered"])
        later = self.now + timedelta(hours=5)
        w.reconcile(queue, [], [], {}, POLICY, later)
        self.assertEqual(queue["items"], [])

    def test_a_pass_keeps_it_until_it_goes_out(self):
        queue = {"items": [self.resumed]}
        w.reconcile(queue, [], [], {}, POLICY, self.now)
        self.assertEqual(queue["items"], [self.resumed])


class InboxTests(unittest.TestCase):
    def test_the_inbox_shows_the_pause_and_the_held_items(self):
        item = {"key": "s1|blocked|m", "kind": "blocked", "session": "s1"}
        view = w.inbox({"items": [item]}, [], paused_until="2026-11-03 00:00 CET")
        self.assertEqual(view["pause"], {"until": "2026-11-03 00:00 CET", "held": 1})
        self.assertIn("PAUSED until 2026-11-03 00:00 CET: 1 item(s) held", w.inbox_lines(view))

    def test_no_pause_prints_no_line(self):
        view = w.inbox({}, [])
        self.assertIsNone(view["pause"])
        self.assertFalse([line for line in w.inbox_lines(view) if "PAUSED" in line])


class DispatchHoldTests(unittest.TestCase):
    def test_a_held_host_sends_nothing_and_still_queues_and_retires(self):
        policy = d.policy_from({"enabled": True, "retire_merged": True}, hold_sends=True)
        facts = [{"session": "gaps", "role": "lead", "agent": "claude", "bead": "B1", "state": "idle", "nudgeable": True,
                  "gaps": ["dirty"], "head": "abc1234", "bead_status": "in_progress", "checks": None},
                 {"session": "limit", "role": "lead", "agent": "claude", "bead": "B2", "state": "idle",
                  "head": "abc1234", "gaps": [], "bead_status": "in_progress", "checks": None},
                 {"session": "done", "role": "lead", "agent": "claude", "bead": "B3", "state": "idle", "head": "abc1234",
                  "gaps": [], "bead_status": "closed", "sweep": "change-complete",
                  "checks": {"pr_state": "MERGED", "head_sha": "abc1234"}},
                 {"session": "ask", "role": "lead", "agent": "claude", "bead": "B4", "state": "needs_input",
                  "gaps": [], "head": "abc1234", "bead_status": "in_progress", "checks": None}]
        old = d.iso(T0 - timedelta(days=1))
        memory = {"sessions": {"gaps": {"state": "idle", "since": old}, "done": {"state": "idle", "since": old},
                               "limit": {"state": "idle", "since": old, "limit": {"since": old, "until": None}},
                               "ask": {"state": "needs_input", "since": old}}}
        actions, _ = d.decide(facts, memory, policy, T0)
        self.assertEqual(sorted(action["type"] for action in actions), ["queue", "retire"])
        unheld = d.policy_from({"enabled": True, "retire_merged": True})
        self.assertLessEqual({"nudge", "resume"}, {action["type"] for action in d.decide(facts, memory, unheld, T0)[0]})


if __name__ == "__main__":
    unittest.main()
