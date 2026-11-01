#!/usr/bin/env python3
"""Small tests of the refresher: intervals, change gates, backoff, demand and idle, and
generations, all against an injected clock. No thread, no sleep, no subprocess."""
from __future__ import annotations

import json, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_cache as cache


class Clock:
    def __init__(self, now=1000.0):
        self.now, self.watcher = now, None

    def __call__(self):
        return self.now

    def advance(self, seconds):
        """Time passes with a client still asking, unless a test is about idleness."""
        self.now += seconds
        if self.watcher:
            self.watcher.touch()


class Reader:
    """A reader that counts its calls and can be told to answer, fail or look absent."""

    def __init__(self, snapshot=None):
        self.snapshot, self.calls, self.error = snapshot if snapshot is not None else {"n": 1}, 0, None

    def __call__(self):
        self.calls += 1
        if self.error:
            raise self.error
        return self.snapshot


def make(readers, gates=None, clock=None, **options):
    clock = clock or Clock()
    refresher = cache.Refresher(readers, gates, clock=clock, wall_clock=lambda: 1_700_000_000.0 + clock.now, **options)
    clock.watcher = refresher
    return refresher, clock


class Intervals(unittest.TestCase):
    def test_a_source_loads_in_the_fixed_order_and_then_waits_for_its_interval(self):
        readers = {name: Reader({"name": name}) for name in cache.ORDER}
        refresher, clock = make(readers)
        ran = [refresher.step() for _ in range(6)]
        self.assertEqual(ran, ["beads", "sessions", "tests", "git", "tokens", None])
        self.assertEqual({name: item["state"] for name, item in refresher.status().items()},
                         {name: "fresh" for name in cache.ORDER})
        clock.advance(30)
        self.assertEqual([refresher.step(), refresher.step()], ["beads", "sessions"])
        self.assertEqual(refresher.step(), None)        # tests wait for 120 s, git for 10 min, tokens for 15
        clock.advance(90)
        self.assertEqual(refresher.step(), "beads")
        self.assertEqual(refresher.step(), "sessions")
        self.assertEqual(refresher.step(), "tests")

    def test_the_first_state_is_loading_and_a_snapshot_is_none(self):
        refresher, _ = make({"beads": Reader()})
        self.assertEqual(refresher.status()["beads"], {"state": "loading", "as_of": None, "generation": 0})
        self.assertIsNone(refresher.snapshot("beads"))

    def test_sources_run_strictly_one_at_a_time(self):
        running = []

        def reader():
            running.append(1)
            self.assertEqual(len(running), 1)
            running.pop()
            return {"x": 1}
        refresher, _ = make({"beads": reader, "sessions": reader, "tests": reader})
        for _ in range(3):
            refresher.step()

    def test_an_unknown_source_is_refused(self):
        with self.assertRaises(ValueError):
            make({"graph": Reader()})


class Gates(unittest.TestCase):
    def test_nothing_changed_skips_the_reload(self):
        reader, token = Reader({"refs": 1}), ["a"]
        refresher, clock = make({"git": reader}, {"git": lambda: token[0]})
        refresher.step()
        before = refresher.status()["git"]
        clock.advance(600)
        refresher.step()
        self.assertEqual(reader.calls, 1)
        after = refresher.status()["git"]
        self.assertEqual((after["state"], after["generation"], after["as_of"]), ("fresh", 1, before["as_of"]))
        token[0] = "b"
        clock.advance(600)
        refresher.step()
        self.assertEqual(reader.calls, 2)

    def test_a_skipped_reload_still_counts_as_a_check(self):
        refresher, clock = make({"git": Reader()}, {"git": lambda: "same"})
        refresher.step()
        for _ in range(5):
            clock.advance(600)
            refresher.step()
            self.assertEqual(refresher.status()["git"]["state"], "fresh")

    def test_a_failed_reload_retries_even_with_an_unchanged_gate(self):
        reader, token = Reader(), ["a"]
        refresher, clock = make({"git": reader}, {"git": lambda: token[0]})
        refresher.step()
        token[0] = "b"
        reader.error = cache.SourceError("bd_error")
        clock.advance(600)
        refresher.step()
        reader.error = None
        clock.advance(30)                       # the gate still reads "b", which never loaded
        refresher.step()
        self.assertEqual(reader.calls, 3)
        self.assertEqual(refresher.status()["git"]["state"], "fresh")


class Failures(unittest.TestCase):
    def test_one_source_fails_and_the_others_stay_fresh(self):
        tokens, git = Reader({"t": 1}), Reader({"g": 1})
        refresher, clock = make({"git": git, "tokens": tokens})
        refresher.step(), refresher.step()
        tokens.error = cache.SourceError("bd_error")
        git.snapshot = {"g": 2}
        clock.advance(900)
        refresher.step(), refresher.step()
        status = refresher.status()
        self.assertEqual((status["tokens"]["state"], status["tokens"]["reason"]), ("stale", "bd_error"))
        self.assertEqual(refresher.snapshot("tokens"), {"t": 1})          # the last good data stays
        self.assertEqual((status["git"]["state"], status["git"]["generation"]), ("fresh", 2))

    def test_a_first_failure_is_unavailable_with_no_data(self):
        reader = Reader()
        reader.error = cache.SourceError("dolt_unreachable")
        refresher, _ = make({"beads": reader})
        refresher.step()
        self.assertEqual(refresher.status()["beads"],
                         {"state": "unavailable", "as_of": None, "generation": 0, "reason": "dolt_unreachable"})
        self.assertIsNone(refresher.snapshot("beads"))

    def test_the_backoff_doubles_from_30_seconds_to_10_minutes_and_resets(self):
        reader = Reader()
        refresher, clock = make({"beads": reader})
        refresher.step()
        reader.error = cache.SourceError("bd_error")
        waits = []
        clock.advance(30)
        for _ in range(8):
            refresher.step()
            waits.append(refresher.wait_time())
            clock.advance(waits[-1])
        self.assertEqual(waits, [30, 60, 120, 240, 480, 600, 600, 600])
        reader.error = None
        refresher.step()
        self.assertEqual(refresher.wait_time(), 30)
        self.assertEqual(refresher.status()["beads"]["state"], "fresh")

    def test_the_text_of_an_error_never_reaches_the_status(self):
        reader = Reader()
        reader.error = RuntimeError("password=hunter2 in /home/jome/.secret")
        refresher, _ = make({"beads": reader})
        refresher.step()
        text = json.dumps(refresher.status())
        self.assertNotIn("hunter2", text)
        self.assertEqual(refresher.status()["beads"]["reason"], "error")
        reader.error = cache.SourceError("a free text reason")
        self.assertEqual(cache.SourceError("a free text reason").kind, "error")

    def test_a_busy_source_keeps_its_snapshot_and_is_no_failure(self):
        reader = Reader({"t": 1})
        refresher, clock = make({"tokens": reader})
        refresher.step()
        reader.error = cache.Busy()
        clock.advance(900)
        refresher.step()
        self.assertEqual(refresher.status()["tokens"]["state"], "stale")
        self.assertEqual(refresher.status()["tokens"]["reason"], "busy")
        self.assertEqual(refresher.snapshot("tokens"), {"t": 1})
        self.assertEqual(refresher.wait_time(), cache.BUSY_RETRY)
        reader.error = None
        clock.advance(cache.BUSY_RETRY)
        refresher.step()
        self.assertEqual(refresher.status()["tokens"]["state"], "fresh")

    def test_a_source_that_does_not_exist_is_absent(self):
        reader = Reader()
        reader.error = cache.Absent()
        refresher, _ = make({"tests": reader})
        refresher.step()
        self.assertEqual(refresher.status()["tests"], {"state": "absent", "as_of": None, "generation": 0})


class Demand(unittest.TestCase):
    def test_no_clients_for_five_minutes_starts_no_source(self):
        reader = Reader()
        refresher, clock = make({"beads": reader})
        refresher.step()
        clock.now += cache.IDLE_AFTER + 1
        self.assertTrue(refresher.idle())
        self.assertIsNone(refresher.step())
        self.assertIsNone(refresher.wait_time())
        self.assertEqual(reader.calls, 1)
        refresher.touch()
        self.assertEqual(refresher.step(), "beads")
        self.assertEqual(reader.calls, 2)

    def test_a_request_inside_five_minutes_keeps_it_awake(self):
        refresher, clock = make({"beads": Reader()})
        for _ in range(4):
            clock.now += 250
            refresher.touch()
            self.assertFalse(refresher.idle())

    def test_data_that_was_not_refreshed_reads_stale_not_fresh(self):
        refresher, clock = make({"beads": Reader()})
        refresher.step()
        clock.now += 61
        self.assertEqual(refresher.status()["beads"]["state"], "stale")


class Generations(unittest.TestCase):
    def test_the_generation_changes_only_when_the_data_does(self):
        reader = Reader({"n": 1})
        refresher, clock = make({"beads": reader})
        generations = []
        for snapshot in ({"n": 1}, {"n": 1}, {"n": 2}, {"n": 2}):
            reader.snapshot = snapshot
            refresher.step()
            generations.append(refresher.status()["beads"]["generation"])
            clock.advance(30)
        self.assertEqual(generations, [1, 1, 2, 2])

    def test_as_of_moves_on_an_unchanged_reload(self):
        refresher, clock = make({"beads": Reader()})
        refresher.step()
        first = refresher.status()["beads"]["as_of"]
        clock.advance(30)
        refresher.step()
        self.assertNotEqual(refresher.status()["beads"]["as_of"], first)

    def test_a_response_is_built_once_per_change(self):
        reader, builds = Reader({"n": 1}), []
        refresher, clock = make({"beads": reader})
        refresher.step()

        def build(snapshots, statuses):
            builds.append(1)
            return snapshots["beads"]
        for _ in range(50):
            self.assertEqual(refresher.render("beads", ["beads"], build), {"n": 1})
        self.assertEqual(len(builds), 1)
        reader.snapshot = {"n": 2}
        clock.advance(30)
        refresher.step()
        self.assertEqual(refresher.render("beads", ["beads"], build), {"n": 2})
        self.assertEqual(len(builds), 2)

    def test_the_render_memo_is_bounded(self):
        refresher, _ = make({"beads": Reader()})
        refresher.step()
        for number in range(cache.RENDER_ENTRIES + 10):
            refresher.render(f"route-{number}", ["beads"], lambda snapshots, statuses: None)
        self.assertEqual(len(refresher._renders), cache.RENDER_ENTRIES)


if __name__ == "__main__":
    unittest.main()
