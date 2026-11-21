"""The preregistration's ``selection`` block and the rules that follow from it.

Design Decisions 18 and 19: the curation commands (``candidates``, ``verify``,
``select``) take every number from the committed ``PREREGISTRATION.md`` and
never from a default in code. :func:`read_selection` is the one place that
knows the block's key names; the rest of this module is pure functions over
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

import yaml

from nogg_bench import prereg
from nogg_bench.records import _FENCE
from nogg_bench.schema import SIZE_CLASSES, Problem

METHOD = "seeded-draw"
DRAW_FILE = "curation/selection.json"


class SelectionError(Exception):
    """The selection block is missing, uncommitted or incomplete; the message names the field."""


@dataclass(frozen=True)
class Selection:
    seed: int
    per_size_class: int
    pilot_per_size_class: int
    repositories: dict[str, int]  # language -> how many repositories are taken
    latest_cutoff: date  # the latest training cutoff of the arm models
    licenses: frozenset[str]
    last_commit_within_days: int
    min_merged_pull_requests: int
    merged_pull_requests_within_days: int
    min_stars: int
    max_stars: int
    exclusion_list: str  # path under the bench directory
    suite_time_limit_seconds: int
    small_max_files: int
    medium_max_files: int
    large_min_changed_lines: int

    @property
    def languages(self) -> tuple[str, ...]:
        return tuple(self.repositories)


def selection_block(markdown: str) -> Any:
    """The ``selection`` mapping of a preregistration text, or None when there is none."""
    for match in _FENCE.finditer(markdown):
        try:
            data = yaml.safe_load(match.group(1))
        except yaml.YAMLError:
            continue
        if isinstance(data, dict) and "selection" in data:
            return data["selection"]
    return None


def _need(obj: Any, path: str, key: str, kind: type) -> Any:
    value = obj.get(key) if isinstance(obj, dict) else None
    if isinstance(value, bool) or not isinstance(value, kind):
        raise SelectionError(f"selection.{path}{key}: missing or not {kind.__name__} in the preregistration")
    return value


def _day(value: Any, field: str) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        raise SelectionError(f"{field}: {value!r} is not a date") from None


def read_selection(markdown: str) -> Selection:
    """Read the selection block. Every key is required; nothing has a default here."""
    block = selection_block(markdown)
    if not isinstance(block, dict):
        raise SelectionError("selection: the preregistration has no selection block")
    if block.get("method") != METHOD:
        raise SelectionError(f"selection.method: must be {METHOD} (got {block.get('method')!r})")
    counts = _need(block, "", "counts", dict)
    repositories = _need(counts, "counts.", "repositories", dict)
    cutoffs = block.get("training_cutoffs")
    entries = list(cutoffs.values()) if isinstance(cutoffs, dict) else cutoffs
    if not isinstance(entries, list) or not entries or not all(isinstance(e, dict) and "cutoff" in e for e in entries):
        raise SelectionError("selection.training_cutoffs: needs one entry with a cutoff per arm model")
    crit = _need(block, "", "criteria", dict)
    c = "criteria."
    return Selection(
        seed=_need(block, "", "seed", int),
        per_size_class=_need(counts, "counts.", "per_size_class", int),
        pilot_per_size_class=_need(counts, "counts.", "pilot_per_size_class", int),
        repositories={str(k).lower(): _need(repositories, "counts.repositories.", k, int) for k in repositories},
        latest_cutoff=max(_day(e["cutoff"], "selection.training_cutoffs.cutoff") for e in entries),
        licenses=frozenset(str(x) for x in _need(crit, c, "licenses", list)),
        last_commit_within_days=_need(crit, c, "last_commit_within_days", int),
        min_merged_pull_requests=_need(crit, c, "min_merged_pull_requests", int),
        merged_pull_requests_within_days=_need(crit, c, "merged_pull_requests_within_days", int),
        min_stars=_need(crit, c, "min_stars", int),
        max_stars=_need(crit, c, "max_stars", int),
        exclusion_list=_need(crit, c, "exclusion_list", str),
        suite_time_limit_seconds=_need(crit, c, "suite_time_limit_seconds", int),
        small_max_files=_need(crit, c, "small_max_files", int),
        medium_max_files=_need(crit, c, "medium_max_files", int),
        large_min_changed_lines=_need(crit, c, "large_min_changed_lines", int),
    )


def committed_selection(bench: Path) -> tuple[Selection, str]:
    """The selection of the committed, unchanged preregistration and that file's blob hash."""
    blob, refusals = prereg.preregistration_hash(bench)
    if blob is None:
        raise SelectionError(refusals[0])
    return read_selection((bench / prereg.PREREGISTRATION).read_text(encoding="utf-8")), blob


def load_exclusions(path: Path) -> set[str]:
    """Lower-cased ``owner/name`` of every repository under a ``repositories`` key of the list file."""
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise SelectionError(f"exclusion list {path}: cannot read ({type(exc).__name__})") from exc
    out: set[str] = set()

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "repositories" and isinstance(value, list):
                    out.update(str(v).lower() for v in value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(data)
    if not out:
        raise SelectionError(f"exclusion list {path}: names no repository")
    return out


# ----------------------------------------------------------------- criteria


def repo_refusal(repo: dict, sel: Selection, excluded: set[str]) -> str | None:
    """Why a search result is not in the pool, by the criteria the search result itself answers."""
    language = str(repo.get("language") or "").lower()
    if language not in sel.languages:
        return f"primary language {repo.get('language')!r} is not one of {', '.join(sel.languages)}"
    spdx = (repo.get("license") or {}).get("spdx_id")
    if spdx not in sel.licenses:
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
    if files > sel.medium_max_files or changed_lines >= sel.large_min_changed_lines:
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
