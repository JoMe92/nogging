"""``nogg-bench candidates``: the criteria per rule (small)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from curation_fixtures import PREREG_TEXT, make_bench

from nogg_bench import selection
from nogg_bench.selection import SelectionError

NOW = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)
SEL = selection.read_selection(PREREG_TEXT)


def repo(name: str = "octo/alpha", **over) -> dict:
    return {"full_name": name, "language": "Python", "license": {"spdx_id": "MIT"}, "stargazers_count": 900,
            "default_branch": "main", "archived": False, "fork": False, **over}


# ------------------------------------------------------- criteria, per rule


def test_the_selection_block_is_read_with_every_number():
    assert (SEL.seed, SEL.per_size_class, SEL.pilot_per_size_class) == (7, 10, 4)
    assert SEL.repositories == {"python": 2, "typescript": 1}
    assert SEL.latest_cutoff.isoformat() == "2026-03-31"  # the latest of the arm models' cutoffs
    assert SEL.suite_time_limit_seconds == 600


@pytest.mark.parametrize("line, field", [
    ("  seed: 7\n", "selection.seed"),
    ("    max_stars: 20000\n", "selection.criteria.max_stars"),
    ("    per_size_class: 10\n", "selection.counts.per_size_class"),
])
def test_a_missing_number_is_named_not_defaulted(line, field):
    with pytest.raises(SelectionError, match=field):
        selection.read_selection(PREREG_TEXT.replace(line, ""))


def test_the_licence_must_be_permissive():
    assert selection.repo_refusal(repo(), SEL, set()) is None
    assert "licence 'GPL-3.0'" in selection.repo_refusal(repo(license={"spdx_id": "GPL-3.0"}), SEL, set())
    assert "licence None" in selection.repo_refusal(repo(license=None), SEL, set())


def test_the_primary_language_must_be_preregistered():
    assert "primary language 'Go'" in selection.repo_refusal(repo(language="Go"), SEL, set())


@pytest.mark.parametrize("stars, ok", [(299, False), (300, True), (20000, True), (20001, False)])
def test_the_star_range_is_inclusive(stars, ok):
    assert (selection.repo_refusal(repo(stargazers_count=stars), SEL, set()) is None) is ok


def test_the_exclusion_list_removes_training_sources(tmp_path):
    bench = make_bench(tmp_path)
    excluded = selection.load_exclusions(bench / SEL.exclusion_list)
    assert excluded == {"octo/gamma"}
    assert "exclusion list" in selection.repo_refusal(repo("octo/gamma"), SEL, excluded)


def test_the_activity_window():
    assert selection.activity_refusal(NOW - timedelta(days=90), 10, NOW, SEL) is None
    assert "older than 90 days" in selection.activity_refusal(NOW - timedelta(days=91), 10, NOW, SEL)
    assert "9 merged pull requests" in selection.activity_refusal(NOW, 9, NOW, SEL)


def test_a_bot_author_is_recognised():
    assert selection.is_bot("dependabot[bot]", "User")
    assert selection.is_bot("renovate", "Bot")
    assert selection.is_bot(None, None)  # a deleted account cannot be shown to be a person
    assert not selection.is_bot("alice", "User")


@pytest.mark.parametrize("files, lines, expected", [
    (1, 5, "small"), (2, 299, "small"), (3, 10, "medium"), (5, 299, "medium"),
    (6, 10, "large"), (5, 300, "large"), (2, 300, "large"), (4, 120, "medium"),
])
def test_size_class_boundaries(files, lines, expected):
    assert selection.size_class(files, lines, SEL) == expected


def test_the_fix_url_or_a_diff_in_the_issue_text_disqualifies():
    url = "https://github.com/octo/alpha/pull/12"
    assert selection.issue_text_refusal("Parsing 1h30m fails.", url) is None
    assert "URL" in selection.issue_text_refusal(f"Fixed by {url}.", url)
    assert "diff" in selection.issue_text_refusal("Try:\n```diff\n-a\n+b\n```", url)
    assert "diff" in selection.issue_text_refusal("x\n@@ -1,2 +1,3 @@\n y", url)


def test_test_files_are_told_from_the_rest():
    tests = ["tests/test_x.py", "pkg/x_test.py", "src/__tests__/a.ts", "src/a.test.tsx", "src/a.spec.ts", "conftest.py"]
    assert all(selection.is_test_file(p) for p in tests)
    assert not any(selection.is_test_file(p) for p in ["src/a.py", "src/contest.py", "docs/testing.md", "src/latest.ts"])
