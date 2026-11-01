"""The pure half of `nogg test`: the `testing` block, what a stage runs, over which
files, and whether it may run at all. No subprocess, no clock and no state here:
scripts/nogg passes every fact in, so each table of the design is a small test.

The file is `testing_stages.py`, never `test_stages.py`: TEST_PATH_RE would read
that name as a test, and its lines would vanish from the production count.
"""
from __future__ import annotations

import copy
import math
import os
import re
import shlex
from pathlib import Path

from token_usage_report import TEST_PATH_RE

STAGES = ("changed", "commit", "bead", "full")
DEFAULTS = {
    "stages": {},
    "budgets": {"changed": 300, "commit": 600, "bead": 1800, "full": 7200},
    "max_parallel_heavy": 2,
    "heavy_stages": ["bead", "full"],
    "slot_wait_seconds": 3600,
    "full_lock": "auto",
    "integrity": "report",
    "trend_threshold_percent": 30,
    "ci": {"branch": "develop", "job_pattern": "test", "max_age_days": 7, "cache_seconds": 21600},
    "nightly": {"enabled": True, "setup": []},
}
BRANCH_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]*")
LIST_PLACEHOLDERS = ("{files}", "{test_files}")
# What `scripts/test --only` can run; any other test path is only reported by it.
RUNNABLE_RE = re.compile(r"(\.test\.sh|_test\.py)$")
NIGHTLY_IN_USE_SECONDS = 3 * 86400
FULL_REFUSED_RELEASE = "refused: --release is for an operator shell or the Orchestration Agent, not a {role} session"
FULL_REFUSED_NIGHTLY = "refused: --nightly runs outside any supervised session; this is a {role} session"
FULL_REFUSED_REASON = 'refused: --allow-full needs a non-empty reason, e.g. --allow-full "migration touches every test"'
FULL_REFUSED_LOCK = ("refused: `nogg test full` is locked here ({why}). Run `nogg test bead` for your change and "
                     'leave the full suite to CI, or pass --allow-full "<reason>" for a recorded exception, or '
                     "--release from an operator shell or the Orchestration Agent. testing.full_lock sets the lock.")


def _is_int(value, minimum):
    return type(value) is int and value >= minimum


def _is_number(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def stage_problem(value):
    """Why a `testing.stages.<stage>` value cannot run, or None. Commands are
    checked here so a bad string is a WARN and the default, never a crash."""
    commands = [value] if isinstance(value, str) else value
    if not isinstance(commands, list) or not commands:
        return "must be a command string or a non-empty list of them"
    for command in commands:
        if not isinstance(command, str):
            return "must be a command string or a non-empty list of them"
        try:
            words = shlex.split(command)
        except ValueError as exc:
            return f"cannot be split into arguments ({exc})"
        if not words:
            return "holds an empty command"
        for word in words:
            if word not in LIST_PLACEHOLDERS and any(p in word for p in LIST_PLACEHOLDERS):
                return f"uses a list placeholder inside the word {word!r}; it must stand alone"
    return None


def _parse_stages(raw, problems):
    stages = {}
    if not isinstance(raw, dict):
        problems.append("testing.stages must be an object; using the defaults")
        return stages
    for key, value in raw.items():
        if key not in STAGES:
            problems.append(f"testing.stages.{key} is not a known stage; ignored")
            continue
        problem = stage_problem(value)
        if problem:
            problems.append(f"testing.stages.{key} {problem}; using the default")
        else:
            stages[key] = list(value) if isinstance(value, list) else value
    return stages


def _parse_budgets(raw, problems):
    budgets = dict(DEFAULTS["budgets"])
    if not isinstance(raw, dict):
        problems.append("testing.budgets must be an object; using the defaults")
        return budgets
    for key, value in raw.items():
        if key not in STAGES:
            problems.append(f"testing.budgets.{key} is not a known stage; ignored")
        elif not _is_number(value):
            problems.append(f"testing.budgets.{key} must be a positive number of seconds; "
                            f"using the default {DEFAULTS['budgets'][key]}")
        else:
            budgets[key] = value
    return budgets


def _parse_heavy(value, problems):
    if isinstance(value, list) and all(isinstance(s, str) and s in STAGES for s in value):
        return list(dict.fromkeys(value))
    problems.append("testing.heavy_stages must be a list of stage names; "
                    f"using the default {DEFAULTS['heavy_stages']}")
    return list(DEFAULTS["heavy_stages"])


def _job_pattern_ok(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        re.compile(value)
    except re.error:
        return False
    return True


def _parse_ci(raw, problems):
    ci = dict(DEFAULTS["ci"])
    if not isinstance(raw, dict):
        problems.append("testing.ci must be an object; using the defaults")
        return ci
    checks = {
        "branch": (lambda v: isinstance(v, str) and BRANCH_RE.fullmatch(v) is not None, "a branch name"),
        "job_pattern": (_job_pattern_ok, "a valid regular expression"),
        "max_age_days": (lambda v: _is_int(v, 1), "a positive integer"),
        "cache_seconds": (lambda v: _is_int(v, 0), "a non-negative integer"),
    }
    for key, value in raw.items():
        if key not in checks:
            problems.append(f"testing.ci.{key} is not a known key; ignored")
        elif not checks[key][0](value):
            problems.append(f"testing.ci.{key} must be {checks[key][1]}; using the default {ci[key]!r}")
        else:
            ci[key] = value
    return ci


def _parse_nightly(raw, problems):
    nightly = copy.deepcopy(DEFAULTS["nightly"])
    if not isinstance(raw, dict):
        problems.append("testing.nightly must be an object; using the defaults")
        return nightly
    for key, value in raw.items():
        if key == "enabled":
            if isinstance(value, bool):
                nightly["enabled"] = value
            else:
                problems.append("testing.nightly.enabled must be true or false; using the default true")
        elif key == "setup":
            setup = [value] if isinstance(value, str) else value
            problem = None if setup == [] else stage_problem(setup)
            if problem:
                problems.append(f"testing.nightly.setup {problem}; using the default []")
            else:
                nightly["setup"] = list(setup)
        else:
            problems.append(f"testing.nightly.{key} is not a known key; ignored")
    return nightly


def parse_testing(raw):
    """(settings, problems) for the raw `testing` value, None when the key is
    absent. Every key is optional and a malformed one keeps its default, so this
    never raises: a problem is a `doctor` WARN, never a failed command. It reads
    the whole block, including the keys later commands consume."""
    settings, problems = copy.deepcopy(DEFAULTS), []
    if raw is None:
        return settings, problems
    if not isinstance(raw, dict):
        return settings, ["testing in .nogging/config.json must be an object; using the defaults"]
    scalar = {
        "max_parallel_heavy": (lambda v: _is_int(v, 1), "a positive integer"),
        "slot_wait_seconds": (lambda v: _is_int(v, 0), "a non-negative integer"),
        "full_lock": (lambda v: v in ("auto", "always", "never"), "auto, always or never"),
        "integrity": (lambda v: v in ("report", "enforce"), "report or enforce"),
        "trend_threshold_percent": (_is_number, "a positive number"),
    }
    for key, value in raw.items():
        if key == "stages":
            settings["stages"] = _parse_stages(value, problems)
        elif key == "budgets":
            settings["budgets"] = _parse_budgets(value, problems)
        elif key == "heavy_stages":
            settings["heavy_stages"] = _parse_heavy(value, problems)
        elif key == "ci":
            settings["ci"] = _parse_ci(value, problems)
        elif key == "nightly":
            settings["nightly"] = _parse_nightly(value, problems)
        elif key not in scalar:
            problems.append(f"testing.{key} is not a known key; ignored")
        elif not isinstance(value, (str, int, float)) or not scalar[key][0](value):
            problems.append(f"testing.{key} must be {scalar[key][1]}; using the default {DEFAULTS[key]!r}")
        else:
            settings[key] = value
    return settings, problems


def stage_commands(stage, settings, test_changed=False, ci_configured=False):
    """The command strings of `stage`, configured or by fallback. `bead` falls
    back to the whole `scripts/test` only where no CI will run it."""
    configured = settings["stages"].get(stage)
    if configured is not None:
        return [configured] if isinstance(configured, str) else list(configured)
    if stage == "full":
        return ["scripts/test --timings {timings}"]
    if stage == "bead" and not ci_configured:
        return ["scripts/test"]
    return ["scripts/test-changed {files}" if test_changed else "scripts/test --only {test_files}"]


def change_set(paths, exists=os.path.lexists):
    """(files, test_files), sorted and unique. A deleted path is left out, since
    no runner can open it. TEST_PATH_RE decides what counts as a test."""
    files = sorted({path for path in paths if exists(path)})
    return files, [path for path in files if TEST_PATH_RE.search(path)]


def _runs_only(argv):
    """True for `scripts/test --only ...`, which reports a path it cannot run."""
    return bool(argv) and os.path.normpath(argv[0]) == "scripts/test" and "--only" in argv


def expand_command(command, files, test_files, junit, timings):
    """(argv, skip_reason): argv is None when a list placeholder has nothing to
    hold. Paths gain `./`, so a file named `-rf.test.sh` cannot be an option. The
    result paths may sit inside a word (`--junitxml={junit}`)."""
    argv = []
    for word in shlex.split(command):
        if word not in LIST_PLACEHOLDERS:
            argv.append(word.replace("{junit}", junit).replace("{timings}", timings))
            continue
        chosen = files if word == "{files}" else test_files
        if _runs_only(argv):
            chosen = [path for path in chosen if RUNNABLE_RE.search(path)]
            if not chosen:
                return None, "no runnable test file changed"
        elif not chosen:
            return None, "no changed files" if word == "{files}" else "no changed test files"
        argv.extend(f"./{path}" for path in chosen)
    return argv, None


def plan_stage(commands, files, test_files, result_paths):
    """(steps, skip_reason). A step is `{"argv", "junit", "timings"}`; a command
    with nothing to hold is left out, and `skip_reason` names why when none is
    left. `result_paths(index)` gives the fresh pair of a command's result paths."""
    steps, reason = [], None
    for index, command in enumerate(commands):
        junit, timings = result_paths(index)
        argv, skipped = expand_command(command, files, test_files, junit, timings)
        if argv is None:
            reason = reason or skipped
        else:
            steps.append({"argv": argv, "junit": junit, "timings": timings})
    return steps, None if steps else (reason or "no commands")


def skip_line(stage, reason):
    return f"skipped: {stage} ran no tests ({reason})"


def over_budget(seconds, budget):
    return seconds > budget


def budget_line(stage, seconds, budget):
    """The report of a run above its budget. Rounded up, so a run just over its
    budget never reads as equal to it."""
    return (f"over budget: {stage} took {math.ceil(seconds)} s, budget {budget} s "
            f"(testing.budgets.{stage})")


def ci_files(root):
    """The CI configuration files under `root`. A static check on purpose: it
    needs no network, and `doctor` reports a workflow that runs no test."""
    root = Path(root)
    found = [path for pattern in ("*.yml", "*.yaml") for path in sorted((root / ".github/workflows").glob(pattern))]
    found += [root / name for name in (".gitlab-ci.yml", ".circleci/config.yml", "Jenkinsfile")]
    return [path.relative_to(root).as_posix() for path in found if path.is_file()]


def nightly_in_use(last_at, now_seconds):
    """True when the last nightly record (epoch seconds, or None) is at most 3 days old."""
    return last_at is not None and 0 <= now_seconds - last_at <= NIGHTLY_IN_USE_SECONDS


def full_lock_active(mode, ci_configured, nightly_recent):
    if mode == "always":
        return True
    if mode == "never":
        return False
    return bool(ci_configured or nightly_recent)


def _lock_reason(mode, ci_configured):
    if mode == "always":
        return "testing.full_lock is always"
    return "CI is configured" if ci_configured else "the nightly run is in use"


def full_decision(settings, ci_configured, nightly_recent, *, release=False, nightly=False,
                  allow_full=None, role=None, supervised=False):
    """`{"allowed", "trigger", "reason", "message"}` for `nogg test full`. A
    trigger the caller may not use refuses even when the lock is inactive, so a
    false claim never reaches the record as that trigger."""
    def refuse(message):
        return {"allowed": False, "trigger": "none", "reason": None, "message": message}
    if release and supervised and role != "orchestrator":
        return refuse(FULL_REFUSED_RELEASE.format(role=role or "supervised"))
    if nightly and supervised:
        return refuse(FULL_REFUSED_NIGHTLY.format(role=role or "supervised"))
    if allow_full is not None and not allow_full.strip():
        return refuse(FULL_REFUSED_REASON)
    if release:
        return {"allowed": True, "trigger": "release", "reason": None, "message": None}
    if nightly:
        return {"allowed": True, "trigger": "nightly", "reason": None, "message": None}
    if allow_full is not None:
        return {"allowed": True, "trigger": "allow-full", "reason": allow_full.strip(), "message": None}
    mode = settings["full_lock"]
    if full_lock_active(mode, ci_configured, nightly_recent):
        return refuse(FULL_REFUSED_LOCK.format(why=_lock_reason(mode, ci_configured)))
    return {"allowed": True, "trigger": "unlocked", "reason": None, "message": None}
