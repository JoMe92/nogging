"""The pure half of `nogg session dispatch`: one level-triggered decision per pass.

No I/O, no clock and no model: callers inject the gathered facts, the remembered
state, the policy and the time, and `decide` returns the actions. See
openspec/changes/session-wake, design Decisions 6, 7 and 13.

A fact is one session's evidence, and a missing or None value means `unknown`, on
which no action may depend:

    session, role, agent, bead, state   `state` is a classified state, or `gone`
    nudgeable       a kicked-off autonomous Lead on a guarded runtime
    head, gaps      the checkout's HEAD and `completion_gaps`, None when unreadable
    bead_status, sweep                  the Bead and `_sweep_state`
    checks          the `_observe_checks` observation
    signal          {"kind", "reason", "at"}
    turn_error      {"at", "error"} when the last turn ended in a non-limit error
    turn, excerpt   the last event's timestamp and its excerpt
    pane_excerpt, switch_prompt, limit_until, limit_source   from the pane
    silent_seconds  age of the session log
    kicked_off, started_at, exit_reason, superseded, worktree_record
"""
from __future__ import annotations

import copy
import re
from datetime import datetime, timezone
from typing import Any

SETTLE_SECONDS = 60
NEEDS_INPUT_SECONDS = 120
CHECKS_INTERVAL_SECONDS = 120
BEADS_CACHE_SECONDS = 300
FAILED_CHECKS_SHOWN = 5
DONE_KEYS_KEPT = 64
EXCERPT_LINES = 6

# Retrying these cannot help, so they skip the retry nudge.
PERMANENT_ERRORS = frozenset({"authentication_failed", "billing_error", "invalid_request"})
# What a host-wide hold stops. Items and retirement go on (TASK-SWK-009).
SENDS = frozenset({"nudge", "resume"})

GAP_WORDS = {"dirty": "uncommitted changes", "unpushed": "unpushed commits"}
BLOCK_HINT = "If you cannot, run `./scripts/nogg session signal blocked \"<why>\"` and stop."
NUDGE_GAPS = "Nogging dispatcher: you are idle with {gaps}. Commit, push and open the pull request now. " + BLOCK_HINT
NUDGE_NO_PR = ("Nogging dispatcher: you are idle with a clean tree, no pull request and no signal. "
               "Open the pull request now. " + BLOCK_HINT)
NUDGE_CI = ("Nogging dispatcher: CI is failing on PR #{pr}: {checks}. Repair it in this worktree and push. "
            + BLOCK_HINT)
NUDGE_RETRY = "Nogging dispatcher: your last turn ended in an error. Continue exactly where you left off."
NUDGE_STALL = ("Nogging dispatcher: your session log has been silent for {minutes} minutes. Continue. "
               + BLOCK_HINT)

_CHECK_NAME_DROP = re.compile(r"[^\w .:/()+-]+")
_DURATION = re.compile(r"^(\d+)([smh]?)$")
_UNITS = {"": 1, "s": 1, "m": 60, "h": 3600}
_QUIET_WINDOW = re.compile(r"^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$")


def seconds(value: Any) -> int:
    """`90`, `90s`, `15m` or `4h` as seconds; ValueError otherwise."""
    match = _DURATION.match(str(value).strip()) if not isinstance(value, bool) else None
    if match is None:
        raise ValueError(f"not a duration: {value!r}")
    return int(match.group(1)) * _UNITS[match.group(2)]


def _is_duration(value: Any) -> bool:
    try:
        return seconds(value) > 0
    except ValueError:
        return False


def _is_bool(value: Any) -> bool:
    return isinstance(value, bool)


def _is_count(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_positive(value: Any) -> bool:
    return _is_count(value) and value > 0


def _is_percent(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value <= 100


def _is_windows(value: Any) -> bool:
    return isinstance(value, list) and all(isinstance(w, str) and _QUIET_WINDOW.match(w) for w in value)


_WANTS = {_is_duration: "a duration such as 90s, 15m or 4h", _is_bool: "true or false",
          _is_count: "a non-negative integer", _is_positive: "a positive integer",
          _is_percent: "a percentage from 0 to 100", _is_windows: 'a list of "HH:MM-HH:MM" windows'}
_WAKE_SCHEMA = {"urgent_quiet": _is_duration, "normal_quiet": _is_duration, "max_hold": _is_duration,
                "min_gap": _is_duration, "max_wakes_per_hour": _is_positive, "remind_after": _is_duration,
                "hold_above_percent": _is_percent, "keep_warm": _is_bool, "keep_warm_after": _is_duration,
                "quiet_hours": _is_windows}
_DISPATCH_SCHEMA = {"enabled": _is_bool, "max_nudges": _is_count, "max_ci_nudges": _is_count,
                    "stall_after": _is_duration, "ci_timeout": _is_duration, "retire_merged": _is_bool,
                    "wake": _WAKE_SCHEMA, "precompact_after": _is_duration,
                    "precompact_min_tokens": _is_positive}
_CONTEXT_SCHEMA = {"auto_compact_window": _is_positive, "idle_compact_min_tokens": _is_positive}


def _block_errors(block: Any, where: str, schema: dict[str, Any]) -> list[str]:
    if not isinstance(block, dict):
        return [f"{where}: must be an object"]
    errors = []
    for key, value in block.items():
        check = schema.get(key)
        if check is None:
            errors.append(f"{where}: unknown key {key!r}")
        elif isinstance(check, dict):
            errors.extend(_block_errors(value, f"{where}.{key}", check))
        elif not check(value):
            errors.append(f"{where}.{key}: must be {_WANTS[check]}")
    return errors


def config_errors(config: dict[str, Any]) -> list[str]:
    """Every defect in the `session_dispatch` and `orchestrator_context` blocks."""
    errors = []
    if "session_dispatch" in config:
        errors.extend(_block_errors(config["session_dispatch"], "session_dispatch", _DISPATCH_SCHEMA))
    if "orchestrator_context" in config:
        errors.extend(_block_errors(config["orchestrator_context"], "orchestrator_context", _CONTEXT_SCHEMA))
    return errors


def policy_from(block: dict[str, Any] | None, hold_sends: bool = False) -> dict[str, Any]:
    """The validated block with its defaults, durations in seconds."""
    block = block or {}
    return {"enabled": block.get("enabled") is True,
            "max_nudges": block.get("max_nudges", 2),
            "max_ci_nudges": block.get("max_ci_nudges", 2),
            "stall_after": seconds(block.get("stall_after", "15m")),
            "ci_timeout": seconds(block.get("ci_timeout", "60m")),
            "retire_merged": block.get("retire_merged") is True,
            "hold_sends": hold_sends}
