"""Assembling and appending result lines (design Decision 9).

:class:`RunRecord` collects what a run learned, step by step, and turns it
into one result line for any status; the line is checked against the BEN-001
schema before it is written. :func:`append` adds it to the batch file in one
locked, synced write and never rewrites an existing line.
"""

from __future__ import annotations

import fcntl
import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from nogg_bench.records import read_jsonl
from nogg_bench.schema import SCHEMA_VERSION, check_result
from nogg_bench.usage_helper import HELPER_VERSION
from nogg_bench.workspace import passes

UNKNOWN = "unknown"


def run_id_for(batch: str, arm: str, task: str, seed: int) -> str:
    return f"{batch}-{arm.lower()}-{task}-{seed}"


def _stamp(moment: datetime) -> str:
    return moment.isoformat().replace("+00:00", "Z")


@dataclass
class RunRecord:
    run_id: str
    batch: str
    arm: str
    task: str
    seed: int
    size_class: str
    started_at: datetime
    source: str = "bench"
    ended_at: datetime | None = None
    status: str = "infra_error"
    reason: str | None = None
    tests: dict = field(default_factory=lambda: {"fail_to_pass": {}, "pass_to_pass": {}})
    hidden_paths_overwritten: list[str] = field(default_factory=list)
    contamination_suspect: bool = False
    diff_stats: dict | None = None
    diff_path: str | None = None
    markdown_lines: int = 0
    pr_count: int = 0
    usage: dict = field(default_factory=dict)
    usage_collector: dict = field(
        default_factory=lambda: {"helper_version": HELPER_VERSION, "nogging_commit": UNKNOWN}
    )
    provenance: dict = field(default_factory=dict)

    def fail(self, reason: str) -> None:
        """Mark the run as an infrastructure failure with ``reason``."""
        self.status = "infra_error"
        self.reason = reason

    def line(self) -> dict:
        ended = self.ended_at or self.started_at
        prov = {
            "arm_file_hash": UNKNOWN, "prompt_hash": UNKNOWN, "agent_cli_version": UNKNOWN,
            "image_digest": UNKNOWN, "bench_commit": UNKNOWN, "nogging_ref": None,
            "preregistration_hash": None, "smoke": False, **self.provenance,
        }
        line = {
            "schema": SCHEMA_VERSION,
            "run_id": self.run_id, "batch": self.batch, "arm": self.arm, "task": self.task,
            "seed": self.seed, "size_class": self.size_class, "source": self.source,
            "started_at": _stamp(self.started_at), "ended_at": _stamp(ended),
            "wall_clock_seconds": round((ended - self.started_at).total_seconds(), 3),
            "status": self.status,
            "passed": self.status != "infra_error" and passes(self.tests),
            "tests": self.tests,
            "hidden_paths_overwritten": sorted(self.hidden_paths_overwritten),
            "contamination_suspect": self.contamination_suspect,
            "diff_stats": self.diff_stats, "diff_path": self.diff_path,
            "markdown_lines": self.markdown_lines, "pr_count": self.pr_count,
            "usage": self.usage, "usage_collector": self.usage_collector,
            "provenance": prov,
        }
        if self.reason is not None:
            line["reason"] = self.reason
        return line


class ResultError(Exception):
    pass


def append(path: Path, line: dict) -> None:
    """Validate ``line`` and append it to ``path`` atomically (one write under an exclusive lock)."""
    problems = check_result(line)
    if problems:
        raise ResultError("result line is invalid: " + "; ".join(str(p.at(str(path))) for p in problems))
    data = (json.dumps(line, sort_keys=True) + "\n").encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)


def recorded(path: Path) -> tuple[set[tuple[str, str, int]], set[str]]:
    """The (arm, task, seed) combinations and the run IDs already in a batch file."""
    combos: set[tuple[str, str, int]] = set()
    ids: set[str] = set()
    if not path.is_file():
        return combos, ids
    for _number, line in read_jsonl(path):
        if isinstance(line, dict):
            combos.add((line.get("arm"), line.get("task"), line.get("seed")))
            ids.add(line.get("run_id"))
    return combos, ids


def unique_run_id(base: str, taken: set[str]) -> str:
    if base not in taken:
        return base
    n = 2
    while f"{base}-r{n}" in taken:
        n += 1
    return f"{base}-r{n}"
