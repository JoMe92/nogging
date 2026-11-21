"""``nogg-bench candidates``: the criteria per rule (small) and collection through a stub ``gh`` (medium)."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from curation_fixtures import PREREG_TEXT, commit, gh_calls, make_bench, read_task, stub_gh

from nogg_bench import candidates, selection
from nogg_bench.cli import main
from nogg_bench.selection import SelectionError
from nogg_bench.validate import validate

NOW = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)
SEL = selection.read_selection(PREREG_TEXT)
ONE_PYTHON = PREREG_TEXT.replace("{python: 2, typescript: 1}", "{python: 1}")


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


# ------------------------------------------------------ repos, with stub gh


def commits(days_ago: int) -> list[dict]:
    return [{"commit": {"committer": {"date": (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")}}}]


def test_repos_writes_the_pool_and_logs_every_skip(tmp_path, monkeypatch):
    bench = make_bench(tmp_path)
    found = [repo("octo/alpha"), repo("octo/beta", license={"spdx_id": "GPL-3.0"}), repo("octo/gamma"),
             repo("octo/stale"), repo("octo/quiet"), repo("octo/delta")]
    log = stub_gh(tmp_path, monkeypatch, [
        (["search/repositories", "language:python"], {"items": found}),
        (["search/repositories", "language:typescript"], {"items": []}),
        (["repos/octo/stale/commits"], commits(120)),
        (["/commits"], commits(3)),
        (["search/issues", "repo:octo/quiet "], {"total_count": 4}),
        (["search/issues"], {"total_count": 25}),
    ])
    assert main(["candidates", "--bench-dir", str(bench), "repos"]) == 0

    pool = json.loads((bench / "curation/pool.json").read_text())
    assert pool["seed"] == 7 and pool["taken_at"].endswith("Z") and len(pool["preregistration_hash"]) == 40
    assert pool["queries"][0].startswith("language:python stars:300..20000 pushed:>=")
    names = [r["full_name"] for r in pool["repositories"]]
    assert sorted(names) == ["octo/alpha", "octo/delta"]
    assert names == [n for n in selection.ranked(7, [r["full_name"] for r in found]) if n in names]  # draw order
    assert pool["repositories"][0]["merged_pull_requests"] == 25
    skipped = {e["repo"]: e["reason"] for e in map(json.loads, (bench / "curation/pool-log.jsonl").read_text().splitlines())}
    assert set(skipped) == {"octo/beta", "octo/gamma", "octo/stale", "octo/quiet"}
    assert "licence" in skipped["octo/beta"] and "exclusion list" in skipped["octo/gamma"]
    assert "older than 90 days" in skipped["octo/stale"] and "4 merged pull requests" in skipped["octo/quiet"]
    assert all(call[:3] == ["api", "--method", "GET"] for call in gh_calls(log))  # read-only

    # The pool is taken once: a second search would let somebody pick the better pool.
    assert main(["candidates", "--bench-dir", str(bench), "repos"]) == 1


def test_the_criteria_come_only_from_the_committed_preregistration(tmp_path, monkeypatch, capsys):
    bench = make_bench(tmp_path)
    log = stub_gh(tmp_path, monkeypatch, [])
    (bench / "PREREGISTRATION.md").write_text(PREREG_TEXT.replace("max_stars: 20000", "max_stars: 90000"))
    assert main(["candidates", "--bench-dir", str(bench), "repos"]) == 1
    assert "uncommitted changes" in capsys.readouterr().err
    assert not log.exists() and not (bench / "curation/pool.json").exists()


# ----------------------------------------------------- issues, with stub gh


def file_diff(path: str, added: int) -> str:
    body = "".join(f"+line {i}\n" for i in range(added))
    return (f"diff --git a/{path} b/{path}\nnew file mode 100644\nindex 0000000..1111111\n"
            f"--- /dev/null\n+++ b/{path}\n@@ -0,0 +1,{added} @@\n{body}")


def issue(number: int, pr: dict | None, *, body: str = "It fails.", reason: str = "COMPLETED") -> dict:
    return {"number": number, "title": f"Bug {number}", "body": body, "stateReason": reason,
            "url": f"https://github.com/octo/alpha/issues/{number}", "closedAt": "2026-05-02T10:00:00Z",
            "closedByPullRequestsReferences": {"nodes": [pr] if pr else []}}


def pull(number: int, login: str = "alice", kind: str = "User") -> dict:
    return {"number": number, "url": f"https://github.com/octo/alpha/pull/{number}", "merged": True,
            "baseRefOid": f"{number:040x}", "author": {"__typename": kind, "login": login}}


def issues_bench(tmp_path, monkeypatch, nodes: list[dict], diffs: dict[int, str]):
    bench = make_bench(tmp_path, ONE_PYTHON)
    pool = {"schema": 1, "repositories": [
        {"full_name": "octo/first", "language": "python", "rank": 1, "license": "MIT"},
        {"full_name": "octo/alpha", "language": "python", "rank": 2, "license": "MIT"},
    ]}
    (bench / "curation/pool.json").write_text(json.dumps(pool))
    page = {"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}}
    log = stub_gh(tmp_path, monkeypatch, [(["graphql", "owner=octo", "name=alpha"], page)] + [
        ([f"repos/octo/alpha/pulls/{number}\n"], text) for number, text in diffs.items()])
    return bench, log


RECIPE = "image: python:3.13-slim\nsetup: [pip install -e .]\ntest_command: python -m pytest -q -rA {tests}\ntest_timeout_seconds: 600\n"


def take_alpha(bench) -> None:
    """The curating agent's part: skip the first repository in draw order, write the next one's recipe."""
    assert main(["candidates", "--bench-dir", str(bench), "skip", "octo/first", "--reason", "suite needs a GPU"]) == 0
    (bench / "curation/recipes").mkdir()
    (bench / "curation/recipes/octo__alpha.yaml").write_text(RECIPE)


def test_repositories_are_taken_in_draw_order_or_skipped_on_record(tmp_path, monkeypatch, capsys):
    bench, _ = issues_bench(tmp_path, monkeypatch, [], {})
    assert main(["candidates", "--bench-dir", str(bench), "issues"]) == 1
    assert "octo/first is next in draw order" in capsys.readouterr().err
    take_alpha(bench)
    assert json.loads((bench / "curation/pool-log.jsonl").read_text())["reason"] == "suite needs a GPU"
    assert main(["candidates", "--bench-dir", str(bench), "issues"]) == 0


def test_a_bots_pull_request_is_not_a_candidate(tmp_path, monkeypatch):
    diff = file_diff("src/a.py", 3) + file_diff("tests/test_a.py", 3)
    nodes = [issue(1, pull(11, "dependabot[bot]", "Bot")), issue(2, None), issue(3, pull(13), reason="NOT_PLANNED"),
             issue(4, pull(14), body="See https://github.com/octo/alpha/pull/14"), issue(5, pull(15))]
    bench, _ = issues_bench(tmp_path, monkeypatch, nodes, {11: diff, 15: file_diff("src/a.py", 3)})
    take_alpha(bench)
    summary = candidates.collect_issues(bench, candidates.Gh())
    assert not (bench / "tasks").exists()  # no task for the bot's fix, nor for the others
    assert summary["octo/alpha"]["the fix pull request's author is a bot account"] == 1
    assert summary["octo/alpha"]["the fix does not change both test and non-test files"] == 1
    assert sum(summary["octo/alpha"].values()) == 5


def test_the_size_class_follows_the_fix(tmp_path, monkeypatch):
    non_test = [file_diff(f"src/mod{i}.py", 30) for i in range(4)]  # 4 non-test files, 120 changed lines
    diff = non_test[0] + file_diff("tests/test_mod.py", 500) + "".join(non_test[1:])
    bench, log = issues_bench(tmp_path, monkeypatch, [issue(2, pull(12))], {12: diff})
    take_alpha(bench)
    assert main(["candidates", "--bench-dir", str(bench), "issues"]) == 0

    task = read_task(bench, "octo-alpha-2")
    assert task["size_class"] == "medium"
    assert task["curation"] == {"status": "candidate"}
    assert task["base_commit"] == f"{12:040x}" and task["repo"] == "https://github.com/octo/alpha.git"
    assert task["fix_pr_url"].endswith("/pull/12") and task["issue_closed_at"] == "2026-05-02T10:00:00Z"
    assert task["environment"]["test_timeout_seconds"] == 600  # the repository's recipe
    task_dir = bench / "tasks/octo-alpha-2"
    assert (task_dir / "hidden/tests.patch").read_text() == file_diff("tests/test_mod.py", 500)
    assert (task_dir / "hidden/fix.patch").read_text() == "".join(non_test)
    assert (task_dir / "issue.md").read_text() == "# Bug 2\n\nIt fails.\n"
    assert validate([task_dir], bench) == []
    assert all(c[:3] == ["api", "--method", "GET"] or c[:2] == ["api", "graphql"] for c in gh_calls(log))

    # Collecting again writes nothing new and changes nothing.
    commit(bench, "candidates")
    assert candidates.collect_issues(bench, candidates.Gh())["octo/alpha"] == {"already written": 1}
