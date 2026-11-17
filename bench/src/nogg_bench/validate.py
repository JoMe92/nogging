"""``nogg-bench validate``: check every record kind by its location.

Which kind a file is follows from where it lies:

| Path (relative to the bench directory)    | Kind        |
| ----------------------------------------- | ----------- |
| ``**/task.yaml``                          | task        |
| ``arms/<arm>.yaml``                       | arm         |
| ``results/<batch>.jsonl``                 | result line |
| ``results/review/<pack>.jsonl``           | review      |
| ``PREREGISTRATION.md``                    | thresholds  |

With no path, everything under the bench directory is checked except
``tests/`` (its fixtures include deliberately invalid records) and
``reports/``.
"""

from __future__ import annotations

from pathlib import Path
from typing import Iterable

from nogg_bench.records import RecordError, load_yaml, read_jsonl, thresholds_block
from nogg_bench.schema import (
    Problem,
    check_arm,
    check_result,
    check_review,
    check_task,
    check_thresholds,
)

SKIPPED_DIRS = {"tests", "reports", "__pycache__", ".venv", ".pytest_cache"}


def find_bench_dir(start: Path | None = None) -> Path:
    """The bench directory: the nearest ancestor of ``start`` holding ``pyproject.toml``
    with the nogg-bench package, else the checkout this package was loaded from."""
    here = (start or Path.cwd()).resolve()
    for base in (here, *here.parents):
        for candidate in (base, base / "bench"):
            if (candidate / "pyproject.toml").is_file() and (candidate / "src" / "nogg_bench").is_dir():
                return candidate
    return Path(__file__).resolve().parents[2]


def kind_of(path: Path, bench: Path) -> str | None:
    """The record kind of ``path`` from its location, or None when it is not a record."""
    try:
        rel = path.resolve().relative_to(bench.resolve())
    except ValueError:
        rel = Path(path.name)
    parts = rel.parts
    if path.name == "task.yaml":
        return "task"
    if path.name == "PREREGISTRATION.md":
        return "thresholds"
    if path.suffix in (".yaml", ".yml") and len(parts) >= 2 and parts[-2] == "arms":
        return "arm"
    if path.suffix == ".jsonl":
        if len(parts) >= 2 and parts[-2] == "review":
            return "review"
        if len(parts) >= 2 and parts[-2] == "results":
            return "result"
    return None


def discover(bench: Path) -> list[Path]:
    """Every record file under ``bench`` (see the module docstring)."""
    out: list[Path] = []
    for path in sorted(bench.rglob("*")):
        if not path.is_file():
            continue
        if SKIPPED_DIRS & set(path.relative_to(bench).parts[:-1]):
            continue
        if kind_of(path, bench):
            out.append(path)
    return out


def expand(paths: Iterable[Path], bench: Path) -> tuple[list[Path], list[Problem]]:
    """Turn the command-line paths (files or directories) into record files."""
    files: list[Path] = []
    problems: list[Problem] = []
    for given in paths:
        if given.is_dir():
            found = sorted(p for p in given.rglob("*") if p.is_file() and kind_of(p, bench))
            if not found:
                problems.append(Problem(str(given), "(path)", "contains no benchmark record"))
            files.extend(found)
        elif given.is_file():
            if kind_of(given, bench):
                files.append(given)
            else:
                problems.append(Problem(str(given), "(path)", "is not a benchmark record by its location"))
        else:
            problems.append(Problem(str(given), "(path)", "does not exist"))
    return files, problems


def validate_file(path: Path, bench: Path) -> list[Problem]:
    """All problems of one record file, each naming ``path`` (and the line for JSON Lines)."""
    kind = kind_of(path, bench)
    name = str(path)
    try:
        if kind == "task":
            return _task_problems(path, name)
        if kind == "arm":
            return _arm_problems(path, name)
        if kind in ("result", "review"):
            check = check_result if kind == "result" else check_review
            out: list[Problem] = []
            for number, record in read_jsonl(path):
                out += [p.at(f"{name}:{number}") for p in check(record)]
            return out
        if kind == "thresholds":
            data, errors = thresholds_block(path.read_text(encoding="utf-8"))
            if errors:
                return [Problem(name, "thresholds", e) for e in errors]
            return [p.at(name) for p in check_thresholds(data)]
    except RecordError as exc:
        return [exc.problem]
    except OSError as exc:
        return [Problem(name, "(file)", f"cannot read: {exc.strerror}")]
    return [Problem(name, "(path)", "is not a benchmark record by its location")]


def _task_problems(path: Path, name: str) -> list[Problem]:
    data = load_yaml(path)
    problems = [p.at(name) for p in check_task(data, dir_name=path.parent.name)]
    if isinstance(data, dict):
        # The files the task points to must exist next to it.
        issue = data.get("issue")
        if isinstance(issue, str) and not problems_for(problems, "issue") and not (path.parent / issue).is_file():
            problems.append(Problem(name, "issue", f"file {issue} does not exist"))
        hidden = data.get("hidden_tests")
        patch = hidden.get("patch") if isinstance(hidden, dict) else None
        if isinstance(patch, str) and not problems_for(problems, "hidden_tests.patch") and not (path.parent / patch).is_file():
            problems.append(Problem(name, "hidden_tests.patch", f"file {patch} does not exist"))
    return problems


def _arm_problems(path: Path, name: str) -> list[Problem]:
    data = load_yaml(path)
    problems = [p.at(name) for p in check_arm(data)]
    if isinstance(data, dict):
        prompt = data.get("prompt")
        if isinstance(prompt, str) and not problems_for(problems, "prompt") and not (path.parent / prompt).is_file():
            problems.append(Problem(name, "prompt", f"file {prompt} does not exist next to the arm file"))
        arm_id = data.get("id")
        if isinstance(arm_id, str) and not problems_for(problems, "id") and path.stem != arm_id:
            problems.append(Problem(name, "id", f"must equal the file name {path.stem!r} (got {arm_id!r})"))
    return problems


def problems_for(problems: list[Problem], field: str) -> bool:
    return any(p.field == field or p.field.startswith(field + ".") for p in problems)


def validate(paths: list[Path], bench: Path) -> list[Problem]:
    """Validate ``paths`` (files or directories), or all of ``bench`` when empty."""
    if paths:
        files, problems = expand(paths, bench)
    else:
        files, problems = discover(bench), []
    for path in files:
        problems += validate_file(path, bench)
    return problems
