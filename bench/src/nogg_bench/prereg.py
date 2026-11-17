"""The preregistration and curation gate of a measured run (design Decision 11).

A measured run (no ``--smoke``) needs ``bench/PREREGISTRATION.md`` committed,
unchanged in the working tree, with a valid thresholds block, and a task whose
curation status is ``accepted``. The gate runs before any container starts.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from nogg_bench.records import RecordError, load_thresholds

PREREGISTRATION = "PREREGISTRATION.md"


def _git(bench: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(bench), *args], capture_output=True, text=True, check=False)


def preregistration_hash(bench: Path) -> tuple[str | None, list[str]]:
    """``(blob hash, refusals)`` for the preregistration; the hash is None when refused."""
    path = bench / PREREGISTRATION
    name = f"bench/{PREREGISTRATION}"
    if not path.is_file():
        return None, [f"{name} is missing; a measured run needs a committed preregistration"]
    if _git(bench, "ls-files", "--error-unmatch", "--", PREREGISTRATION).returncode != 0:
        return None, [f"{name} is not committed"]
    status = _git(bench, "status", "--porcelain", "--", PREREGISTRATION)
    if status.returncode != 0 or status.stdout.strip():
        return None, [f"{name} has uncommitted changes"]
    try:
        load_thresholds(path)
    except RecordError as exc:
        return None, [f"{name} has no valid thresholds block: {exc.problem.message}"]
    blob = _git(bench, "rev-parse", f"HEAD:./{PREREGISTRATION}")
    if blob.returncode != 0:
        return None, [f"{name} is not in the current commit"]
    return blob.stdout.strip(), []


def task_refusals(task: dict) -> list[str]:
    status = task["curation"]["status"]
    if status != "accepted":
        return [f"task {task['id']} has curation.status {status}; a measured run needs accepted (or --smoke)"]
    return []


def bench_commit(bench: Path) -> str:
    done = _git(bench, "rev-parse", "HEAD")
    return done.stdout.strip() if done.returncode == 0 else "unknown"
