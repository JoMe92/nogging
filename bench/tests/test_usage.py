"""The usage helper counts both vendors through the host checkout's adapters (Decision 10)."""

from __future__ import annotations

import json
import subprocess
import sys

import pytest
from conftest import BENCH, FIXTURES

from nogg_bench import usage
from nogg_bench.usage_helper import EXIT_ADAPTERS_MISSING

REPO_ROOT = BENCH.parent
CLAUDE = FIXTURES / "transcripts" / "claude"
CODEX = FIXTURES / "transcripts" / "codex"

# What Nogging's adapters report directly, last revision per event, summed per
# model: inclusive input, output, cache read, cache write.
DIRECT = """
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import token_usage_adapters as a
last = {}
claude = a.ClaudeAdapter()
for runtime, root in (("claude", sys.argv[2]), ("codex", sys.argv[3])):
    for path in sorted(Path(root).rglob("*.jsonl")):
        adapter = claude if runtime == "claude" else a.CodexAdapter()
        for row in a.read_source_lines(path)[0]:
            got = adapter.parse_record(row)
            if got:
                last[(got[1]["source_id"], got[1]["event_id"])] = got[1]
out = {}
for f in last.values():
    m = out.setdefault(f["model"], [0, 0, 0, 0])
    m[0] += f["input_tokens"]; m[1] += f["output_tokens"]
    m[2] += f["cache_read_tokens"] or 0; m[3] += f["cache_write_tokens"] or 0
print(json.dumps(out))
"""


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


def test_the_counts_are_the_ones_nogging_adapters_produce():
    direct = subprocess.run(
        [sys.executable, "-I", "-c", DIRECT, str(REPO_ROOT / "scripts" / "lib"), str(CLAUDE), str(CODEX)],
        capture_output=True, text=True, check=True,
    )
    expected = json.loads(direct.stdout)
    got = usage.collect(REPO_ROOT, [CLAUDE], [CODEX]).usage
    for model, (inclusive, output, cache_read, cache_write) in expected.items():
        counts = got[model]
        assert counts["input"] + counts["cache_read"] + counts["cache_write"] == inclusive
        assert (counts["output"], counts["cache_read"], counts["cache_write"]) == (output, cache_read, cache_write)


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
