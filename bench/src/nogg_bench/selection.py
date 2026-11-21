"""The preregistration's ``selection`` block and the rules that follow from it.

Design Decisions 18 and 19: the curation commands (``candidates``, ``verify``,
``select``) take every number from the committed ``PREREGISTRATION.md`` and
never from a default in code. :func:`read_selection` flattens the block that
``records.load_selection`` reads and checks; the rest of this module is pure functions over
its result: the repository and issue criteria and the SHA-256 rank.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Iterable

from nogg_bench import prereg
from nogg_bench.records import RecordError, load_selection, load_yaml
from nogg_bench.schema import SIZE_CLASSES, Problem, check_exclusions

METHOD = "seeded-draw"
DRAW_FILE = "curation/selection.json"


class SelectionError(Exception):
    """The selection block is missing, uncommitted or incomplete; the message names the field."""


@dataclass(frozen=True)
class Selection:
    """The numbers of the checked selection block, flat, for the curation commands."""

    seed: int
    per_size_class: int
    pilot_per_size_class: int
    repositories: dict[str, int]  # lower-cased primary language -> how many repositories are taken
    latest_cutoff: date  # the latest training cutoff of the arm models
    licences: frozenset[str]
    last_commit_within_days: int
    min_merged_pull_requests: int
    merged_pull_requests_within_days: int
    min_stars: int
    max_stars: int
    exclusion_list: str  # path under the bench directory
    suite_time_limit_minutes: int
    linked_merged_pull_requests: int
    small_max_files: int
    medium_max_files: int
    large_min_lines: int
    runs_per_side: int

    @property
    def languages(self) -> tuple[str, ...]:
        return tuple(self.repositories)

    @property
    def suite_time_limit_seconds(self) -> int:
        return self.suite_time_limit_minutes * 60


def _day(value: Any, field: str) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        raise SelectionError(f"{field}: {value!r} is not a date") from None


def read_selection(path: Path) -> Selection:
    """The selection block of a preregistration file, read and checked by
    :func:`nogg_bench.records.load_selection` (the one reader); nothing has a default here."""
    try:
        block = load_selection(path)
    except RecordError as exc:
        raise SelectionError(f"{exc.problem.field}: {exc.problem.message}") from exc
    if block is None:
        raise SelectionError("selection: the preregistration has no selection block")
    repos, issues = block["criteria"]["repositories"], block["criteria"]["issues"]
    return Selection(
        seed=block["seed"],
        per_size_class=block["counts"]["per_size_class"],
        pilot_per_size_class=block["counts"]["pilot_per_size_class"],
        repositories={str(language).lower(): count for language, count in repos["languages"].items()},
        latest_cutoff=max(_day(e["cutoff"], "selection.training_cutoffs.cutoff") for e in block["training_cutoffs"]),
        licences=frozenset(repos["licences"]),
        exclusion_list=repos["exclusion_list"],
        runs_per_side=block["criteria"]["verification"]["runs_per_side"],
        **{key: repos[key] for key in (
            "last_commit_within_days", "min_merged_pull_requests", "merged_pull_requests_within_days",
            "min_stars", "max_stars", "suite_time_limit_minutes")},
        **issues,
    )


def committed_selection(bench: Path) -> tuple[Selection, str]:
    """The selection of the committed, unchanged preregistration and that file's blob hash."""
    blob, refusals = prereg.preregistration_hash(bench)
    if blob is None:
        raise SelectionError(refusals[0])
    return read_selection(bench / prereg.PREREGISTRATION), blob


def load_exclusions(path: Path) -> set[str]:
    """Lower-cased ``owner/name`` of every repository of the checked exclusion list
    (a renamed repository is listed under both names; names compare without regard to case)."""
    try:
        data = load_yaml(path)
    except RecordError as exc:
        raise SelectionError(f"exclusion list {path}: {exc.problem.message}") from exc
    problems = check_exclusions(data)
    if problems:
        raise SelectionError(f"exclusion list {path}: {problems[0].field}: {problems[0].message}")
    return {name.lower() for entry in data["lists"] for name in entry["repositories"]}


# ----------------------------------------------------------------- criteria


def repo_refusal(repo: dict, sel: Selection, excluded: set[str]) -> str | None:
    """Why a search result is not in the pool, by the criteria the search result itself answers."""
    language = str(repo.get("language") or "").lower()
    if language not in sel.languages:
        return f"primary language {repo.get('language')!r} is not one of {', '.join(sel.languages)}"
    spdx = (repo.get("license") or {}).get("spdx_id")
    if spdx not in sel.licences:
        return f"licence {spdx!r} is not a permissive licence of the preregistration"
    stars = repo.get("stargazers_count", -1)
    if not sel.min_stars <= stars <= sel.max_stars:
        return f"{stars} stars are outside {sel.min_stars} to {sel.max_stars}"
    if str(repo.get("full_name", "")).lower() in excluded:
        return "on the exclusion list of training sources"
    if repo.get("archived") or repo.get("fork"):
        return "archived or a fork"
    return None


def activity_refusal(last_commit: datetime, merged_prs: int, now: datetime, sel: Selection) -> str | None:
    """Why a repository is not actively maintained at ``now``."""
    if last_commit < now - timedelta(days=sel.last_commit_within_days):
        return f"last default-branch commit {last_commit.date()} is older than {sel.last_commit_within_days} days"
    if merged_prs < sel.min_merged_pull_requests:
        return (f"{merged_prs} merged pull requests in {sel.merged_pull_requests_within_days} days, "
                f"fewer than {sel.min_merged_pull_requests}")
    return None


def is_bot(login: str | None, kind: str | None) -> bool:
    """A bot account: GitHub says so (``Bot``) or the login ends in ``[bot]``. An author
    GitHub no longer names (a deleted account) cannot be shown to be a person and counts as one."""
    return kind == "Bot" or not login or login.lower().endswith("[bot]")


_TEST_DIRS = {"test", "tests", "testing", "__tests__", "spec", "specs", "e2e"}
_TEST_NAME = re.compile(r"^(test_.*\.py|.*_test\.py|conftest\.py|.*\.(test|spec)\.[cm]?[jt]sx?)$")


def is_test_file(path: str) -> bool:
    """A test file: under a test directory, or named as pytest, Jest or Vitest name test files."""
    parts = path.lower().split("/")
    return bool(_TEST_DIRS & set(parts[:-1])) or bool(_TEST_NAME.match(parts[-1]))


def size_class(files: int, changed_lines: int, sel: Selection) -> str:
    """The size class of a fix by its non-test changes (files, insertions plus deletions)."""
    if files > sel.medium_max_files or changed_lines >= sel.large_min_lines:
        return "large"
    return "small" if files <= sel.small_max_files else "medium"


_DIFF = re.compile(r"^(diff --git |@@ -\d+(,\d+)? \+\d+(,\d+)? @@|```+ *(diff|patch)\b|--- a/|\+\+\+ b/)", re.M)


def issue_text_refusal(text: str, fix_pr_url: str) -> str | None:
    """Why an issue text gives the fix away: it names the fix pull request or holds a diff."""
    if fix_pr_url.lower().removeprefix("https://") in text.lower():
        return "the issue text contains the fix pull request's URL"
    if _DIFF.search(text):
        return "the issue text contains a diff"
    return None


# --------------------------------------------------------------------- rank


def rank_key(seed: int, key: str) -> str:
    """The rank key of Decision 19: SHA-256 of ``"<seed>:<key>"`` in hex."""
    return hashlib.sha256(f"{seed}:{key}".encode("utf-8")).hexdigest()


def ranked(seed: int, keys: Iterable[str]) -> list[str]:
    return sorted(keys, key=lambda k: rank_key(seed, k))


def closed_after(task: dict, cutoff: date) -> bool:
    return _day(task.get("issue_closed_at"), "issue_closed_at") > cutoff


def draw_order(seed: int, tasks: Iterable[dict], cutoff: date) -> list[str]:
    """Task IDs in draw order: closed after ``cutoff`` first, each group in rank order."""
    tasks = list(tasks)
    post = [t["id"] for t in tasks if closed_after(t, cutoff)]
    pre = [t["id"] for t in tasks if not closed_after(t, cutoff)]
    return ranked(seed, post) + ranked(seed, pre)


# ------------------------------------------------- the draw record (select)


def drawn_tasks(path: Path) -> dict[str, bool]:
    """``{task id: pilot}`` of the tickets ``selection.json`` lists as drawn; empty when unreadable."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return {str(e["task"]): bool(e.get("pilot")) for entries in data["tickets"].values()
                for e in entries if e.get("drawn")}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def check_draw(data: Any) -> list[Problem]:
    """Validate ``curation/selection.json`` as ``select`` writes it."""
    if not isinstance(data, dict):
        return [Problem("", "(record)", "must be a mapping")]
    out: list[Problem] = []
    if data.get("schema") != 1:
        out.append(Problem("", "schema", f"must be 1 (got {data.get('schema')!r})"))
    if data.get("method") != METHOD:
        out.append(Problem("", "method", f"must be {METHOD}"))
    if isinstance(data.get("seed"), bool) or not isinstance(data.get("seed"), int):
        out.append(Problem("", "seed", "must be an integer"))
    for key in ("preregistration_hash", "pool_hash"):
        if not isinstance(data.get(key), str) or not data.get(key):
            out.append(Problem("", key, "must be a non-empty string"))
    tickets = data.get("tickets")
    if not isinstance(tickets, dict) or set(tickets) != set(SIZE_CLASSES):
        return out + [Problem("", "tickets", f"must list the classes {', '.join(SIZE_CLASSES)}")]
    for name, entries in tickets.items():
        ok = isinstance(entries, list) and all(isinstance(e, dict) and isinstance(e.get("task"), str) for e in entries)
        if not ok:
            out.append(Problem("", f"tickets.{name}", "must be a list of entries naming a task"))
        elif isinstance(data.get("seed"), int):
            keys = [(not e.get("post_cutoff"), rank_key(data["seed"], e["task"])) for e in entries]
            if keys != sorted(keys):
                out.append(Problem("", f"tickets.{name}", "is not in draw order for the seed"))
    return out
