"""Shared helpers of the curation tests: a temporary bench checkout with a committed
fixture preregistration, the stub ``gh`` and the example fixture repository."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import yaml
from conftest import BENCH, FIXTURES

STUBS = BENCH / "tests" / "stubs"
PREREG_TEXT = (FIXTURES / "curation" / "PREREGISTRATION.md").read_text(encoding="utf-8")
BUNDLE = BENCH / "examples" / "fixture-repo.bundle"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout


def commit(bench: Path, message: str) -> str:
    git(bench, "add", "--all", ".")
    git(bench, "commit", "-qm", message)
    return git(bench, "rev-parse", "HEAD").strip()


def make_bench(tmp_path: Path, prereg_text: str | None = PREREG_TEXT) -> Path:
    """``<tmp>/checkout/bench`` in a fresh git repository, the preregistration committed (unless None)."""
    bench = tmp_path / "checkout" / "bench"
    (bench / "curation").mkdir(parents=True)
    git(bench, "init", "-q", "-b", "main", str(bench.parent))
    git(bench, "config", "user.email", "t@example.invalid")
    git(bench, "config", "user.name", "t")
    shutil.copy(FIXTURES / "curation" / "exclude.yaml", bench / "curation" / "exclude.yaml")
    if prereg_text is not None:
        (bench / "PREREGISTRATION.md").write_text(prereg_text, encoding="utf-8")
    commit(bench, "preregistration")
    return bench


def stub_gh(tmp_path: Path, monkeypatch, responses: list[tuple[list[str], object]]) -> Path:
    """Put the stub ``gh`` on PATH replaying ``responses`` (``(texts to match, body)``); returns its log."""
    root = tmp_path / "gh"
    root.mkdir()
    index = []
    for number, (match, body) in enumerate(responses):
        name = f"response-{number}"
        (root / name).write_text(body if isinstance(body, str) else json.dumps(body), encoding="utf-8")
        index.append({"match": match, "file": name})
    (root / "index.json").write_text(json.dumps(index), encoding="utf-8")
    monkeypatch.setenv("PATH", f"{STUBS}:{os.environ['PATH']}")
    monkeypatch.setenv("STUB_GH_DIR", str(root))
    monkeypatch.setenv("STUB_GH_LOG", str(root / "calls.jsonl"))
    return root / "calls.jsonl"


def gh_calls(log: Path) -> list[list[str]]:
    return [json.loads(line)["argv"] for line in log.read_text(encoding="utf-8").splitlines()]


def read_task(bench: Path, task_id: str) -> dict:
    return yaml.safe_load((bench / "tasks" / task_id / "task.yaml").read_text(encoding="utf-8"))
