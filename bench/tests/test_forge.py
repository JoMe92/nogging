"""The local forge stand-in (``gh`` in a nogging arm's container): its four answers and its refusals (small)."""

from __future__ import annotations

import ast
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from nogg_bench import forge

FORGE = Path(forge.__file__)
TOKEN = "ghp_THISMUSTNOTLEAK0123456789"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout


@pytest.fixture
def work(tmp_path, monkeypatch) -> Path:
    """A repository on a pushed feature branch, with a local bare origin beside it, as the driver leaves it."""
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init", "--quiet", "-b", "develop")
    git(repo, "config", "user.email", "bench@example.invalid")
    git(repo, "config", "user.name", "bench")
    (repo / "app.txt").write_text("broken\n")
    git(repo, "add", ".")
    git(repo, "commit", "--quiet", "-m", "base")
    git(repo, "init", "--quiet", "--bare", str(tmp_path / "origin.git"))
    git(repo, "remote", "add", "origin", str(tmp_path / "origin.git"))
    git(repo, "checkout", "--quiet", "-b", "feat/fix")
    (repo / "app.txt").write_text("fixed\n")
    git(repo, "commit", "--quiet", "-am", "fix: app text")
    git(repo, "push", "--quiet", "origin", "develop", "feat/fix")
    monkeypatch.chdir(repo)
    monkeypatch.setenv("GH_TOKEN", TOKEN)  # set on purpose: the stand-in must neither need nor record it
    return repo


def gh(capsys, *argv: str) -> tuple[int, str, str]:
    code = forge.main(list(argv))
    out = capsys.readouterr()
    return code, out.out, out.err


def records(work: Path) -> list[dict]:
    return [json.loads(p.read_text()) for p in sorted((work.parent / "forge" / "pulls").glob("*.json"))]


def test_pr_create_records_the_pull_request_and_prints_its_url(work, capsys):
    # the exact call Nogging v3.6.0's `nogg pr create` makes
    code, out, _ = gh(capsys, "pr", "create", "--base", "develop", "--head", "feat/fix",
                      "--title", "fix-app: implementation", "--body", "## Plan and tasks\nPlan: fix-app\n")
    assert code == 0 and out.strip().splitlines()[-1] == "https://forge.invalid/bench/repo/pull/1"
    [record] = records(work)
    assert record == {**record, "number": 1, "title": "fix-app: implementation", "base": "develop",
                      "head": "feat/fix", "state": "OPEN", "draft": False, "merged_at": None,
                      "head_sha": git(work, "rev-parse", "feat/fix").strip()}
    assert record["body"].startswith("## Plan and tasks")
    # a second pull request for the same branch is refused, as the real forge does
    code, _, err = gh(capsys, "pr", "create", "--fill")
    assert code == 1 and "already exists" in err and len(records(work)) == 1


def test_pr_create_defaults_to_the_current_branch_and_its_last_subject(work, capsys):
    assert gh(capsys, "pr", "create", "--draft", "--label", "bench")[0] == 0
    [record] = records(work)
    assert (record["head"], record["base"], record["title"], record["draft"]) == (
        "feat/fix", "develop", "fix: app text", True)


def test_pr_view_shows_the_recorded_pull_request(work, capsys):
    gh(capsys, "pr", "create", "--title", "T", "--body", "B")
    code, out, _ = gh(capsys, "pr", "view")
    assert code == 0 and "title:\tT" in out and "state:\tOPEN" in out and "checks:\tpassed" in out
    for selector in ("1", "#1", "https://forge.invalid/bench/repo/pull/1", "feat/fix"):
        code, out, _ = gh(capsys, "pr", "view", selector, "--json", "number,state,headRefName,statusCheckRollup")
        assert code == 0
        assert json.loads(out) == {"number": 1, "state": "OPEN", "headRefName": "feat/fix", "statusCheckRollup": [
            {"__typename": "CheckRun", "name": "bench-forge", "status": "COMPLETED", "conclusion": "SUCCESS"}]}
    assert gh(capsys, "pr", "view", "--json", "url", "--jq", ".url")[1] == "https://forge.invalid/bench/repo/pull/1\n"
    assert gh(capsys, "pr", "view", "7")[0] == 1
    code, _, err = gh(capsys, "pr", "view", "--json", "number,secrets")
    assert code == 1 and "unknown JSON field: secrets" in err


def test_pr_checks_reports_passed(work, capsys):
    gh(capsys, "pr", "create", "--fill")
    url = "https://forge.invalid/bench/repo/pull/1"
    # the exact call of v3.6.0's `nogg pr ci`: every bucket must be pass for ready_for_user_review
    code, out, _ = gh(capsys, "pr", "checks", url, "--required", "--json", "name,state,bucket")
    assert code == 0 and json.loads(out) == [{"name": "bench-forge", "state": "SUCCESS", "bucket": "pass"}]
    code, out, _ = gh(capsys, "pr", "checks", "--watch")
    assert code == 0 and out.startswith("bench-forge\tpass\t")
    assert gh(capsys, "pr", "checks", "9")[0] == 1  # no such pull request: nothing to report on


def test_pr_merge_merges_into_the_local_bare_origin(work, capsys):
    gh(capsys, "pr", "create", "--fill")
    origin = work.parent / "origin.git"
    before = git(origin, "rev-parse", "develop").strip()
    code, out, err = gh(capsys, "pr", "merge", "1", "--merge", "--delete-branch")
    assert code == 0 and out.startswith("Merged pull request #1") and "is kept" in err
    assert git(origin, "show", "develop:app.txt") == "fixed\n"
    assert git(origin, "rev-list", "--parents", "-1", "develop").split()[1:] == [
        before, git(work, "rev-parse", "feat/fix").strip()]
    [record] = records(work)
    assert record["state"] == "MERGED" and record["merge_commit"] == git(origin, "rev-parse", "develop").strip()
    assert git(origin, "rev-parse", "--verify", "feat/fix").strip()  # the measured branch stays
    assert gh(capsys, "pr", "merge", "1")[1] == "Pull request #1 was already merged\n"
    assert json.loads(gh(capsys, "pr", "view", "1", "--json", "state,closed")[1]) == {"state": "MERGED", "closed": True}


def test_a_conflicting_or_unpushed_branch_is_refused(work, capsys):
    gh(capsys, "pr", "create", "--fill")
    git(work, "checkout", "--quiet", "develop")
    (work / "app.txt").write_text("something else\n")
    git(work, "commit", "--quiet", "-am", "conflict")
    git(work, "push", "--quiet", "origin", "develop")
    code, _, err = gh(capsys, "pr", "merge", "1")
    assert code == 1 and "not mergeable" in err and records(work)[0]["state"] == "OPEN"
    git(work, "checkout", "--quiet", "-b", "feat/local-only")
    code, _, err = gh(capsys, "pr", "create", "--fill")
    assert code == 1 and "push it first" in err and len(records(work)) == 1


@pytest.mark.parametrize("argv", [
    [], ["--version"], ["--help"], ["auth", "status"], ["auth", "token"], ["api", "repos/o/r/pulls"],
    ["repo", "view", "--json", "isPrivate"], ["issue", "list"], ["run", "list"], ["release", "download"],
    ["pr"], ["pr", "list", "--head", "feat/fix", "--base", "develop", "--state", "open", "--json", "url"],
    ["pr", "close", "1"], ["pr", "comment", "1", "--body", "x"], ["pr", "edit", "1"], ["pr", "checkout", "1"],
    ["pr", "create", "--repo", "owner/repo"], ["pr", "create", "--web"], ["pr", "create", "--head", "fork:feat"],
    ["pr", "merge", "--rebase"], ["pr", "merge", "--admin"], ["pr", "view", "--web"], ["pr", "view", "--jq", "."],
])
def test_everything_else_is_refused(work, capsys, argv):
    code, out, err = gh(capsys, *argv)
    assert code == 1 and out == "" and "refused" in err
    assert records(work) == []
    assert git(work.parent / "origin.git", "rev-parse", "develop") == git(work, "rev-parse", "develop")


@pytest.mark.parametrize("url", [
    "https://example.invalid/owner/repo.git", "git@example.invalid:owner/repo.git", "ssh://example.invalid/r.git",
    "file:///tmp/somewhere.git", "relative/path.git",
])
def test_an_origin_that_is_not_local_is_refused_before_anything_else(work, capsys, monkeypatch, url):
    git(work, "remote", "set-url", "origin", url)
    seen: list[list[str]] = []
    real = forge.run_git
    monkeypatch.setattr(forge, "run_git", lambda argv, **kw: seen.append(argv) or real(argv, **kw))
    code, _, err = gh(capsys, "pr", "create", "--fill")
    assert code == 1 and "refused" in err
    assert seen == [["remote", "get-url", "origin"]]  # the only git call: nothing ever talks to that URL
    assert not (work.parent / "forge").exists()


def test_the_stand_in_makes_no_network_call(work, capsys, monkeypatch):
    seen: list[list[str]] = []
    real = forge.run_git
    monkeypatch.setattr(forge, "run_git", lambda argv, **kw: seen.append(argv) or real(argv, **kw))
    gh(capsys, "pr", "create", "--fill")
    gh(capsys, "pr", "view", "--json", "url")
    gh(capsys, "pr", "checks")
    gh(capsys, "pr", "merge", "--squash")
    origin = str(work.parent / "origin.git")
    local = {"remote", "branch"}  # read the working directory's own configuration and HEAD
    plumbing = {"rev-parse", "log", "merge-tree", "commit-tree", "update-ref"}
    for argv in seen:
        if argv[0] == "--git-dir":
            assert argv[1] == origin and argv[2] in plumbing, argv
        else:
            assert argv[0] in local, argv
    assert {a[2] for a in seen if a[0] == "--git-dir"} == plumbing  # the whole flow was exercised
    # and the file can open no connection of its own: only these standard-library modules
    imported = set()
    for node in ast.walk(ast.parse(FORGE.read_text(encoding="utf-8"))):
        if isinstance(node, ast.Import):
            imported |= {alias.name.split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ImportFrom):
            imported.add((node.module or "").split(".")[0])
    assert imported == {"__future__", "argparse", "json", "os", "re", "subprocess", "sys", "datetime", "pathlib"}


def test_no_token_and_no_argument_value_reaches_the_records_or_the_call_log(work, capsys):
    gh(capsys, "pr", "create", "--title", "T", "--body", "B")
    gh(capsys, "api", "-H", f"Authorization: token {TOKEN}", "user")
    gh(capsys, "auth", "login", "--with-token")
    gh(capsys, TOKEN)
    calls = [json.loads(x) for x in (work.parent / "forge" / "calls.jsonl").read_text().splitlines()]
    assert [(c["call"], c["exit"]) for c in calls] == [("pr create", 0), ("api ?", 1), ("auth login", 1), ("?", 1)]
    tree = "".join(p.read_text() for p in (work.parent / "forge").rglob("*") if p.is_file())
    assert TOKEN not in tree
    source = FORGE.read_text(encoding="utf-8")
    assert "GH_TOKEN" not in source and "GITHUB_TOKEN" not in source and "getenv" not in source


def test_the_stand_in_runs_as_gh_with_python_alone(work, tmp_path):
    """The container has python3 only: copied in as ``gh``, it must import nothing from the bench."""
    copy = tmp_path / "bin" / "gh"
    copy.parent.mkdir()
    shutil.copy(FORGE, copy)
    done = subprocess.run([sys.executable, "-I", str(copy), "pr", "create", "--fill"], capture_output=True, text=True)
    assert (done.returncode, done.stdout) == (0, "https://forge.invalid/bench/repo/pull/1\n"), done.stderr
    done = subprocess.run([sys.executable, "-I", str(copy), "pr", "list"], capture_output=True, text=True)
    assert done.returncode == 1 and "refused" in done.stderr
    assert FORGE.read_text(encoding="utf-8").startswith("#!/usr/bin/env python3\n")
