"""Run records and test detail: schema 1, rotation, JUnit and timings parsing."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import testing_runs as r

JUNIT = """<?xml version="1.0"?>
<testsuites><testsuite name="s">
  <testcase classname="a" name="slow" time="3.5"/>
  <testcase classname="a" name="broken" time="1.0"><failure>boom</failure></testcase>
  <testcase classname="b" name="crash" time="0.5"><error/></testcase>
  <testcase name="ignored" time="bad"><skipped/></testcase>
</testsuite></testsuites>
"""


def record(**fields):
    return r.build_record(**{"stage": "bead", "trigger": "stage", "status": "passed", "exit_code": 0, **fields})


class Base(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.dir = Path(temporary.name)

    def write(self, name, text):
        path = self.dir / name
        path.write_text(text)
        return str(path)


class Junit(Base):
    def test_counts_and_slowest(self):
        detail = r.parse_junit(self.write("j.xml", JUNIT))
        self.assertEqual((detail["tests"], detail["failed_tests"], detail["skipped_tests"]), (4, 2, 1))
        self.assertEqual(detail["slowest"][0], {"name": "a.slow", "seconds": 3.5})
        self.assertEqual(detail["slowest"][-1], {"name": "ignored", "seconds": 0.0})

    def test_failed_names(self):
        self.assertEqual(r.parse_junit(self.write("j.xml", JUNIT))["failed_names"], ["a.broken", "b.crash"])

    def test_failed_names_are_bounded(self):
        cases = "".join(f'<testcase name="t{i}"><failure/></testcase>' for i in range(9))
        detail = r.parse_junit(self.write("j.xml", f"<testsuite>{cases}</testsuite>"))
        self.assertEqual((detail["failed_tests"], len(detail["failed_names"])), (9, r.FAILED_NAMES_KEPT))

    def test_a_single_testsuite_root(self):
        path = self.write("j.xml", '<testsuite><testcase name="x" time="1"/></testsuite>')
        self.assertEqual(r.parse_junit(path)["tests"], 1)

    def test_a_namespaced_file(self):
        path = self.write("j.xml", '<testsuite xmlns="urn:x"><testcase name="x"><failure/></testcase></testsuite>')
        self.assertEqual(r.parse_junit(path)["failed_tests"], 1)

    def test_a_broken_result_file_is_no_detail(self):
        for text in ("<testsuite><testcase", "not xml", "<html><testcase name='x'/></html>", ""):
            with self.subTest(text=text):
                self.assertIsNone(r.parse_junit(self.write("j.xml", text)))

    def test_a_missing_file_is_no_detail(self):
        self.assertIsNone(r.parse_junit(str(self.dir / "absent.xml")))

    def test_a_directory_is_no_detail(self):
        self.assertIsNone(r.parse_junit(str(self.dir)))

    def test_a_file_above_the_limit_is_no_detail(self):
        path = self.write("j.xml", JUNIT)
        with open(path, "ab") as handle:
            handle.truncate(r.MAX_RESULT_BYTES + 1)
        self.assertIsNone(r.parse_junit(path))

    def test_ten_slowest_at_most(self):
        cases = "".join(f'<testcase name="t{i:02}" time="{i}"/>' for i in range(14))
        detail = r.parse_junit(self.write("j.xml", f"<testsuite>{cases}</testsuite>"))
        self.assertEqual(detail["tests"], 14)
        self.assertEqual([test["name"] for test in detail["slowest"]], [f"t{i:02}" for i in range(13, 3, -1)])

    def test_a_test_name_cannot_carry_a_control_character(self):
        path = self.write("j.xml", '<testsuite><testcase name="a&#10;b" time="1"/></testsuite>')
        self.assertEqual(r.parse_junit(path)["slowest"][0]["name"], "a b")


class Timings(Base):
    def test_counts_and_slowest(self):
        detail = r.parse_timings(self.write("t.tsv", "1.5\ta.test.sh\n2\tb.test.sh\n"))
        self.assertEqual(detail, {"tests": 2, "failed_tests": None, "skipped_tests": None,
                                  "slowest": [{"name": "b.test.sh", "seconds": 2.0},
                                              {"name": "a.test.sh", "seconds": 1.5}]})

    def test_a_broken_result_file_is_no_detail(self):
        for text in ("1.5 a.test.sh\n", "x\ta\n", "1\t\n", "nan\ta\n", "-1\ta\n", "1\ta\nbroken\n", ""):
            with self.subTest(text=text):
                self.assertIsNone(r.parse_timings(self.write("t.tsv", text)))

    def test_a_file_that_is_no_text_is_no_detail(self):
        path = self.dir / "t.tsv"
        path.write_bytes(b"\xff\xfe\t\n")
        self.assertIsNone(r.parse_timings(str(path)))

    def test_a_file_above_the_limit_is_no_detail(self):
        path = self.write("t.tsv", "1\ta\n")
        with open(path, "ab") as handle:
            handle.truncate(r.MAX_RESULT_BYTES + 1)
        self.assertIsNone(r.parse_timings(path))


class Detail(Base):
    def test_junit_wins_over_timings(self):
        step = {"junit": self.write("j.xml", JUNIT), "timings": self.write("t.tsv", "1\ta\n")}
        self.assertEqual(r.read_detail([step])["tests"], 4)

    def test_timings_when_there_is_no_junit(self):
        step = {"junit": str(self.dir / "absent"), "timings": self.write("t.tsv", "1\ta\n")}
        self.assertEqual(r.read_detail([step])["tests"], 1)

    def test_no_result_file_is_an_empty_detail(self):
        step = {"junit": str(self.dir / "a"), "timings": str(self.dir / "b")}
        self.assertEqual(r.read_detail([step]), {"tests": None, "failed_tests": None, "skipped_tests": None,
                                                 "slowest": [], "failed_names": []})

    def test_steps_add_up(self):
        first = {"junit": self.write("1.xml", JUNIT), "timings": str(self.dir / "a")}
        second = {"junit": str(self.dir / "b"), "timings": self.write("2.tsv", "9\tb\n")}
        detail = r.read_detail([first, second])
        self.assertEqual((detail["tests"], detail["failed_tests"]), (5, 2))
        self.assertEqual(detail["slowest"][0]["name"], "b")


class Records(Base):
    def test_schema_1_holds_every_field_and_no_command(self):
        line = record(seconds=1.23456, wait_seconds=2, budget_seconds=1800, over_budget=False, reason="why",
                      bead="SPEC-x", session="s", role="lead", branch="b", head="abc", at="2026-10-31T00:00:00+00:00",
                      detail={"tests": 3, "failed_tests": 1, "skipped_tests": 0, "slowest": []})
        self.assertEqual(set(line), {
            "schema", "id", "at", "stage", "trigger", "reason", "status", "exit", "seconds", "wait_seconds",
            "budget_seconds", "over_budget", "bead", "session", "role", "branch", "head", "tests", "failed_tests",
            "skipped_tests", "slowest", "failed_names"})
        self.assertEqual((line["schema"], line["seconds"], line["tests"]), (1, 1.235, 3))

    def test_a_reason_is_one_bounded_line(self):
        self.assertEqual(record(reason="a\nb\x1b")["reason"], "a b")
        self.assertEqual(len(record(reason="x" * 900)["reason"]), r.MAX_REASON)

    def test_append_and_read_back(self):
        first, second = record(), record(status="failed", exit_code=2)
        r.append_record(self.dir / "new/testing", first)
        r.append_record(self.dir / "new/testing", second)
        read = r.read_records(self.dir / "new/testing")
        self.assertEqual([rec["id"] for rec in read], [first["id"], second["id"]])
        self.assertEqual(read[1]["status"], "failed")

    def test_rotation_keeps_both_files_for_readers(self):
        r.append_record(self.dir, record(stage="changed"), rotate_bytes=10)
        r.append_record(self.dir, record(stage="commit"), rotate_bytes=10)
        self.assertTrue((self.dir / "runs.jsonl.1").is_file())
        self.assertEqual(len((self.dir / "runs.jsonl").read_text().splitlines()), 1)
        self.assertEqual([rec["stage"] for rec in r.read_records(self.dir)], ["changed", "commit"])

    def test_the_default_limit_is_5_mib(self):
        self.assertEqual(r.ROTATE_BYTES, 5 * 1024 * 1024)

    def test_a_symlinked_record_file_is_refused(self):
        (self.dir / "runs.jsonl").symlink_to(self.dir / "elsewhere")
        with self.assertRaises(OSError):
            r.append_record(self.dir, record())
        self.assertFalse((self.dir / "elsewhere").exists())

    def test_a_directory_that_cannot_exist_raises_oserror(self):
        self.write("file", "x")
        with self.assertRaises(OSError):
            r.append_record(self.dir / "file/testing", record())

    def test_readers_validate_every_field(self):
        good = record()
        bad = [
            "not json", "[]", json.dumps({**good, "schema": 2}), json.dumps({**good, "status": "green"}),
            json.dumps({**good, "exit": "0"}), json.dumps({**good, "seconds": "1"}), json.dumps({**good, "seconds": -1}),
            json.dumps({**good, "tests": -1}), json.dumps({**good, "tests": True}), json.dumps({**good, "bead": 3}),
            json.dumps({**good, "id": ""}), json.dumps({**good, "over_budget": 1}),
            json.dumps({**good, "slowest": "x"}), json.dumps({**good, "slowest": [{"name": 1, "seconds": 1}]}),
            json.dumps({**good, "slowest": [{"name": "a", "seconds": 1}] * 11}),
            json.dumps({**good, "failed_names": "x"}), json.dumps({**good, "failed_names": [1]}),
        ]
        (self.dir / "runs.jsonl").write_text("\n".join(bad + [json.dumps(good)]) + "\n")
        self.assertEqual([rec["id"] for rec in r.read_records(self.dir)], [good["id"]])

    def test_a_reader_cleans_text_fields(self):
        line = {**record(), "bead": "a\x1b[31m", "slowest": [{"name": "a\nb", "seconds": 1}]}
        (self.dir / "runs.jsonl").write_text(json.dumps(line) + "\n")
        read = r.read_records(self.dir)[0]
        self.assertNotIn("\x1b", read["bead"])
        self.assertEqual(read["slowest"], [{"name": "a b", "seconds": 1}])

    def test_a_record_from_before_failed_names_reads_as_none(self):
        line = {key: value for key, value in record().items() if key != "failed_names"}
        (self.dir / "runs.jsonl").write_text(json.dumps(line) + "\n")
        self.assertEqual(r.read_records(self.dir)[0]["failed_names"], [])

    def test_no_record_yet(self):
        self.assertEqual(r.read_records(self.dir / "absent"), [])


class Bead(unittest.TestCase):
    def test_the_newest_token_wins(self):
        self.assertEqual(r.bead_from_subjects(["no token", "feat: x [SPEC-abc]", "feat: y [SPEC-old]"]), "SPEC-abc")

    def test_no_token(self):
        self.assertIsNone(r.bead_from_subjects(["feat: x", "fix: [not a bead]"]))


class Logs(Base):
    def test_the_newest_are_kept(self):
        for number in range(5):
            path = self.dir / f"{number}.log"
            path.write_text("x")
            os.utime(path, (number, number))
        (self.dir / "other.txt").write_text("x")
        r.prune_logs(self.dir, 2)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["3.log", "4.log", "other.txt"])


if __name__ == "__main__":
    unittest.main()
