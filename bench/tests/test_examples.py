"""The three example tasks: valid, and their hidden tests do what a task promises.

For each example the hidden tests fail on the base commit and pass on the fix
commit, inside the unpacked fixture bundle, with the task's own test command.
"""

from __future__ import annotations

import shlex
import subprocess
import sys
from pathlib import Path

import pytest
import yaml
from conftest import BENCH

from nogg_bench.schema import check_task
from nogg_bench.validate import validate

EXAMPLES = BENCH / "examples"
TASK_DIRS = sorted(p for p in (EXAMPLES / "tasks").iterdir() if p.is_dir())
BUNDLE = EXAMPLES / "fixture-repo.bundle"

GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "PATH": "/usr/bin:/bin:/usr/local/bin"}


def _git(cwd: Path, *args: str) -> str:
    import os

    env = {**os.environ, **GIT_ENV}
    done = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    assert done.returncode == 0, f"git {' '.join(args)}: {done.stderr}"
    return done.stdout.strip()


def _task(task_dir: Path) -> dict:
    return yaml.safe_load((task_dir / "task.yaml").read_text())


@pytest.fixture(scope="module")
def unpacked(tmp_path_factory) -> Path:
    """The fixture bundle cloned once; each test makes a cheap detached worktree of it."""
    clone = tmp_path_factory.mktemp("bundle") / "repo"
    _git(clone.parent, "clone", "-q", str(BUNDLE), str(clone))
    return clone


def _checkout(unpacked: Path, tmp_path: Path, commit: str) -> Path:
    work = tmp_path / "work"
    _git(unpacked, "worktree", "add", "-q", "--detach", str(work), commit)
    return work


def _run_tests(work: Path, task: dict) -> dict[str, bool]:
    """Run the task's test command on the identifiers and report passed or not per identifier."""
    hidden = task["hidden_tests"]
    ids = hidden["fail_to_pass"] + hidden["pass_to_pass"]
    argv = shlex.split(task["environment"]["test_command"].format(tests=" ".join(shlex.quote(i) for i in ids)))
    if argv[0] == "python":
        argv[0] = sys.executable
    done = subprocess.run(argv, cwd=work, capture_output=True, text=True, timeout=task["environment"]["test_timeout_seconds"])
    passed = {line.split(maxsplit=1)[1].split(" - ")[0] for line in done.stdout.splitlines() if line.startswith("PASSED ")}
    return {i: i in passed for i in ids}


def test_there_is_one_example_per_size_class():
    classes = sorted(_task(d)["size_class"] for d in TASK_DIRS)
    assert classes == ["large", "medium", "small"]


@pytest.mark.parametrize("task_dir", TASK_DIRS, ids=lambda p: p.name)
def test_an_example_task_is_valid_and_marked_as_an_example(task_dir):
    assert validate([task_dir], BENCH) == []
    assert _task(task_dir)["curation"]["status"] == "example"


@pytest.mark.parametrize("task_dir", TASK_DIRS, ids=lambda p: p.name)
def test_the_hidden_tests_fail_on_the_base_and_pass_on_the_fix(task_dir, unpacked, tmp_path):
    task = _task(task_dir)
    patch = (task_dir / task["hidden_tests"]["patch"]).resolve()
    base = task["base_commit"]
    fix = _git(unpacked, "rev-list", "--reverse", "--ancestry-path", f"{base}..origin/main").splitlines()[0]

    (tmp_path / "base").mkdir()
    on_base = _checkout(unpacked, tmp_path / "base", base)
    _git(on_base, "apply", str(patch))
    base_result = _run_tests(on_base, task)
    for ident in task["hidden_tests"]["fail_to_pass"]:
        assert base_result[ident] is False, f"{ident} must fail on the base commit"
    for ident in task["hidden_tests"]["pass_to_pass"]:
        assert base_result[ident] is True, f"{ident} must pass on the base commit"

    (tmp_path / "fix").mkdir()
    on_fix = _checkout(unpacked, tmp_path / "fix", fix)
    _git(on_fix, "apply", str(patch))
    fix_result = _run_tests(on_fix, task)
    assert all(fix_result.values()), {k: v for k, v in fix_result.items() if not v}


@pytest.mark.parametrize("task_dir", TASK_DIRS, ids=lambda p: p.name)
def test_the_base_commit_is_in_the_bundle_and_the_fix_is_one_commit_later(task_dir, unpacked):
    base = _task(task_dir)["base_commit"]
    assert _git(unpacked, "cat-file", "-t", base) == "commit"
    children = _git(unpacked, "rev-list", "--children", "--all").splitlines()
    assert any(line.startswith(base + " ") for line in children), "the base commit has no fix after it"


def test_the_hidden_tests_are_not_in_the_repository_history(unpacked):
    names = _git(unpacked, "log", "--all", "--name-only", "--pretty=format:").splitlines()
    assert "tests/test_config.py" not in names
