"""``nogg-bench run``: its building blocks (small) and whole runs against a stub ``docker`` (medium)."""

from __future__ import annotations

import json
import os
import stat
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
import yaml
from conftest import BENCH

from nogg_bench import prereg, results, scan, workspace
from nogg_bench.credentials import REDACTED, CredentialError, Credentials, Redactor
from nogg_bench.schema import check_result

T0 = datetime(2026, 11, 20, 10, 0, tzinfo=timezone.utc)
EXAMPLE = BENCH / "examples" / "tasks" / "example-small-slugify" / "task.yaml"


def example_task() -> dict:
    return yaml.safe_load(EXAMPLE.read_text(encoding="utf-8"))


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout


# ------------------------------------------------------------- pass rule


def test_the_pass_rule_needs_every_test():
    ok = {"fail_to_pass": {"a": True}, "pass_to_pass": {"b": True}}
    assert workspace.passes(ok)
    assert not workspace.passes({"fail_to_pass": {"a": True}, "pass_to_pass": {"b": False}})
    assert not workspace.passes({"fail_to_pass": {"a": False}, "pass_to_pass": {}})
    assert not workspace.passes({"fail_to_pass": {}, "pass_to_pass": {"b": True}})


def test_test_output_is_read_per_test():
    task = example_task()
    task["hidden_tests"]["fail_to_pass"] = f2p = ["tests/t.py::a", "tests/t.py::b[x y]"]
    task["hidden_tests"]["pass_to_pass"] = p2p = ["tests/t.py::c", "tests/t.py::d"]
    output = "\n".join(
        [f"PASSED {f2p[0]}", f"FAILED {f2p[1]} - AssertionError: no", f"PASSED {p2p[0]}", f"ERROR {p2p[0]} - teardown"]
    )
    tests = workspace.parse_test_output(output, task)
    assert tests["fail_to_pass"] == {f2p[0]: True, f2p[1]: False}
    assert tests["pass_to_pass"][p2p[0]] is False  # an ERROR after PASSED fails it
    assert all(v is False for k, v in tests["pass_to_pass"].items() if k != p2p[0])  # unreported fails
    assert workspace.test_script(task) == (
        "python -m pytest -q -rA tests/t.py::a 'tests/t.py::b[x y]' tests/t.py::c tests/t.py::d")


# ----------------------------------------------------------------- patches

AGENT_PATCH = """\
diff --git a/README.md b/README.md
index 1111111..2222222 100644
--- a/README.md
+++ b/README.md
@@ -1,2 +1,3 @@
 # miniutil
+Slugs collapse separators.
+++ also an added line that starts with plus signs
diff --git a/tests/test_text.py b/tests/test_text.py
index 3333333..4444444 100644
--- a/tests/test_text.py
+++ b/tests/test_text.py
@@ -1,3 +1,2 @@
-def old():
-    pass
+def new(): pass
diff --git a/notes/new.txt b/notes/new.txt
new file mode 100644
index 0000000..5555555
--- /dev/null
+++ b/notes/new.txt
@@ -0,0 +1 @@
+hello
"""


def test_a_patch_is_measured():
    stats = workspace.parse_patch(AGENT_PATCH)
    assert stats.files == ["README.md", "tests/test_text.py", "notes/new.txt"]
    assert stats.new_files == {"notes/new.txt"}
    assert (stats.insertions, stats.deletions, stats.markdown_lines) == (4, 2, 2)
    assert stats.diff_stats() == {"files_changed": 3, "insertions": 4, "deletions": 2}


def test_hidden_paths_are_restored_before_the_hidden_patch():
    hidden = workspace.parse_patch((EXAMPLE.parent / "hidden" / "tests.patch").read_text(encoding="utf-8"))
    agent = workspace.parse_patch(AGENT_PATCH)
    assert workspace.overwritten_paths(agent, hidden) == ["tests/test_text.py"]
    script = workspace.restore_script("abc123", hidden)
    assert script == "git checkout --quiet abc123 -- tests/test_text.py && git apply --whitespace=nowarn ../hidden.patch"


def test_the_fix_is_not_in_the_container_history(tmp_path):
    task = example_task()  # base is the first commit; the bundle holds three later fixes
    repo = tmp_path / "repo"
    workspace.prepare_repo(task, BENCH, repo)
    assert git(repo, "rev-list", "--all").split() == [task["base_commit"]]
    assert git(repo, "remote").split() == []
    assert git(repo, "for-each-ref", "--format=%(refname)").split() == ["refs/heads/main"]
    assert git(repo, "rev-parse", "HEAD").strip() == task["base_commit"]
    assert workspace.history_problems(repo, task["base_commit"]) == []
    fix = "00ccd954624cdd3b0ef31622be2c944e6bad2668"
    assert subprocess.run(["git", "-C", str(repo), "cat-file", "-e", fix], capture_output=True).returncode != 0


def test_a_later_commit_left_behind_is_named(tmp_path):
    task = example_task()
    repo = tmp_path / "repo"
    workspace.prepare_repo(task, BENCH, repo)
    (repo / "x").write_text("x")
    git(repo, "add", "x")
    git(repo, "commit", "-qm", "later")
    git(repo, "tag", "leak")
    problems = workspace.history_problems(repo, task["base_commit"])
    assert "1 commit(s) after the base commit are reachable" in problems
    assert "ref(s) left: refs/tags/leak" in problems


# ------------------------------------------------------- contamination scan


def write_transcript(path: Path, records: list[dict]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in records), encoding="utf-8")
    return path


def test_a_web_lookup_is_flagged(tmp_path):
    task = example_task()
    clean = write_transcript(tmp_path / "a.jsonl", [{"type": "assistant", "message": {"content": "fixing"}}])
    assert scan.scan([clean], [task["issue_url"], task["fix_pr_url"]]) == []
    leak = write_transcript(tmp_path / "b.jsonl", [{"type": "user", "message": {"content": f"see {task['fix_pr_url']}"}}])
    assert scan.scan([leak], [task["fix_pr_url"]]) == [f"b.jsonl mentions {task['fix_pr_url']}"]


@pytest.mark.parametrize(
    "record,call",
    [
        ({"message": {"content": [{"type": "tool_use", "name": "WebFetch", "input": {}}]}}, "WebFetch"),
        ({"type": "response_item", "payload": {"type": "web_search_call", "action": {}}}, "web_search_call"),
        ({"type": "response_item", "payload": {"type": "function_call", "name": "web_search"}}, "web_search"),
    ],
)
def test_web_tool_calls_are_flagged(tmp_path, record, call):
    path = write_transcript(tmp_path / "t.jsonl", [record])
    assert scan.scan([path], []) == [f"t.jsonl has a web tool call ({call})"]


# -------------------------------------------------------------- result line


def record(**overrides) -> results.RunRecord:
    base = results.RunRecord(
        run_id="b-a-example-small-slugify-1", batch="b", arm="A", task="example-small-slugify", seed=1,
        size_class="small", started_at=T0,
    )
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


FINISHED = dict(
    ended_at=T0 + timedelta(minutes=9),
    tests={"fail_to_pass": {"t1": True}, "pass_to_pass": {"t2": True}},
    diff_stats={"files_changed": 1, "insertions": 2, "deletions": 1},
    diff_path="runs/b-a-example-small-slugify-1/diff.patch",
    pr_count=1,
    usage={"claude-opus-5-5": {"input": 1, "output": 2, "cache_read": 3, "cache_write": 4}},
    usage_collector={"helper_version": "1", "nogging_commit": "abc"},
    provenance={"arm_file_hash": "sha256:a", "prompt_hash": "sha256:p", "agent_cli_version": "2.1.326",
                "image_digest": "sha256:i", "bench_commit": "c" * 40, "smoke": True},
)


@pytest.mark.parametrize("status", ["completed", "timeout", "agent_error"])
def test_a_finished_run_assembles_a_valid_line(status):
    line = record(status=status, **FINISHED).line()
    assert check_result(line) == []
    assert line["passed"] is True and line["wall_clock_seconds"] == 540
    assert line["started_at"] == "2026-11-20T10:00:00Z"
    failing = record(status=status, **{**FINISHED, "tests": {"fail_to_pass": {"t1": False}, "pass_to_pass": {}}})
    assert failing.line()["passed"] is False


def test_an_infra_error_line_is_valid_with_nothing_measured():
    rec = record(ended_at=T0 + timedelta(seconds=3), provenance={"smoke": True})
    rec.fail("starting the container failed: no such image")
    line = rec.line()
    assert check_result(line) == []
    assert (line["status"], line["passed"], line["diff_path"], line["usage"]) == ("infra_error", False, None, {})
    assert line["reason"] == "starting the container failed: no such image"


def test_lines_are_appended_and_combinations_recorded(tmp_path):
    path = tmp_path / "results" / "b.jsonl"
    results.append(path, record(status="completed", **FINISHED).line())
    results.append(path, record(run_id="b-a-example-small-slugify-1-r2", status="completed", **FINISHED).line())
    combos, ids = results.recorded(path)
    assert combos == {("A", "example-small-slugify", 1)}
    assert results.unique_run_id("b-a-example-small-slugify-1", ids) == "b-a-example-small-slugify-1-r3"
    assert len(path.read_text().splitlines()) == 2
    with pytest.raises(results.ResultError, match="status"):
        results.append(path, {**record(status="completed", **FINISHED).line(), "status": "fine"})
    assert len(path.read_text().splitlines()) == 2


# -------------------------------------------------------------- credentials


def test_an_env_credential_is_staged_privately_and_removed():
    with Credentials({"env": "BENCH_KEY"}, {"BENCH_KEY": "sk-test-0123456789"}) as creds:
        env_file = creds.env_file
        assert env_file.read_text() == "BENCH_KEY=sk-test-0123456789\n"
        assert stat.S_IMODE(env_file.stat().st_mode) == 0o600
        assert stat.S_IMODE(creds.root.stat().st_mode) == 0o700
        assert creds.redactor().redact("key sk-test-0123456789 here") == f"key {REDACTED} here"
    assert not env_file.exists() and not env_file.parent.exists()


def test_a_missing_variable_is_named_without_a_value():
    with pytest.raises(CredentialError, match="credential variable BENCH_KEY is not set"):
        with Credentials({"env": "BENCH_KEY"}, {}):
            pass


def test_a_credential_directory_is_copied_privately(tmp_path):
    source = tmp_path / "login"
    source.mkdir()
    (source / ".credentials.json").write_text(json.dumps({"oauth": {"accessToken": "tok-abcdefghijkl"}}))
    with Credentials({"dir": str(source)}, {}) as creds:
        staged = creds.staged_dir / ".credentials.json"
        assert stat.S_IMODE(staged.stat().st_mode) == 0o600
        assert creds.files == [".credentials.json"]
        assert creds.redactor().contains("Bearer tok-abcdefghijkl")
    assert not staged.exists()


def test_redaction_rewrites_copied_transcripts(tmp_path):
    path = write_transcript(tmp_path / "t" / "s.jsonl", [{"text": "echo sk-test-0123456789"}])
    Redactor(["sk-test-0123456789"]).redact_tree(tmp_path / "t")
    assert "sk-test" not in path.read_text() and REDACTED in path.read_text()


# ------------------------------------------------------ preregistration gate

PREREG = (BENCH / "tests" / "fixtures" / "valid" / "PREREGISTRATION.md").read_text(encoding="utf-8")


@pytest.fixture
def bench_repo(tmp_path) -> Path:
    bench = tmp_path / "bench"
    bench.mkdir()
    git(bench, "init", "-q")
    git(bench, "config", "user.email", "t@example.invalid")
    git(bench, "config", "user.name", "t")
    (bench / "README.md").write_text("bench\n")
    git(bench, "add", ".")
    git(bench, "commit", "-qm", "init")
    return bench


def commit_prereg(bench: Path, text: str = PREREG) -> None:
    (bench / "PREREGISTRATION.md").write_text(text)
    git(bench, "add", "PREREGISTRATION.md")
    git(bench, "commit", "-qm", "prereg")


def test_no_preregistration_no_measurement(bench_repo):
    assert prereg.preregistration_hash(bench_repo) == (
        None, ["bench/PREREGISTRATION.md is missing; a measured run needs a committed preregistration"])
    commit_prereg(bench_repo)
    (bench_repo / "PREREGISTRATION.md").write_text(PREREG + "\nchanged\n")
    assert prereg.preregistration_hash(bench_repo) == (None, ["bench/PREREGISTRATION.md has uncommitted changes"])


def test_a_committed_preregistration_yields_its_blob_hash(bench_repo):
    commit_prereg(bench_repo)
    blob, refusals = prereg.preregistration_hash(bench_repo)
    assert refusals == []
    assert blob == git(bench_repo, "hash-object", "PREREGISTRATION.md").strip()


def test_a_preregistration_without_thresholds_is_refused(bench_repo):
    commit_prereg(bench_repo, "# Plan\n\nNo block.\n")
    blob, refusals = prereg.preregistration_hash(bench_repo)
    assert blob is None and "no valid thresholds block" in refusals[0]


def test_a_candidate_task_is_not_measured():
    task = example_task()
    task["curation"] = {"status": "candidate"}
    assert prereg.task_refusals(task) == [
        "task example-small-slugify has curation.status candidate; a measured run needs accepted (or --smoke)"]
    task["curation"] = {"status": "accepted", "hidden_tests_verified_by": "PO", "verified_on": "2026-11-20"}
    assert prereg.task_refusals(task) == []


def test_env_file_is_not_world_readable_even_with_a_loose_umask():
    old = os.umask(0)
    try:
        with Credentials({"env": "K"}, {"K": "value-0123456789"}) as creds:
            assert stat.S_IMODE(creds.env_file.stat().st_mode) == 0o600
    finally:
        os.umask(old)
