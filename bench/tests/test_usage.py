"""The usage helper counts both vendors through the host checkout's adapters (Decision 10)."""

from __future__ import annotations

import subprocess
import sys

import pytest
from conftest import BENCH, FIXTURES

from nogg_bench import usage
from nogg_bench.usage_helper import EXIT_ADAPTERS_MISSING

REPO_ROOT = BENCH.parent
CLAUDE = FIXTURES / "transcripts" / "claude"
CODEX = FIXTURES / "transcripts" / "codex"


def test_both_vendors_are_counted_the_same_way():
    got = usage.collect(REPO_ROOT, [CLAUDE], [CODEX])
    assert got.usage == {
        # msg_1 counted once at its last revision (output 300), plus msg_2
        "claude-opus-5-5": {"input": 1400, "output": 420, "cache_read": 17000, "cache_write": 600},
        # the event_msg token_count summary is ignored, as Nogging's collector does
        "gpt-6.1-sol": {"input": 3000, "output": 650, "cache_read": 9000, "cache_write": 0},
    }
    head = subprocess.run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"], capture_output=True, text=True)
    assert got.nogging_commit == head.stdout.strip()
    assert got.collector() == {"helper_version": "1", "nogging_commit": got.nogging_commit}


def test_no_transcripts_count_nothing():
    assert usage.collect(REPO_ROOT, [], []).usage == {}


def test_the_adapters_moved(tmp_path):
    with pytest.raises(usage.UsageHelperError, match="usage helper failed: .*adapters not found at"):
        usage.collect(tmp_path, [CLAUDE], [CODEX])
    done = subprocess.run(
        [sys.executable, "-I", str(usage.HELPER), "--nogging", str(tmp_path)], capture_output=True, text=True
    )
    assert done.returncode == EXIT_ADAPTERS_MISSING
    assert done.stdout == ""
