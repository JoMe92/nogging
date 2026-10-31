"""Pure loading, validation and prompt checks for Nogging loop definitions.

Loads the `loops_file` (default `.nogging/loops.json`), applies the scheduler
and per-loop defaults, and enforces the mode-specific, host, prompt and
secret rules. Raises `ValueError` naming the file, key, loop, line or rule —
never the matched secret text. No side effects: nothing here writes state,
and the approval hash is a pure SHA-256 over canonical JSON. Loaded beside
`scripts/nogg` like `session_backend` and shipped in bin/lib/manifest.js.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

from loop_schedule import parse_schedule

SCHEMA_VERSION = 1
LOOP_NAME_MAX = 40
PROMPT_MAX_BYTES = 16 * 1024
DEFAULT_MAX_RUNTIME = "1h"
MIN_RUNTIME_MINUTES = 5
MAX_RUNTIME_MINUTES = 12 * 60
SCHEDULER_DEFAULTS = {"max_active_launch_runs": 2, "suspend_after_failures": 3}

_TOP_KEYS = {"schema_version", "timezone", "scheduler", "loops"}
_SCHEDULER_KEYS = set(SCHEDULER_DEFAULTS)
_LOOP_KEYS = {"schedule", "run", "enabled", "host", "usage"}
_USAGE_KEYS = {"max_used_percent", "on_unknown"}
_SEND_KEYS = {"mode", "target", "max_runtime"}
_LAUNCH_KEYS = {"mode", "agent", "tier", "model", "effort", "authority", "max_runtime"}
_AUTHORITIES = ("restricted", "trusted")
_REFUSED_LAUNCH_VALUES = {
    "profile": ("orchestrator",),
    "prompt": ("autonomous", "orchestrator"),
}

_NAME_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
_RUNTIME_RE = re.compile(r"([0-9]+)([mh])\Z")
_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
_PEM_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
_TOKEN_RULES = (
    ("GitHub token", re.compile(r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}")),
    ("GitHub fine-grained token", re.compile(r"github_pat_[A-Za-z0-9_]{22,}")),
    ("Anthropic token", re.compile(r"sk-ant-")),
    ("OpenAI-style token", re.compile(r"sk-[A-Za-z0-9]{20,}")),
    ("AWS access key", re.compile(r"AKIA[A-Z0-9]{16}")),
    ("Slack token", re.compile(r"xox[abposr]-")),
)

# Mirrors of the session redactor's patterns in scripts/nogg: this module is
# shipped standalone, so it cannot import them, and the two must stay in step.
SECRET_NAME_RE = re.compile(
    r"TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|API_KEY|_KEY|CREDENTIAL|AUTH", re.I)
_SECRET_ASSIGN_RE = re.compile(
    r"([\w.-]*(?:TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|API_KEY|_KEY|CREDENTIAL|AUTH)[\w.-]*\s*=\s*)"
    r"(\"[^\"]*\"|'[^']*'|\S+)", re.I)


def secret_values():
    return [v for k, v in os.environ.items()
            if v and len(v) >= 4 and SECRET_NAME_RE.search(k)]


def _fail(message: str) -> ValueError:
    return ValueError(message)


def _key_fail(key: str, reason: str) -> ValueError:
    return _fail(f"{key}: {reason}")


def _loop_fail(name: str, key: str, reason: str) -> ValueError:
    return _fail(f"loop {name!r}: {key}: {reason}")


def _no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _fail(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _known_keys(value, allowed, where):
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise _key_fail(where, f"unknown key {unknown[0]!r}")
    return value


def _runtime_minutes(value, key):
    match = _RUNTIME_RE.fullmatch(value or "")
    if not match:
        raise _key_fail(key, "expected a string like 45m or 2h")
    minutes = int(match.group(1)) * (1 if match.group(2) == "m" else 60)
    if not MIN_RUNTIME_MINUTES <= minutes <= MAX_RUNTIME_MINUTES:
        raise _key_fail(key, f"must be between {MIN_RUNTIME_MINUTES} minutes and "
                             f"{MAX_RUNTIME_MINUTES // 60} hours")
    return minutes


def _load_run(name: str, run) -> dict:
    if not isinstance(run, dict):
        raise _loop_fail(name, "run", "expected an object")
    mode = run.get("mode")
    if mode == "send":
        _known_keys(run, _SEND_KEYS, f"loop {name!r} run")
        if run.get("target") != "orchestrator":
            raise _loop_fail(name, "target", "a send loop targets the orchestrator only")
        for key in ("agent", "tier", "authority"):
            if key in run:
                raise _loop_fail(name, key, "a send loop names no "
                                            f"{key} (it inherits the target's)")
    elif mode == "launch":
        _known_keys(run, _LAUNCH_KEYS, f"loop {name!r} run")
        for key in ("agent", "tier"):
            if not isinstance(run.get(key), str) or not run[key]:
                raise _loop_fail(name, key, "a launch loop requires an agent and a tier")
        authority = run.get("authority", "restricted")
        if authority not in _AUTHORITIES:
            raise _loop_fail(name, "authority",
                             f"must be one of {', '.join(_AUTHORITIES)}, got {authority!r}")
        for key, refused in _REFUSED_LAUNCH_VALUES.items():
            if run.get(key) is not None:
                raise _loop_fail(name, key,
                                 f"a loop run cannot select {run[key]!r}; a loop always "
                                 f"uses the loop prompt, the command floor and the "
                                 f"openspec/ fence")
    else:
        raise _loop_fail(name, "mode", 'must be "send" or "launch"')
    if "max_runtime" in run:
        _runtime_minutes(run["max_runtime"], f"loop {name!r} max_runtime")
    else:
        run = {**run, "max_runtime": DEFAULT_MAX_RUNTIME}
    if "authority" not in run and mode == "launch":
        run = {**run, "authority": "restricted"}
    return run


def _load_loop(name: str, loop, timezone: str) -> dict:
    if not isinstance(loop, dict):
        raise _loop_fail(name, "loop", "expected an object")
    _known_keys(loop, _LOOP_KEYS, f"loop {name!r}")
    if not isinstance(name, str) or len(name) > LOOP_NAME_MAX or not _NAME_RE.fullmatch(name):
        raise _fail(f"loop name {name!r}: must be kebab-case and at most "
                    f"{LOOP_NAME_MAX} characters")
    if "schedule" not in loop:
        raise _loop_fail(name, "schedule", "is required")
    try:
        parse_schedule({"timezone": timezone, **loop["schedule"]})
    except ValueError as exc:
        raise _loop_fail(name, "schedule", str(exc)) from exc
    if "run" not in loop:
        raise _loop_fail(name, "run", "is required")
    enabled = loop.get("enabled", True)
    if not isinstance(enabled, bool):
        raise _loop_fail(name, "enabled", "must be a boolean")
    host = loop.get("host")
    if host is not None and (not isinstance(host, str) or not host):
        raise _loop_fail(name, "host", "must be a non-empty string")
    usage = loop.get("usage")
    if usage is not None:
        if not isinstance(usage, dict):
            raise _loop_fail(name, "usage", "expected an object")
        _known_keys(usage, _USAGE_KEYS, f"loop {name!r} usage")
        if "max_used_percent" in usage:
            value = usage["max_used_percent"]
            if not isinstance(value, (int, float)) or isinstance(value, bool) \
                    or not 0 < value <= 100:
                raise _loop_fail(name, "usage.max_used_percent",
                                 "must be a percentage between 0 and 100")
    return {**loop, "enabled": enabled, "run": _load_run(name, loop["run"])}


def load(path) -> dict | None:
    """Load and validate a loop definitions file; None when it does not exist.

    Returns the parsed configuration with the scheduler defaults and the
    per-loop defaults (`enabled`, `authority`, `max_runtime`) applied.
    """
    path = Path(path)
    if not path.exists():
        return None
    try:
        raw = json.loads(path.read_text(encoding="utf-8"),
                         object_pairs_hook=_no_duplicate_keys)
    except json.JSONDecodeError as exc:
        raise _fail(f"{path}: invalid JSON: line {exc.lineno}: {exc.msg}") from exc
    except ValueError as exc:
        if "duplicate JSON key" in str(exc):
            raise _fail(f"{path}: {exc}") from exc
        raise
    if not isinstance(raw, dict):
        raise _fail(f"{path}: expected a JSON object")
    _known_keys(raw, _TOP_KEYS, str(path))
    if raw.get("schema_version") != SCHEMA_VERSION:
        raise _key_fail(f"{path}: schema_version",
                        f"expected {SCHEMA_VERSION}, got {raw.get('schema_version')!r}")
    timezone = raw.get("timezone")
    try:
        from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
        if not isinstance(timezone, str) or not timezone:
            raise _key_fail(f"{path}: timezone", "is required")
        ZoneInfo(timezone)
    except ZoneInfoNotFoundError as exc:
        raise _key_fail(f"{path}: timezone", f"not a valid IANA zone: {timezone!r}") from exc
    scheduler = raw.get("scheduler", {})
    if not isinstance(scheduler, dict):
        raise _key_fail(f"{path}: scheduler", "expected an object")
    _known_keys(scheduler, _SCHEDULER_KEYS, f"{path}: scheduler")
    scheduler = {**SCHEDULER_DEFAULTS, **scheduler}
    for key, value in scheduler.items():
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise _key_fail(f"{path}: scheduler.{key}", "must be a positive integer")
    loops = raw.get("loops", {})
    if not isinstance(loops, dict):
        raise _key_fail(f"{path}: loops", "expected an object")
    return {"schema_version": SCHEMA_VERSION, "timezone": timezone,
            "scheduler": scheduler,
            "loops": {name: _load_loop(name, loop, timezone)
                      for name, loop in loops.items()}}


def defs_dir(path) -> Path:
    """Directory holding the definitions file; prompts live in `loops/` there."""
    return Path(path).parent


def prompt_path(path, name) -> Path:
    """A loop's prompt file: `loops/<name>.md` beside the definitions file."""
    return defs_dir(path) / "loops" / f"{name}.md"


def check_prompt(path) -> None:
    """Enforce the prompt rules; a ValueError names file, line and rule and
    never the matched text."""
    path = Path(path)
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise _fail(f"{path}: cannot read prompt: {exc.strerror}") from exc
    if not data:
        raise _fail(f"{path}: prompt file is empty")
    if b"\0" in data:
        raise _fail(f"{path}: prompt contains a NUL byte")
    if len(data) > PROMPT_MAX_BYTES:
        raise _fail(f"{path}: prompt exceeds 16 KiB ({len(data)} bytes)")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise _fail(f"{path}: prompt is not valid UTF-8 (byte {exc.start})") from exc
    secrets = secret_values()
    for number, line in enumerate(text.splitlines(), start=1):
        if _EMAIL_RE.search(line):
            raise _fail(f"{path}: line {number}: email addresses are not allowed in prompts")
        for secret in secrets:
            if secret in line:
                raise _fail(f"{path}: line {number}: prompt carries a set secret-named "
                            "environment variable's value")
        if _SECRET_ASSIGN_RE.search(line):
            raise _fail(f"{path}: line {number}: secret assignment "
                        "(NAME=value with a secret-named key)")
        for rule, pattern in _TOKEN_RULES:
            if pattern.search(line):
                raise _fail(f"{path}: line {number}: prompt carries a {rule}")
        if _PEM_RE.search(line):
            raise _fail(f"{path}: line {number}: prompt carries a PEM private-key header")


def validate_hosts(config: dict, multi_machine: bool) -> None:
    """In multi-machine mode every enabled loop must name a host."""
    if not multi_machine:
        return
    for name, loop in config["loops"].items():
        if loop.get("enabled", True) and not loop.get("host"):
            raise _loop_fail(name, "host",
                             "is required for every enabled loop while "
                             "multi_machine is true")


def approval_hash(timezone: str, loop: dict, prompt: bytes) -> str:
    """SHA-256 over the canonical JSON of the timezone, loop and prompt bytes."""
    payload = {"timezone": timezone, "loop": loop, "prompt": list(prompt)}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
