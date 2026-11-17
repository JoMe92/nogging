"""The usage helper process (design Decision 10). Run it as a script, never import it for use.

    python3 -I usage_helper.py --nogging <checkout> [--claude <dir>]... [--codex <dir>]...

It is the one place that knows where Nogging's token-usage adapters live
(``scripts/lib/token_usage_adapters.py`` in a Nogging checkout) and how to call
them. It feeds every ``*.jsonl`` transcript under the given directories through
Nogging's own ``ClaudeAdapter`` or ``CodexAdapter``, keeps the last revision of
each usage event, and prints one JSON object to stdout::

    {"helper_version": "1", "nogging_commit": "<sha>",
     "usage": {"<model>": {"input": n, "output": n, "cache_read": n, "cache_write": n}}}

``input`` is the uncached input: both adapters report input inclusive of
cached tokens, so the cache-read and cache-write counts are subtracted, the
same way for both vendors.

Exit status 3 means the adapters could not be loaded (they moved, or the
checkout is wrong); the message on stderr names the path. Importing this module
loads nothing from Nogging: that happens only in :func:`main`.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HELPER_VERSION = "1"
ADAPTERS = Path("scripts/lib/token_usage_adapters.py")
EXIT_ADAPTERS_MISSING = 3


def load_adapters(checkout: Path):
    """Import Nogging's adapter module from ``checkout``; raise ImportError naming the path."""
    module_path = checkout / ADAPTERS
    if not module_path.is_file():
        raise ImportError(f"Nogging token-usage adapters not found at {module_path}")
    sys.path.insert(0, str(module_path.parent))
    try:
        import token_usage_adapters as adapters  # noqa: PLC0415 - loaded from the checkout on purpose
    except Exception as exc:  # any failure to load means the contract moved
        raise ImportError(f"cannot load {module_path}: {exc}") from exc
    for name in ("ClaudeAdapter", "CodexAdapter", "read_source_lines"):
        if not hasattr(adapters, name):
            raise ImportError(f"{module_path} has no {name}")
    return adapters


def nogging_commit(checkout: Path) -> str:
    done = subprocess.run(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], capture_output=True, text=True, check=False
    )
    return done.stdout.strip() if done.returncode == 0 else "unknown"


def transcripts(dirs: list[Path]) -> list[Path]:
    out: list[Path] = []
    for d in dirs:
        if d.is_file():
            out.append(d)
        elif d.is_dir():
            out.extend(sorted(p for p in d.rglob("*.jsonl") if p.is_file()))
    return out


def count(adapters, claude_dirs: list[Path], codex_dirs: list[Path]) -> dict:
    """Per-model counters from the transcripts, through Nogging's adapters."""
    last: dict[tuple[str, str], dict] = {}
    claude = adapters.ClaudeAdapter()  # one adapter: deduplicates snapshots across files
    for runtime, dirs in (("claude", claude_dirs), ("codex", codex_dirs)):
        for path in transcripts(dirs):
            # A Codex adapter carries the rollout's model context, so one per file.
            adapter = claude if runtime == "claude" else adapters.CodexAdapter()
            rows, _offset, _partial = adapters.read_source_lines(path)
            for row in rows:
                parsed = adapter.parse_record(row)
                if parsed:
                    fact = parsed[1]
                    last[(fact["source_id"], fact["event_id"])] = fact
    usage: dict[str, dict[str, int]] = {}
    for fact in last.values():
        model = fact.get("model") or "unknown"
        cache_read = fact.get("cache_read_tokens") or 0
        cache_write = fact.get("cache_write_tokens") or 0
        counters = usage.setdefault(model, {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0})
        counters["input"] += max((fact.get("input_tokens") or 0) - cache_read - cache_write, 0)
        counters["output"] += fact.get("output_tokens") or 0
        counters["cache_read"] += cache_read
        counters["cache_write"] += cache_write
    return dict(sorted(usage.items()))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--nogging", required=True, type=Path, help="the Nogging checkout whose adapters to use")
    parser.add_argument("--claude", action="append", default=[], type=Path, help="Claude Code transcript directory")
    parser.add_argument("--codex", action="append", default=[], type=Path, help="Codex session directory")
    args = parser.parse_args(argv)
    try:
        adapters = load_adapters(args.nogging.resolve())
    except ImportError as exc:
        print(f"usage helper: {exc}", file=sys.stderr)
        return EXIT_ADAPTERS_MISSING
    result = {
        "helper_version": HELPER_VERSION,
        "nogging_commit": nogging_commit(args.nogging),
        "usage": count(adapters, args.claude, args.codex),
    }
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
