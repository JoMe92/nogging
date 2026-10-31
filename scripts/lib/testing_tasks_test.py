"""Unit tests for the tasks.md `Check:` and `Tests:` field checks.

Covers the scenarios of the test-policy requirements "A new task may not demand
the full suite" and "A task names its tests and their size". Pure: task blocks
and the set of mapped task IDs are passed in.
"""
import unittest

from testing_tasks import full_suite_match, task_fields, task_format_findings, tests_field_ok


def block(check=None, tests="small Scenario \"A\"."):
    parts = ["Do the thing."]
    if tests is not None:
        parts.append(f"Tests: {tests}")
    if check is not None:
        parts.append(f"Check: {check}")
    parts.append("Branch docs/.")
    return " ".join(parts)


def findings(text, mapped=()):
    return task_format_findings([("TASK-X-001", text)], set(mapped), "demo")


class FullSuiteCheck(unittest.TestCase):
    def test_new_task_demanding_the_full_suite_is_refused_and_quoted(self):
        refusals, notes = findings(block("scripts/test"))
        self.assertEqual(len(refusals), 1)
        self.assertIn("TASK-X-001", refusals[0])
        self.assertIn('"scripts/test"', refusals[0])
        self.assertEqual(notes, [])

    def test_every_full_suite_wording_matches(self):
        for check in ("./scripts/test.", "the full suite", "run the whole test suite",
                      "Entire suite green", "`nogg test full`", "scripts/test, then lint"):
            self.assertTrue(full_suite_match(check), check)

    def test_named_suites_and_selectors_pass(self):
        for check in ("scripts/session-dispatch.test.sh", "scripts/test --only a.test.sh",
                      "scripts/test-changed", "scripts/test.sh", "scripts/lib/x_test.py",
                      "nogg test bead", "nogg test changed"):
            self.assertIsNone(full_suite_match(check), check)
        self.assertEqual(findings(block("scripts/session-dispatch.test.sh"))[0], [])

    def test_approved_task_gets_a_note_not_a_refusal(self):
        refusals, notes = findings(block("scripts/test"), mapped={"TASK-X-001"})
        self.assertEqual(refusals, [])
        self.assertEqual(len(notes), 1)
        self.assertIn("TASK-X-001", notes[0])

    def test_only_the_check_field_is_read(self):
        text = block("scripts/session-dispatch.test.sh").replace(
            "Do the thing.", "Do the thing; run the full suite in CI.")
        self.assertEqual(findings(text), ([], []))

    def test_quoted_labels_in_prose_do_not_start_a_field(self):
        text = ("Parse `Check:` and `Tests:` fields. Tests: small Scenario \"A\". "
                "Check: scripts/a.test.sh. Branch docs/.")
        fields = task_fields(text)
        self.assertEqual(fields["check"], "scripts/a.test.sh.")
        self.assertTrue(fields["tests"].startswith("small"))
        self.assertEqual(findings(text), ([], []))

    def test_a_task_without_a_check_field_is_not_refused(self):
        self.assertEqual(findings(block(None))[0], [])


class TestsField(unittest.TestCase):
    def test_a_task_without_the_field_gets_a_note_naming_it(self):
        refusals, notes = findings(block("scripts/a.test.sh", tests=None))
        self.assertEqual(refusals, [])
        self.assertEqual(len(notes), 1)
        self.assertIn("TASK-X-001", notes[0])
        self.assertIn("demo", notes[0])

    def test_a_field_naming_no_size_gets_a_note(self):
        self.assertEqual(len(findings(block(None, tests="the scenarios"))[1]), 1)

    def test_a_documentation_task_gets_no_note(self):
        self.assertEqual(findings(block(None, tests="none (documentation only)."))[1], [])

    def test_none_needs_a_reason(self):
        self.assertFalse(tests_field_ok("none"))
        self.assertTrue(tests_field_ok("None: documentation only"))

    def test_each_size_is_accepted(self):
        for size in ("small", "medium", "large"):
            self.assertTrue(tests_field_ok(f"{size} a scenario"), size)

    def test_one_note_lists_every_task_that_lacks_the_field(self):
        blocks = [("TASK-X-001", block(None, tests=None)), ("TASK-X-002", block(None, tests=None)),
                  ("TASK-X-003", block(None))]
        _, notes = task_format_findings(blocks, set(), "demo")
        self.assertEqual(len(notes), 1)
        self.assertIn("TASK-X-001, TASK-X-002", notes[0])
        self.assertNotIn("TASK-X-003", notes[0])


if __name__ == "__main__":
    unittest.main()
