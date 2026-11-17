"""The contamination scan over a run's transcripts (design Decision 7).

Network egress cannot be closed while the agent needs its model API, so a run
is marked ``contamination_suspect`` when a transcript shows a web tool call,
or mentions the task's issue URL or fix pull request URL.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable

# Tool names of web access in Claude Code and Codex transcripts.
WEB_TOOL_NAMES = {"WebSearch", "WebFetch", "web_search", "web_fetch", "web.run", "browser"}
WEB_RECORD_TYPES = {"web_search_call", "web_search", "web_fetch_call"}


def _web_calls(record) -> list[str]:
    found: list[str] = []
    stack = [record]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            kind, name = item.get("type"), item.get("name")
            if kind in WEB_RECORD_TYPES:
                found.append(str(kind))
            elif kind in ("tool_use", "function_call", "server_tool_use", "custom_tool_call") and name in WEB_TOOL_NAMES:
                found.append(str(name))
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)
    return found


def scan(files: Iterable[Path], urls: Iterable[str]) -> list[str]:
    """Why the transcripts are suspect, one reason per finding; empty when clean."""
    needles = sorted({u.rstrip("/") for u in urls if u})
    reasons: list[str] = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for url in needles:
            if url in text:
                reasons.append(f"{path.name} mentions {url}")
        for line in text.splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            for call in _web_calls(record):
                reasons.append(f"{path.name} has a web tool call ({call})")
    return sorted(set(reasons))


def transcript_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*") if p.is_file()) if root.is_dir() else []
