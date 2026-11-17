#!/usr/bin/env python3
"""Rebuild the fixture repository bundle and the example tasks' hidden patches.

The three example tasks run against ``fixture-repo.bundle``, a tiny Python
library ("miniutil") with three commits that each fix one task's issue:

    c0 initial -> c1 (small: slugify) -> c2 (medium: durations) -> c3 (large: config)

A task's base commit is the commit before its fix; the hidden tests are a patch
that adds that fix's tests and is *not* part of the repository history.

Commit identities and dates are fixed, so rebuilding gives the same SHAs. It
needs only git and the standard library. The script prints the SHAs to put in
each ``task.yaml`` (``base_commit``); ``tests/test_examples.py`` fails when they
drift.

    python3 bench/examples/build_fixture_repo.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

# --------------------------------------------------------------- file contents

BASE = {
    "README.md": """# miniutil

Small helpers used as the fixture repository of the nogg-bench example tasks.
""",
    "pytest.ini": """[pytest]
pythonpath = src
testpaths = tests
""",
    "src/miniutil/__init__.py": """from .durations import parse_duration
from .text import slugify, truncate

__all__ = ["parse_duration", "slugify", "truncate"]
""",
    "src/miniutil/text.py": '''"""Small text helpers."""


def slugify(text: str) -> str:
    """Lower-case ``text`` and join its words with dashes."""
    out = []
    for ch in text.lower():
        out.append(ch if ch.isalnum() else "-")
    return "".join(out).strip("-")


def truncate(text: str, width: int, marker: str = "...") -> str:
    """Shorten ``text`` to ``width`` characters, ending in ``marker`` when cut."""
    if width < len(marker):
        raise ValueError("width is smaller than the marker")
    if len(text) <= width:
        return text
    return text[: width - len(marker)] + marker
''',
    "src/miniutil/units.py": '''"""Time units, in seconds."""

UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600}
''',
    "src/miniutil/durations.py": '''"""Duration parsing."""

from .units import UNIT_SECONDS


def parse_duration(text: str) -> int:
    """Parse a single-unit duration such as ``90s``, ``5m`` or ``2h`` into seconds."""
    text = text.strip().lower()
    if len(text) < 2 or not text[:-1].isdigit() or text[-1] not in UNIT_SECONDS:
        raise ValueError(f"not a duration: {text!r}")
    return int(text[:-1]) * UNIT_SECONDS[text[-1]]
''',
    "tests/test_text.py": '''from miniutil import slugify, truncate


def test_slugify_basic():
    assert slugify("Hello World") == "hello-world"


def test_truncate_short_text_is_unchanged():
    assert truncate("abc", 5) == "abc"


def test_truncate_adds_marker():
    assert truncate("abcdefghij", 6) == "abc..."
''',
    "tests/test_durations.py": '''import pytest

from miniutil import parse_duration


def test_single_unit():
    assert parse_duration("90s") == 90
    assert parse_duration("5m") == 300


def test_rejects_garbage():
    with pytest.raises(ValueError):
        parse_duration("soon")
''',
}

# ------------------------------------------------------------------ small task
SMALL_FIX = {
    "src/miniutil/text.py": BASE["src/miniutil/text.py"].replace(
        '''    out = []
    for ch in text.lower():
        out.append(ch if ch.isalnum() else "-")
    return "".join(out).strip("-")
''',
        '''    return re.sub(r"[\\W_]+", "-", text.lower()).strip("-")
''',
    ).replace('"""Small text helpers."""\n', '"""Small text helpers."""\n\nimport re\n'),
}
SMALL_HIDDEN = {
    "tests/test_text.py": BASE["tests/test_text.py"]
    + '''

def test_slugify_collapses_separators():
    assert slugify("Hello,   World!!") == "hello-world"


def test_slugify_strips_edges():
    assert slugify("  --Hello-- ") == "hello"
''',
}

# ----------------------------------------------------------------- medium task
MEDIUM_FIX = {
    "src/miniutil/units.py": '''"""Time units, in seconds."""

UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400}
''',
    "src/miniutil/durations.py": '''"""Duration parsing and formatting."""

import re

from .units import UNIT_SECONDS

_PART = re.compile(r"(\\d+)([a-z])")


def parse_duration(text: str) -> int:
    """Parse ``90s``, ``5m``, ``2h``, ``1d`` or a compound such as ``1h30m`` into seconds."""
    text = text.strip().lower()
    parts = _PART.findall(text)
    if not parts or "".join(n + u for n, u in parts) != text or any(u not in UNIT_SECONDS for _, u in parts):
        raise ValueError(f"not a duration: {text!r}")
    return sum(int(n) * UNIT_SECONDS[u] for n, u in parts)


def format_duration(seconds: int) -> str:
    """Write ``seconds`` as the shortest compound duration, e.g. ``5400`` as ``1h30m``."""
    if seconds < 0:
        raise ValueError("a duration cannot be negative")
    if seconds == 0:
        return "0s"
    out = []
    for unit, size in sorted(UNIT_SECONDS.items(), key=lambda item: -item[1]):
        count, seconds = divmod(seconds, size)
        if count:
            out.append(f"{count}{unit}")
    return "".join(out)
''',
    "src/miniutil/__init__.py": '''from .durations import format_duration, parse_duration
from .text import slugify, truncate

__all__ = ["format_duration", "parse_duration", "slugify", "truncate"]
''',
}
MEDIUM_HIDDEN = {
    "tests/test_durations.py": BASE["tests/test_durations.py"].replace(
        "from miniutil import parse_duration\n", "import miniutil\nfrom miniutil import parse_duration\n"
    )
    + '''

def test_compound_duration():
    assert parse_duration("1h30m") == 5400


def test_day_unit():
    assert parse_duration("2d") == 172800


def test_format_duration():
    assert miniutil.format_duration(5400) == "1h30m"
    assert miniutil.format_duration(0) == "0s"


def test_format_round_trips():
    assert parse_duration(miniutil.format_duration(93784)) == 93784
''',
}

# ------------------------------------------------------------------ large task
LARGE_FIX = {
    "src/miniutil/config.py": '''"""Layered configuration: defaults, environment, then explicit overrides."""

from __future__ import annotations

from typing import Any, Mapping


def merge(*layers: Mapping[str, Any]) -> dict[str, Any]:
    """Deep-merge ``layers``. Later layers win; mappings merge, everything else is replaced."""
    result: dict[str, Any] = {}
    for layer in layers:
        for key, value in layer.items():
            if isinstance(value, Mapping):
                base = result.get(key)
                result[key] = merge(base if isinstance(base, dict) else {}, value)
            else:
                result[key] = value
    return result


def set_path(target: dict[str, Any], path: list[str], value: Any) -> None:
    """Set ``value`` at the nested ``path`` of ``target``, creating mappings on the way."""
    for part in path[:-1]:
        nested = target.setdefault(part, {})
        if not isinstance(nested, dict):
            nested = target[part] = {}
        target = nested
    target[path[-1]] = value


def from_environ(environ: Mapping[str, str], prefix: str = "MINIUTIL_") -> dict[str, Any]:
    """Read ``MINIUTIL_DB__HOST=x`` as ``{"db": {"host": "x"}}``."""
    out: dict[str, Any] = {}
    for name, value in environ.items():
        if name.startswith(prefix):
            path = [part.lower() for part in name[len(prefix):].split("__") if part]
            if path:
                set_path(out, path, value)
    return out


def from_assignments(assignments: list[str]) -> dict[str, Any]:
    """Read ``["db.host=x"]`` as ``{"db": {"host": "x"}}``."""
    out: dict[str, Any] = {}
    for item in assignments:
        key, sep, value = item.partition("=")
        if not sep or not key:
            raise ValueError(f"not an assignment: {item!r}")
        set_path(out, key.split("."), value)
    return out


def load(defaults: Mapping[str, Any], environ: Mapping[str, str] | None = None, overrides: list[str] | None = None) -> dict[str, Any]:
    """Merge defaults, then the environment, then ``key=value`` overrides."""
    return merge(defaults, from_environ(environ or {}), from_assignments(overrides or []))
''',
    "src/miniutil/cli.py": '''"""Command line: ``python -m miniutil show --set db.host=x``."""

from __future__ import annotations

import argparse
import json
import os
import sys

from .config import load

DEFAULTS = {"debug": "false", "db": {"host": "localhost", "port": "5432"}}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="miniutil")
    sub = parser.add_subparsers(dest="command", required=True)
    show = sub.add_parser("show", help="print the effective configuration as JSON")
    show.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    args = parser.parse_args(argv)
    try:
        config = load(DEFAULTS, os.environ, args.set)
    except ValueError as exc:
        print(f"miniutil: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(config, sort_keys=True))
    return 0
''',
    "src/miniutil/__main__.py": '''import sys

from .cli import main

sys.exit(main())
''',
    "src/miniutil/__init__.py": MEDIUM_FIX["src/miniutil/__init__.py"].replace(
        "from .text import", "from .config import load\nfrom .text import"
    ).replace('__all__ = ["format_duration",', '__all__ = ["format_duration", "load",'),
    "README.md": BASE["README.md"]
    + """
## Configuration

`python -m miniutil show` prints the effective configuration. It layers the
defaults, then `MINIUTIL_*` environment variables (`MINIUTIL_DB__HOST=x` sets
`db.host`), then `--set key=value` options.
""",
}
LARGE_HIDDEN = {
    "tests/test_config.py": '''import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class _Lazy:
    """Import miniutil.config when used, so a missing module fails each test, not the whole file."""

    def __getattr__(self, name):
        import importlib

        return getattr(importlib.import_module("miniutil.config"), name)


config = _Lazy()


def test_merge_is_deep():
    merged = config.merge({"db": {"host": "a", "port": 1}}, {"db": {"host": "b"}})
    assert merged == {"db": {"host": "b", "port": 1}}


def test_later_layer_replaces_non_mappings():
    assert config.merge({"x": [1]}, {"x": [2]}) == {"x": [2]}


def test_merge_does_not_change_its_inputs():
    first = {"db": {"host": "a"}}
    config.merge(first, {"db": {"host": "b"}})
    assert first == {"db": {"host": "a"}}


def test_environment_layer():
    env = {"MINIUTIL_DB__HOST": "e", "OTHER": "ignored"}
    assert config.from_environ(env) == {"db": {"host": "e"}}


def test_assignment_layer_and_error():
    assert config.from_assignments(["a.b=1"]) == {"a": {"b": "1"}}
    try:
        config.from_assignments(["nonsense"])
    except ValueError:
        return
    raise AssertionError("an assignment without = must be refused")


def test_cli_override_beats_environment():
    env = {**os.environ, "PYTHONPATH": str(ROOT / "src"), "MINIUTIL_DB__HOST": "from-env"}
    out = subprocess.run(
        [sys.executable, "-m", "miniutil", "show", "--set", "db.host=from-flag"],
        capture_output=True, text=True, env=env, cwd=ROOT, check=True,
    )
    assert json.loads(out.stdout)["db"]["host"] == "from-flag"
''',
}

TASKS = [
    ("small", SMALL_FIX, SMALL_HIDDEN, "example-small-slugify"),
    ("medium", MEDIUM_FIX, MEDIUM_HIDDEN, "example-medium-durations"),
    ("large", LARGE_FIX, LARGE_HIDDEN, "example-large-config"),
]

# ------------------------------------------------------------------- building


def git(repo: Path, *args: str, env_extra: dict | None = None) -> str:
    env = {
        **os.environ,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_SYSTEM": os.devnull,
        "GIT_AUTHOR_NAME": "Bench Fixture",
        "GIT_AUTHOR_EMAIL": "bench-fixture@example.invalid",
        "GIT_COMMITTER_NAME": "Bench Fixture",
        "GIT_COMMITTER_EMAIL": "bench-fixture@example.invalid",
        **(env_extra or {}),
    }
    done = subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True, text=True)
    return done.stdout.strip()


def write(repo: Path, files: dict[str, str]) -> None:
    for rel, text in files.items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def commit(repo: Path, message: str, when: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message, env_extra={"GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when})
    return git(repo, "rev-parse", "HEAD")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp) / "miniutil"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        write(repo, BASE)
        head = commit(repo, "Initial miniutil", "2026-01-01T00:00:00+0000")
        for number, (size, fix, hidden, task_id) in enumerate(TASKS, start=1):
            base = head
            # The hidden tests as a patch against the base, not committed.
            write(repo, hidden)
            git(repo, "add", "-N", ".")
            patch = git(repo, "diff") + "\n"
            git(repo, "reset", "-q")
            git(repo, "checkout", "-q", "--", ".")
            git(repo, "clean", "-fdq")
            patch_path = HERE / "tasks" / task_id / "hidden" / "tests.patch"
            patch_path.parent.mkdir(parents=True, exist_ok=True)
            patch_path.write_text(patch, encoding="utf-8")
            write(repo, fix)
            head = commit(repo, f"Fix: {task_id}", f"2026-01-0{number + 1}T00:00:00+0000")
            print(f"{task_id}: base_commit {base}  fix_commit {head}")
        bundle = HERE / "fixture-repo.bundle"
        if bundle.exists():
            bundle.unlink()
        git(repo, "bundle", "create", str(bundle), "main")
        shutil.rmtree(repo / ".git", ignore_errors=True)
    print(f"wrote {bundle}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
