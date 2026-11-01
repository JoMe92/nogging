#!/usr/bin/env python3
"""Small tests of the dashboard's loaders, with a fake runner in place of `bd`."""
from __future__ import annotations

import json, subprocess, sys, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_cache as cache
import dashboard_sources as sources

ADDRESS = "someone" + "@" + "example.com"


class Runner:
    """Answers `bd` calls by subcommand, and keeps argv, environment and timeout."""

    def __init__(self, answers=None, fail=None):
        self.answers, self.fail, self.calls = answers or {}, fail, []

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if isinstance(self.fail, BaseException):
            raise self.fail
        if self.fail:
            return SimpleNamespace(returncode=1, stdout="", stderr=self.fail)
        name = "dep" if "dep" in argv else next(word for word in argv if word in ("list", "ready"))
        return SimpleNamespace(returncode=0, stdout=json.dumps(self.answers.get(name, [])), stderr="")


def bead(identifier, **extra):
    return {"id": identifier, "title": "t", "status": "open", "owner": ADDRESS, **extra}


class Beads(unittest.TestCase):
    def test_every_call_is_read_only_sandboxed_and_bounded(self):
        runner = Runner({"list": [bead("SPEC-a")], "ready": [{"id": "SPEC-a"}]})
        sources.read_beads("bd", "/canonical", runner)
        self.assertEqual(len(runner.calls), 3)
        for argv, kwargs in runner.calls:
            self.assertEqual(argv[:3], ["bd", "--readonly", "--sandbox"])
            self.assertEqual(kwargs["timeout"], 30)
            self.assertEqual(kwargs["cwd"], "/canonical")
            self.assertEqual(kwargs["env"]["BEADS_DOLT_AUTO_START"], "0")
            self.assertEqual(kwargs["env"]["GIT_OPTIONAL_LOCKS"], "0")
        words = [word for argv, _ in runner.calls for word in argv]
        for forbidden in ("doctor", "start", "stop", "restart", "create", "update", "close"):
            self.assertNotIn(forbidden, words)

    def test_the_snapshot_has_the_contract_shape_and_no_owner(self):
        runner = Runner({"list": [bead("SPEC-a"), "junk", {"id": "no/slash"}], "ready": [{"id": "SPEC-a"}, "SPEC-b", 3],
                         "dep": [[{"id": "SPEC-a"}, {"id": "SPEC-b"}], []]})
        snapshot = sources.read_beads(["bd"], ".", runner)
        self.assertEqual(sorted(snapshot), ["beads", "cycles", "ready"])
        self.assertEqual([item["id"] for item in snapshot["beads"]], ["SPEC-a"])
        self.assertEqual(snapshot["ready"], ["SPEC-a", "SPEC-b"])
        self.assertEqual(snapshot["cycles"], [["SPEC-a", "SPEC-b"]])
        self.assertNotIn(ADDRESS, json.dumps(snapshot))

    def test_a_source_error_is_a_class_and_never_the_text(self):
        down = "dial tcp 127.0.0.1:3307: connect: connection refused /home/alice/.beads user@example.com"
        with self.assertRaises(cache.SourceError) as caught:
            sources.read_beads("bd", ".", Runner(fail=down))
        self.assertEqual(caught.exception.kind, "dolt_unreachable")
        self.assertNotIn("jome", str(caught.exception))
        with self.assertRaises(cache.SourceError) as caught:
            sources.read_beads("bd", ".", Runner(fail="panic: nil pointer at /home/alice/x"))
        self.assertEqual((caught.exception.kind, str(caught.exception)), ("bd_error", "bd_error"))

    def test_a_missing_bd_a_timeout_and_bad_output_are_classified(self):
        for failure, kind in ((FileNotFoundError("bd"), "bd_absent"),
                              (subprocess.TimeoutExpired(["bd"], 30), "bd_error"),
                              (PermissionError("denied"), "bd_error")):
            with self.assertRaises(cache.SourceError) as caught:
                sources.read_beads("bd", ".", Runner(fail=failure))
            self.assertEqual(caught.exception.kind, kind)
        bad = lambda argv, **kwargs: SimpleNamespace(returncode=0, stdout="not json", stderr="")
        with self.assertRaises(cache.SourceError) as caught:
            sources.read_beads("bd", ".", bad)
        self.assertEqual(caught.exception.kind, "bd_error")
        wrong = lambda argv, **kwargs: SimpleNamespace(returncode=0, stdout='{"x": 1}', stderr="")
        with self.assertRaises(cache.SourceError):
            sources.read_beads("bd", ".", wrong)


class Sessions(unittest.TestCase):
    def test_a_session_record_is_allow_listed_and_sorted(self):
        records = [{"name": "b", "started_at": "2026-11-01T10:00:00Z", "command": ["x"], "log_path": "/home/alice/l"},
                   {"name": "a", "started_at": "2026-10-01T10:00:00Z", "exit_reason": f"{ADDRESS}\nmore"},
                   "junk", {"no": "name"}]
        snapshot = sources.read_sessions(records)
        self.assertEqual([item["name"] for item in snapshot["sessions"]], ["a", "b"])
        self.assertEqual(snapshot["floor"], "2026-10-01T10:00:00Z")
        text = json.dumps(snapshot)
        for private in ("command", "log_path", "/home/alice", ADDRESS, "more"):
            self.assertNotIn(private, text)

    def test_no_record_at_all_is_absent(self):
        with self.assertRaises(cache.Absent):
            sources.read_sessions([])
        with self.assertRaises(cache.Absent):
            sources.read_sessions(["junk"])


class Tests(unittest.TestCase):
    def test_test_records_keep_five_fields_and_a_floor(self):
        records = [{"bead": "SPEC-a", "stage": "bead", "at": "2026-11-01T10:00:00+00:00", "seconds": 5, "status": "passed",
                    "session": "s", "head": "abc", "reason": "x"},
                   {"bead": "SPEC-a", "stage": "bead", "at": "2026-10-30T10:00:00+00:00", "seconds": 7.5, "status": "failed"}]
        snapshot = sources.read_tests(records)
        self.assertEqual(snapshot["floor"], "2026-10-30T10:00:00Z")
        self.assertEqual(snapshot["stage_seconds"]["SPEC-a"]["bead"], 12.5)
        self.assertEqual([tuple(item) for item in snapshot["records"]], [("bead", "stage", "at", "seconds", "status")] * 2)

    def test_no_records_is_absent(self):
        with self.assertRaises(cache.Absent):
            sources.read_tests([])


class Gates(unittest.TestCase):
    def test_a_gate_moves_with_the_files_and_creates_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory, files = sources.directory_gate(root / "sessions"), sources.files_gate(root / "runs.jsonl")
            self.assertEqual((directory(), files()), (None, (None,)))
            self.assertEqual(sorted(root.iterdir()), [])
            (root / "sessions").mkdir()
            (root / "runs.jsonl").write_text("a")
            first = (directory(), files())
            (root / "runs.jsonl").write_text("ab")
            self.assertNotEqual(files(), first[1])
            self.assertEqual(directory(), first[0])


if __name__ == "__main__":
    unittest.main()
