"""Reading the benchmark's files: YAML, JSON Lines and the thresholds block.

These loaders are the shared entry points for ``run``, ``review-pack`` and
``report``. They raise :class:`RecordError` with the file named, so a caller
can report it the way ``validate`` does.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Iterator

import yaml

from nogg_bench.schema import Problem


class RecordError(Exception):
    """A file could not be read or parsed. ``problem`` names file and field."""

    def __init__(self, problem: Problem) -> None:
        super().__init__(str(problem))
        self.problem = problem


def load_yaml(path: Path) -> Any:
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise RecordError(Problem(str(path), "(file)", f"cannot read: {exc.strerror}")) from exc
    except yaml.YAMLError as exc:
        raise RecordError(Problem(str(path), "(file)", f"invalid YAML: {_first_line(exc)}")) from exc


def read_jsonl(path: Path) -> Iterator[tuple[int, Any]]:
    """Yield ``(line_number, parsed)`` for each non-blank line of a JSON Lines file."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RecordError(Problem(str(path), "(file)", f"cannot read: {exc.strerror}")) from exc
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            yield number, json.loads(line)
        except json.JSONDecodeError as exc:
            raise RecordError(Problem(f"{path}:{number}", "(line)", f"invalid JSON: {exc.msg}")) from exc


_FENCE = re.compile(r"^```[ \t]*(?:yaml|yml)[ \t]*\n(.*?)^```[ \t]*$", re.S | re.M)


def thresholds_block(markdown: str) -> tuple[Any, list[str]]:
    """Find the thresholds block in ``PREREGISTRATION.md`` text.

    Returns ``(data, errors)``. The block is the one fenced ``yaml`` block
    whose top level has a ``thresholds`` key; there must be exactly one.
    """
    return _keyed_block(markdown, "thresholds")


def selection_block(markdown: str) -> tuple[Any, list[str]]:
    """The same for the selection block: the one fenced ``yaml`` block whose
    top level has a ``selection`` key. ``data`` is ``{"selection": {...}}``."""
    return _keyed_block(markdown, "selection")


def _keyed_block(markdown: str, key: str) -> tuple[Any, list[str]]:
    found: list[Any] = []
    errors: list[str] = []
    for match in _FENCE.finditer(markdown):
        try:
            data = yaml.safe_load(match.group(1))
        except yaml.YAMLError as exc:
            errors.append(f"a fenced yaml block is not valid YAML: {_first_line(exc)}")
            continue
        if isinstance(data, dict) and key in data:
            found.append(data)
    if not found:
        errors.append(f"no fenced yaml block with a {key} key")
    elif len(found) > 1:
        errors.append(f"{len(found)} fenced yaml blocks have a {key} key; exactly one is allowed")
    return (found[0] if len(found) == 1 else None), errors


def load_selection(path: Path) -> dict | None:
    """The checked ``selection`` mapping of a preregistration file, None when the
    file has no selection block; an invalid block raises RecordError."""
    from nogg_bench.schema import check_selection

    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RecordError(Problem(str(path), "(file)", f"cannot read: {exc.strerror}")) from exc
    data, errors = selection_block(text)
    if data is None and errors == ["no fenced yaml block with a selection key"]:
        return None
    if errors:
        raise RecordError(Problem(str(path), "selection", errors[0]))
    problems = check_selection(data)
    if problems:
        raise RecordError(problems[0].at(str(path)))
    return data["selection"]


def load_thresholds(path: Path) -> dict:
    """Return the thresholds block of a preregistration file, or raise RecordError.

    The block is also schema-checked; a problem there raises with the first problem.
    """
    from nogg_bench.schema import check_thresholds

    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RecordError(Problem(str(path), "(file)", f"cannot read: {exc.strerror}")) from exc
    data, errors = thresholds_block(text)
    if errors:
        raise RecordError(Problem(str(path), "thresholds", errors[0]))
    problems = check_thresholds(data)
    if problems:
        raise RecordError(problems[0].at(str(path)))
    return data


def _first_line(exc: Exception) -> str:
    return str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__
