"""Token usage of a run, counted by the usage helper process (design Decision 10).

The bench process never imports Nogging. It starts :mod:`nogg_bench.usage_helper`
as an isolated child process (``python3 -I``), which loads Nogging's adapters
from the configured checkout and prints per-model counters as JSON.
"""

from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HELPER = Path(__file__).with_name("usage_helper.py")


class UsageHelperError(Exception):
    """The helper failed; the run records ``infra_error`` naming the helper."""


@dataclass(frozen=True)
class Usage:
    usage: dict
    helper_version: str
    nogging_commit: str

    def collector(self) -> dict:
        return {"helper_version": self.helper_version, "nogging_commit": self.nogging_commit}


def collect(nogging_checkout: Path, claude_dirs: list[Path], codex_dirs: list[Path]) -> Usage:
    argv = [sys.executable, "-I", str(HELPER), "--nogging", str(nogging_checkout)]
    for d in claude_dirs:
        argv += ["--claude", str(d)]
    for d in codex_dirs:
        argv += ["--codex", str(d)]
    done = subprocess.run(argv, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        detail = (done.stderr.strip().splitlines() or [f"exit status {done.returncode}"])[-1]
        raise UsageHelperError(f"usage helper failed: {detail}")
    try:
        data = json.loads(done.stdout)
        return Usage(data["usage"], data["helper_version"], data["nogging_commit"])
    except (ValueError, KeyError, TypeError) as exc:
        raise UsageHelperError(f"usage helper printed no usable result: {exc}") from exc
