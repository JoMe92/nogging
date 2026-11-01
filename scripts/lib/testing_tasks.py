"""Pure task-format checks for tasks.md: the `Tests:` and `Check:` fields.

Facts in, findings out: nothing here reads a file, the tracker or the clock.
`scripts/nogg` joins an open task's wrapped lines into one text block
(`open_task_blocks`) and passes it here.

- A new task may not demand the full suite in its `Check:` field. The caller
  refuses it when the task has no Bead yet and prints a NOTE when it has one,
  because a new failure on approved work would redden an `update`.
- A task names its tests and their sizes in a `Tests:` field. A missing field,
  or one that names no size, is only a NOTE: older plans carry none.

The module is named `testing_*`, never `test_*`: the production-line count
treats `test_*.py` as a test file.
"""
import re

SIZES = ("small", "medium", "large")

# A field starts at its label and ends at the next label, or at the `Branch
# <type>/` hint that closes a task block. A label quoted in backticks is prose.
_LABEL = r"(?<![`\w])(?:Tests|Check):"
_FIELD_END = rf"(?={_LABEL}|\bBranch\s+[\w-]+/|$)"
_FIELD_RES = {
    name: re.compile(rf"(?<![`\w]){name.capitalize()}:\s*(.*?){_FIELD_END}", re.S)
    for name in ("tests", "check")
}

# Bare `scripts/test` (not `scripts/test-changed`, `scripts/test.sh`, a named
# test file or `scripts/test --only`), a whole suite, or `nogg test full`.
_FULL_SUITE_RES = (
    re.compile(r"\bscripts/test\b(?![-/\w]|\.\w|\s+--only)"),
    re.compile(r"\b(?:full|whole|entire)\s+(?:test\s+)?suite\b", re.I),
    re.compile(r"\bnogg\s+test\s+full\b"),
)
_SIZE_RE = re.compile(r"\b(?:small|medium|large)\b", re.I)
_NONE_RE = re.compile(r"^none\b[\s:,;.()–—-]*(.*)$", re.I | re.S)


def task_fields(text):
    """The `Tests:` and `Check:` text of one task block, or None when absent."""
    fields = {}
    for name, pattern in _FIELD_RES.items():
        match = pattern.search(text)
        fields[name] = " ".join(match.group(1).split()) if match else None
    return fields


def full_suite_match(check):
    """The first piece of `Check:` text that demands the full suite, else None."""
    for pattern in _FULL_SUITE_RES:
        match = pattern.search(check or "")
        if match:
            return match.group(0)
    return None


def tests_field_ok(tests):
    """Whether a `Tests:` field is usable: `none` with a reason (a documentation
    task) or a field that names a size (small, medium or large)."""
    if tests is None:
        return False
    none = _NONE_RE.match(tests.strip())
    if none:
        return bool(none.group(1).strip())
    return bool(_SIZE_RE.search(tests))


def task_format_findings(blocks, mapped, change):
    """(refusals, notes) for the open tasks of one change.

    `blocks` is [(task id, joined text)], `mapped` the task IDs that already
    have a Bead. A full-suite `Check:` on an unmapped task is a refusal; on a
    mapped task it is a note. Missing or sizeless `Tests:` fields are notes.
    """
    refusals, notes, untested = [], [], []
    for task, text in blocks:
        fields = task_fields(text)
        match = full_suite_match(fields["check"])
        if match and task in mapped:
            notes.append(f'task format: {change}: {task} (already materialized) has a Check: '
                         f'that demands the full suite ("{match}"); the full suite is CI\'s job')
        elif match:
            refusals.append(f'task format: {change}: {task} has a Check: that demands the full '
                            f'suite ("{match}"); name the suites or test files the task affects')
        if not tests_field_ok(fields["tests"]):
            untested.append(task)
    if untested:
        notes.append(f"task format: {change}: {', '.join(untested)} carry no Tests: field naming "
                     f"a size (small, medium or large); name the scenarios, or say "
                     f"Tests: none (<reason>)")
    return refusals, notes
