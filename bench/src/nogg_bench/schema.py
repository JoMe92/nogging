"""Record schemas of the benchmark (design Decision 4).

Every record kind has one ``check_<kind>`` function. It takes the already
parsed data and returns a list of :class:`Problem`, empty when the record is
valid. Nothing here reads a file, so the later tasks (run, review-pack,
report) can validate a record they just built before they write it.

Each record carries ``schema: 1``. A task that needs a new field adds it
here, with a test, and never writes an unvalidated field.

Field paths in a problem use dots and list indexes: ``environment.image``,
``hidden_tests.fail_to_pass[2]``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any, Callable

SCHEMA_VERSION = 1

SIZE_CLASSES = ("small", "medium", "large")
CURATION_STATUSES = ("example", "candidate", "accepted")
ARM_KINDS = ("claude-code", "codex", "nogging")
RUN_STATUSES = ("completed", "timeout", "agent_error", "infra_error")
MERGE_DECISIONS = ("merge", "merge-after-changes", "reject")
DEFECT_SEVERITIES = ("critical", "major", "minor")
ACCEPTED_TICKET_DEFINITIONS = ("tests_pass", "tests_pass_and_review_merge")
THRESHOLD_METRICS = ("hidden_tests_passed", "cost_per_accepted_ticket")
THRESHOLD_REQUIREMENTS = ("not_worse", "lead_by")

_KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
_SHA = re.compile(r"^[0-9a-f]{40}$")
_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_ARM_ID = re.compile(r"^[A-Z]$")
_SOURCE = re.compile(r"^(bench|harbor:[A-Za-z0-9._-]+)$")
_URL = re.compile(r"^https?://\S+$")
_TOKEN_KEYS = ("input", "output", "cache_read", "cache_write")


@dataclass(frozen=True)
class Problem:
    """One problem: where it is (``file``), which field, and what is wrong."""

    file: str
    field: str
    message: str

    def __str__(self) -> str:
        return f"{self.file}: {self.field}: {self.message}"

    def at(self, file: str) -> "Problem":
        return Problem(file, self.field, self.message)


class _Checker:
    """Collects problems for one record; ``file`` is filled in by the caller."""

    def __init__(self, data: Any) -> None:
        self.problems: list[Problem] = []
        self.data = data

    def add(self, field: str, message: str) -> None:
        self.problems.append(Problem("", field, message))

    def get(self, obj: Any, path: str, key: str, *, required: bool = True) -> Any:
        """Return ``obj[key]``, or None after recording a missing-field problem."""
        full = f"{path}.{key}" if path else key
        if not isinstance(obj, dict) or key not in obj:
            if required:
                self.add(full, "missing required field")
            return None
        return obj[key]

    def mapping(self, obj: Any, path: str, key: str, *, required: bool = True) -> dict | None:
        value = self.get(obj, path, key, required=required)
        if value is None:
            if required and isinstance(obj, dict) and key in obj:
                self.add(f"{path}.{key}" if path else key, "must be a mapping")
            return None
        if not isinstance(value, dict):
            self.add(f"{path}.{key}" if path else key, "must be a mapping")
            return None
        return value

    def string(
        self,
        obj: Any,
        path: str,
        key: str,
        *,
        pattern: re.Pattern[str] | None = None,
        what: str = "",
        required: bool = True,
        allow_empty: bool = False,
    ) -> str | None:
        full = f"{path}.{key}" if path else key
        value = self.get(obj, path, key, required=required)
        if value is None:
            return None
        if not isinstance(value, str) or (not value.strip() and not allow_empty):
            self.add(full, "must be a non-empty string")
            return None
        if pattern is not None and not pattern.match(value):
            self.add(full, f"must be {what}" if what else "has the wrong format")
            return None
        return value

    def choice(self, obj: Any, path: str, key: str, options: tuple[str, ...], *, required: bool = True) -> str | None:
        full = f"{path}.{key}" if path else key
        value = self.get(obj, path, key, required=required)
        if value is None:
            return None
        if value not in options:
            self.add(full, f"must be one of {', '.join(options)} (got {value!r})")
            return None
        return value

    def integer(
        self, obj: Any, path: str, key: str, *, minimum: int = 0, required: bool = True
    ) -> int | None:
        full = f"{path}.{key}" if path else key
        value = self.get(obj, path, key, required=required)
        if value is None:
            return None
        if isinstance(value, bool) or not isinstance(value, int):
            self.add(full, "must be an integer")
            return None
        if value < minimum:
            self.add(full, f"must be at least {minimum}")
            return None
        return value

    def number(
        self, obj: Any, path: str, key: str, *, minimum: float = 0.0, exclusive: bool = False, required: bool = True
    ) -> float | None:
        full = f"{path}.{key}" if path else key
        value = self.get(obj, path, key, required=required)
        if value is None:
            return None
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            self.add(full, "must be a number")
            return None
        if value < minimum or (exclusive and value == minimum):
            self.add(full, f"must be {'above' if exclusive else 'at least'} {minimum}")
            return None
        return float(value)

    def boolean(self, obj: Any, path: str, key: str, *, required: bool = True) -> bool | None:
        full = f"{path}.{key}" if path else key
        value = self.get(obj, path, key, required=required)
        if value is None:
            return None
        if not isinstance(value, bool):
            self.add(full, "must be true or false")
            return None
        return value

    def timestamp(self, obj: Any, path: str, key: str, *, required: bool = True) -> datetime | date | None:
        full = f"{path}.{key}" if path else key
        value = self.get(obj, path, key, required=required)
        if value is None:
            return None
        parsed = _parse_time(value)
        if parsed is None:
            self.add(full, "must be an ISO 8601 date or timestamp")
        return parsed

    def string_list(
        self, obj: Any, path: str, key: str, *, non_empty: bool = False, required: bool = True
    ) -> list[str] | None:
        full = f"{path}.{key}" if path else key
        value = self.get(obj, path, key, required=required)
        if value is None:
            return None
        if not isinstance(value, list):
            self.add(full, "must be a list")
            return None
        if non_empty and not value:
            self.add(full, "must not be empty")
        out: list[str] = []
        for i, item in enumerate(value):
            if not isinstance(item, str) or not item.strip():
                self.add(f"{full}[{i}]", "must be a non-empty string")
            else:
                out.append(item)
        return out

    def schema_version(self) -> None:
        value = self.get(self.data, "", "schema") if isinstance(self.data, dict) else None
        if isinstance(self.data, dict) and "schema" in self.data and value != SCHEMA_VERSION:
            self.add("schema", f"must be {SCHEMA_VERSION} (got {value!r})")

    def unknown_keys(self, obj: Any, path: str, allowed: tuple[str, ...]) -> None:
        if not isinstance(obj, dict):
            return
        for key in obj:
            if key not in allowed:
                self.add(f"{path}.{key}" if path else str(key), "unknown field")


def _parse_time(value: Any) -> datetime | date | None:
    if isinstance(value, (datetime, date)):
        return value
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        pass
    try:
        return date.fromisoformat(value)
    except ValueError:
        return None


def _root(data: Any) -> _Checker:
    c = _Checker(data)
    if not isinstance(data, dict):
        c.add("(record)", "must be a mapping")
        return c
    c.schema_version()
    return c


def _finish(c: _Checker) -> list[Problem]:
    return c.problems


# --------------------------------------------------------------------- task

_TASK_KEYS = (
    "schema", "id", "repo", "base_commit", "language", "license", "issue", "issue_url",
    "fix_pr_url", "issue_closed_at", "size_class", "environment", "hidden_tests", "curation",
)


def check_task(data: Any, *, dir_name: str | None = None) -> list[Problem]:
    """Validate a ``task.yaml`` (Decision 5). ``dir_name`` is the task directory's name."""
    c = _root(data)
    if not isinstance(data, dict):
        return _finish(c)
    c.unknown_keys(data, "", _TASK_KEYS)
    task_id = c.string(data, "", "id", pattern=_KEBAB, what="a kebab-case id")
    if task_id and dir_name is not None and task_id != dir_name:
        c.add("id", f"must equal the directory name {dir_name!r} (got {task_id!r})")
    c.string(data, "", "repo")
    c.string(data, "", "base_commit", pattern=_SHA, what="a full 40-character commit SHA")
    c.string(data, "", "language")
    c.string(data, "", "license")
    issue = c.string(data, "", "issue")
    if issue and (issue.startswith("/") or ".." in issue.split("/")):
        c.add("issue", "must be a path inside the task directory")
    c.string(data, "", "issue_url", pattern=_URL, what="an http(s) URL")
    c.string(data, "", "fix_pr_url", pattern=_URL, what="an http(s) URL")
    c.timestamp(data, "", "issue_closed_at")
    c.choice(data, "", "size_class", SIZE_CLASSES)

    env = c.mapping(data, "", "environment")
    if env is not None:
        c.unknown_keys(env, "environment", ("image", "setup", "test_command", "test_timeout_seconds"))
        c.string(env, "environment", "image")
        c.string_list(env, "environment", "setup")
        command = c.string(env, "environment", "test_command")
        if command and "{tests}" not in command:
            c.add("environment.test_command", "must contain the {tests} placeholder")
        c.integer(env, "environment", "test_timeout_seconds", minimum=1)

    hidden = c.mapping(data, "", "hidden_tests")
    if hidden is not None:
        c.unknown_keys(hidden, "hidden_tests", ("patch", "fail_to_pass", "pass_to_pass"))
        patch = c.string(hidden, "hidden_tests", "patch")
        if patch and not patch.startswith("hidden/"):
            c.add("hidden_tests.patch", "must be a path under hidden/")
        elif patch and ".." in patch.split("/"):
            c.add("hidden_tests.patch", "must be a path under hidden/")
        f2p = c.string_list(hidden, "hidden_tests", "fail_to_pass", non_empty=True)
        p2p = c.string_list(hidden, "hidden_tests", "pass_to_pass")
        if f2p is not None and p2p is not None:
            for ident in sorted(set(f2p) & set(p2p)):
                c.add(
                    "hidden_tests.pass_to_pass",
                    f"test {ident!r} is in both fail_to_pass and pass_to_pass",
                )

    cur = c.mapping(data, "", "curation")
    if cur is not None:
        c.unknown_keys(cur, "curation", ("status", "hidden_tests_verified_by", "verified_on"))
        status = c.choice(cur, "curation", "status", CURATION_STATUSES)
        if status == "accepted":
            c.string(cur, "curation", "hidden_tests_verified_by")
            c.timestamp(cur, "curation", "verified_on")
    return _finish(c)


# ---------------------------------------------------------------------- arm

_ARM_KEYS = (
    "schema", "id", "label", "kind", "agent", "model", "effort", "timebox_minutes", "prompt",
    "disabled_tools", "credentials", "nogging_ref", "switches",
)


def check_arm(data: Any) -> list[Problem]:
    """Validate an arm file (Decision 6). Credentials are references only."""
    c = _root(data)
    if not isinstance(data, dict):
        return _finish(c)
    c.unknown_keys(data, "", _ARM_KEYS)
    c.string(data, "", "id", pattern=_ARM_ID, what="a single capital letter")
    c.string(data, "", "label")
    kind = c.choice(data, "", "kind", ARM_KINDS)
    agent = c.mapping(data, "", "agent")
    if agent is not None:
        c.unknown_keys(agent, "agent", ("cli", "version"))
        c.string(agent, "agent", "cli")
        c.string(agent, "agent", "version")
    c.string(data, "", "model")
    c.string(data, "", "effort")
    c.integer(data, "", "timebox_minutes", minimum=1)
    prompt = c.string(data, "", "prompt")
    if prompt and (prompt.startswith("/") or ".." in prompt.split("/")):
        c.add("prompt", "must be a path inside bench/arms/")
    c.string_list(data, "", "disabled_tools")

    creds = c.mapping(data, "", "credentials")
    if creds is not None:
        c.unknown_keys(creds, "credentials", ("env", "dir"))
        has_env, has_dir = "env" in creds, "dir" in creds
        if has_env == has_dir:
            c.add("credentials", "must name exactly one of env (variable name) or dir (credential directory)")
        if has_env:
            # A variable *name*: a pasted key (dashes, dots, spaces) is refused.
            c.string(creds, "credentials", "env", pattern=_ENV_NAME, what="an environment variable name, not a value")
        if has_dir:
            c.string(creds, "credentials", "dir")

    ref = data.get("nogging_ref")
    if kind == "nogging":
        c.string(data, "", "nogging_ref")
    elif ref is not None:
        c.add("nogging_ref", "is only allowed on a nogging arm")
    if "switches" in data:
        sw = data["switches"]
        if kind != "nogging":
            c.add("switches", "is only allowed on a nogging arm")
        elif not isinstance(sw, dict):
            c.add("switches", "must be a mapping")
        else:
            for k, v in sw.items():
                if not isinstance(k, str) or isinstance(v, (dict, list)) or v is None:
                    c.add(f"switches.{k}", "must be a string, number or boolean")
    return _finish(c)


# ------------------------------------------------------------- result line

_RESULT_KEYS = (
    "schema", "run_id", "batch", "arm", "task", "seed", "size_class", "source", "started_at",
    "ended_at", "wall_clock_seconds", "status", "reason", "passed", "tests",
    "hidden_paths_overwritten", "contamination_suspect", "diff_stats", "diff_path",
    "markdown_lines", "pr_count", "usage", "usage_collector", "provenance",
)
_PROVENANCE_KEYS = (
    "arm_file_hash", "prompt_hash", "agent_cli_version", "nogging_ref", "image_digest",
    "bench_commit", "preregistration_hash", "smoke",
)


def check_result(data: Any) -> list[Problem]:
    """Validate one result line (Decision 9).

    An ``infra_error`` line carries a ``reason`` and may leave the fields of a
    finished run empty (``tests`` empty, ``diff_stats``/``diff_path`` null,
    ``usage`` empty).
    """
    c = _root(data)
    if not isinstance(data, dict):
        return _finish(c)
    c.unknown_keys(data, "", _RESULT_KEYS)
    for key in ("run_id", "batch", "arm", "task"):
        c.string(data, "", key)
    c.integer(data, "", "seed", minimum=0)
    c.choice(data, "", "size_class", SIZE_CLASSES)
    c.string(data, "", "source", pattern=_SOURCE, what="'bench' or 'harbor:<dataset>'")
    start = c.timestamp(data, "", "started_at")
    end = c.timestamp(data, "", "ended_at")
    if isinstance(start, datetime) and isinstance(end, datetime):
        try:
            if end < start:
                c.add("ended_at", "is before started_at")
        except TypeError:  # one naive, one aware
            c.add("ended_at", "started_at and ended_at must both carry a time zone or both not")
    c.number(data, "", "wall_clock_seconds")

    status = c.choice(data, "", "status", RUN_STATUSES)
    passed = c.boolean(data, "", "passed")
    infra = status == "infra_error"
    if infra:
        c.string(data, "", "reason")
        if passed:
            c.add("passed", "must be false when status is infra_error")
    elif "reason" in data:
        c.string(data, "", "reason")

    tests = c.mapping(data, "", "tests")
    if tests is not None:
        c.unknown_keys(tests, "tests", ("fail_to_pass", "pass_to_pass"))
        results: dict[str, dict] = {}
        for group in ("fail_to_pass", "pass_to_pass"):
            group_map = c.mapping(tests, "tests", group)
            if group_map is None:
                continue
            results[group] = group_map
            for name, outcome in group_map.items():
                if not isinstance(outcome, bool):
                    c.add(f"tests.{group}.{name}", "must be true or false")
        if not infra and passed is not None and len(results) == 2:
            all_ok = all(v is True for g in results.values() for v in g.values())
            if not results["fail_to_pass"]:
                c.add("tests.fail_to_pass", "must not be empty unless status is infra_error")
            elif passed != all_ok:
                c.add("passed", "must be true exactly when every fail_to_pass and pass_to_pass test passed")

    c.string_list(data, "", "hidden_paths_overwritten")
    c.boolean(data, "", "contamination_suspect")

    diff_stats = data.get("diff_stats", "<absent>")
    diff_path = data.get("diff_path", "<absent>")
    if diff_stats == "<absent>":
        c.add("diff_stats", "missing required field")
    if diff_path == "<absent>":
        c.add("diff_path", "missing required field")
    if infra:
        pass
    else:
        if diff_stats is None:
            c.add("diff_stats", "must not be null unless status is infra_error")
        if diff_path is None:
            c.add("diff_path", "must not be null unless status is infra_error")
    if isinstance(diff_stats, dict):
        c.unknown_keys(diff_stats, "diff_stats", ("files_changed", "insertions", "deletions"))
        for key in ("files_changed", "insertions", "deletions"):
            c.integer(diff_stats, "diff_stats", key)
    elif diff_stats not in (None, "<absent>"):
        c.add("diff_stats", "must be a mapping or null")
    if diff_path not in (None, "<absent>") and not isinstance(diff_path, str):
        c.add("diff_path", "must be a string or null")
    c.integer(data, "", "markdown_lines")
    c.integer(data, "", "pr_count")

    usage = c.mapping(data, "", "usage")
    if usage is not None:
        if not usage and not infra:
            c.add("usage", "must name at least one model unless status is infra_error")
        for model, counts in usage.items():
            path = f"usage.{model}"
            if not isinstance(counts, dict):
                c.add(path, "must be a mapping of token counts")
                continue
            c.unknown_keys(counts, path, _TOKEN_KEYS)
            for key in _TOKEN_KEYS:
                c.integer(counts, path, key)
    collector = c.mapping(data, "", "usage_collector")
    if collector is not None:
        c.unknown_keys(collector, "usage_collector", ("helper_version", "nogging_commit"))
        c.string(collector, "usage_collector", "helper_version")
        c.string(collector, "usage_collector", "nogging_commit")

    prov = c.mapping(data, "", "provenance")
    if prov is not None:
        c.unknown_keys(prov, "provenance", _PROVENANCE_KEYS)
        for key in ("arm_file_hash", "prompt_hash", "agent_cli_version", "image_digest", "bench_commit"):
            c.string(prov, "provenance", key)
        if "nogging_ref" not in prov:
            c.add("provenance.nogging_ref", "missing required field (use null for a non-nogging arm)")
        elif prov["nogging_ref"] is not None and not (
            isinstance(prov["nogging_ref"], str) and prov["nogging_ref"].strip()
        ):
            c.add("provenance.nogging_ref", "must be a non-empty string or null")
        smoke = c.boolean(prov, "provenance", "smoke")
        prereg = prov.get("preregistration_hash", "<absent>")
        if prereg == "<absent>":
            c.add("provenance.preregistration_hash", "missing required field (use null for a smoke run)")
        elif prereg is None:
            if smoke is False:
                c.add("provenance.preregistration_hash", "must be set on a measured (non-smoke) run")
        elif not (isinstance(prereg, str) and _SHA.match(prereg)):
            c.add("provenance.preregistration_hash", "must be a 40-character git blob hash or null")
    return _finish(c)


# ------------------------------------------------------------ review record

_REVIEW_KEYS = (
    "schema", "pack", "item", "run_id", "merge_decision", "defects", "review_minutes",
    "comment", "reviewed_at",
)


def check_review(data: Any) -> list[Problem]:
    """Validate one review record (Decision 13). ``run_id`` is resolved from the key at import."""
    c = _root(data)
    if not isinstance(data, dict):
        return _finish(c)
    c.unknown_keys(data, "", _REVIEW_KEYS)
    for key in ("pack", "item", "run_id"):
        c.string(data, "", key)
    c.choice(data, "", "merge_decision", MERGE_DECISIONS)
    defects = c.mapping(data, "", "defects")
    if defects is not None:
        c.unknown_keys(defects, "defects", DEFECT_SEVERITIES)
        for sev in DEFECT_SEVERITIES:
            c.integer(defects, "defects", sev)
    c.number(data, "", "review_minutes", minimum=0.0, exclusive=True)
    c.string(data, "", "comment", allow_empty=True)
    c.timestamp(data, "", "reviewed_at")
    return _finish(c)


# --------------------------------------------------------- thresholds block

_THRESHOLDS_KEYS = (
    "schema", "primary_comparisons", "accepted_ticket", "thresholds", "minimum_effect",
    "significance_level", "reproducibility",
)


def _check_comparison(c: _Checker, obj: Any, path: str) -> tuple[str | None, str | None]:
    if not isinstance(obj, dict):
        c.add(path, "must be a mapping with treatment and control")
        return None, None
    c.unknown_keys(obj, path, ("treatment", "control"))
    t = c.string(obj, path, "treatment", pattern=_ARM_ID, what="an arm id")
    k = c.string(obj, path, "control", pattern=_ARM_ID, what="an arm id")
    if t and k and t == k:
        c.add(path, "treatment and control must be different arms")
    return t, k


def check_thresholds(data: Any) -> list[Problem]:
    """Validate the thresholds block of ``PREREGISTRATION.md`` (Decision 11).

    The block names the primary comparisons, the definition of an accepted
    ticket for the cost metric, the thresholds, the minimum effect, the
    significance level and the reproducibility criterion.
    """
    c = _root(data)
    if not isinstance(data, dict):
        return _finish(c)
    c.unknown_keys(data, "", _THRESHOLDS_KEYS)

    comparisons: set[tuple[str, str]] = set()
    raw = c.get(data, "", "primary_comparisons")
    if raw is not None:
        if not isinstance(raw, list) or not raw:
            c.add("primary_comparisons", "must be a non-empty list")
        else:
            for i, item in enumerate(raw):
                t, k = _check_comparison(c, item, f"primary_comparisons[{i}]")
                if t and k:
                    comparisons.add((t, k))

    c.choice(data, "", "accepted_ticket", ACCEPTED_TICKET_DEFINITIONS)

    raw = c.get(data, "", "thresholds")
    if raw is not None:
        if not isinstance(raw, list) or not raw:
            c.add("thresholds", "must be a non-empty list")
        else:
            seen: set[str] = set()
            for i, item in enumerate(raw):
                path = f"thresholds[{i}]"
                if not isinstance(item, dict):
                    c.add(path, "must be a mapping")
                    continue
                c.unknown_keys(item, path, ("id", "comparison", "metric", "size_class", "requirement", "margin"))
                tid = c.string(item, path, "id", pattern=_KEBAB, what="a kebab-case id")
                if tid:
                    if tid in seen:
                        c.add(f"{path}.id", f"duplicate threshold id {tid!r}")
                    seen.add(tid)
                cmp_raw = c.get(item, path, "comparison")
                if cmp_raw is not None:
                    t, k = _check_comparison(c, cmp_raw, f"{path}.comparison")
                    if t and k and comparisons and (t, k) not in comparisons:
                        c.add(f"{path}.comparison", f"{t} against {k} is not one of the primary_comparisons")
                metric = c.choice(item, path, "metric", THRESHOLD_METRICS)
                c.choice(item, path, "size_class", ("all",) + SIZE_CLASSES)
                req = c.choice(item, path, "requirement", THRESHOLD_REQUIREMENTS)
                if req == "lead_by":
                    c.number(item, path, "margin", minimum=0.0, exclusive=True)
                    if metric == "cost_per_accepted_ticket":
                        c.add(f"{path}.requirement", "lead_by is only defined for hidden_tests_passed (percentage points)")
                elif req == "not_worse" and "margin" in item:
                    c.add(f"{path}.margin", "is only allowed with requirement lead_by")

    effect = c.mapping(data, "", "minimum_effect")
    if effect is not None:
        c.unknown_keys(effect, "minimum_effect", ("pass_rate_points", "cost_ratio"))
        c.number(effect, "minimum_effect", "pass_rate_points", minimum=0.0)
        c.number(effect, "minimum_effect", "cost_ratio", minimum=0.0)

    level = c.number(data, "", "significance_level", minimum=0.0, exclusive=True)
    if level is not None and level >= 1.0:
        c.add("significance_level", "must be below 1")

    repro = c.mapping(data, "", "reproducibility")
    if repro is not None:
        c.unknown_keys(repro, "reproducibility", ("min_pass_agreement", "max_cost_ratio"))
        agree = c.number(repro, "reproducibility", "min_pass_agreement", minimum=0.0, exclusive=True)
        if agree is not None and agree > 1.0:
            c.add("reproducibility.min_pass_agreement", "must be at most 1")
        c.number(repro, "reproducibility", "max_cost_ratio", minimum=1.0)
    return _finish(c)


CHECKS: dict[str, Callable[..., list[Problem]]] = {
    "task": check_task,
    "arm": check_arm,
    "result": check_result,
    "review": check_review,
    "thresholds": check_thresholds,
}
