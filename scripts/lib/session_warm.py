"""The pure half of an orchestrator that waits: quiet hours, keep-warm and one compaction.

No I/O and no clock: callers inject the facts, the policy, the time and the bytes of a
transcript tail. See openspec/changes/session-wake, design Decisions 9 and 15.

A fact is the orchestrator's evidence, and a missing or None value means `unknown`, on
which nothing is sent:

    agent, state    the record's runtime and its classified state
    idle_since      the end of its last turn or the last wake, the later one
    active          a live Lead or planner, or an open pull request
    paused          a pause is in force
    context_tokens  the size its `Stop` hook recorded with that turn
    warmed_at, compacted_at     the last keep-warm and the last compaction

These come from the events file, `warm.json` and `pause.json` in the shared checkout, so
they are no trust boundary: a forged one can only delay or bring forward one of the two
fixed messages below, and those still go only to an idle session with an empty composer.
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from typing import Any

from session_dispatch import seconds, seconds_since
from session_pause import duration, local

# A message inside the hour refreshes the cache of a subscription's main conversation.
CACHE_LIFETIME_SECONDS = 3600
# The transcript is the runtime's own, so the size is read from a bounded tail: the last
# usage record sat within 8 KiB of the end of the 60 newest transcripts of this host.
TRANSCRIPT_TAIL_BYTES = 256 * 1024

KEEP_WARM = "keep-warm"
COMPACT = "compact"
MESSAGES = {
    KEEP_WARM: '[nogg keepwarm] No action. Answer "ok" in one short line and use no tools.',
    COMPACT: "/compact Keep only a short summary of open work: open Beads, pull requests, sessions and pending decisions.",
}

_WINDOW = re.compile(r"([01][0-9]|2[0-3]):([0-5][0-9])-([01][0-9]|2[0-3]):([0-5][0-9])")
_USAGE_FIELDS = ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
_REFERENCE = datetime(2000, 1, 1, tzinfo=timezone.utc)


def parse_window(window: Any) -> tuple[int, int]:
    """`"HH:MM-HH:MM"` as minutes after midnight. A window whose two ends are equal is
    refused: it could mean no time or the whole day, and the whole day silences a host."""
    match = _WINDOW.fullmatch(window) if isinstance(window, str) else None
    if match is None or match.group(1, 2) == match.group(3, 4):
        raise ValueError(f"not a quiet-hours window: {window!r}")
    hour, minute, end_hour, end_minute = (int(part) for part in match.groups())
    return hour * 60 + minute, end_hour * 60 + end_minute


def is_window(window: Any) -> bool:
    try:
        parse_window(window)
    except ValueError:
        return False
    return True


def quiet_window(windows: list[str], now: datetime) -> str | None:
    """The window `now` falls in, by the local wall clock, so that a change to daylight
    saving needs no special case. The end of a window is outside it."""
    clock = now.astimezone()
    minute = clock.hour * 60 + clock.minute
    for window in windows:
        start, end = parse_window(window)
        if (start <= minute < end) if start < end else (minute >= start or minute < end):
            return window
    return None


def policy_from(block: dict[str, Any] | None) -> dict[str, Any]:
    """From the validated `session_dispatch` block, durations in seconds."""
    block = block or {}
    wake = block.get("wake") or {}
    return {"keep_warm": wake.get("keep_warm", True) is True,
            "keep_warm_after": seconds(wake.get("keep_warm_after", "50m")),
            "quiet_hours": list(wake.get("quiet_hours") or []),
            "precompact_after": seconds(block.get("precompact_after", "50m")),
            "precompact_min_tokens": block.get("precompact_min_tokens", 100000)}


def latest(*stamps: Any) -> str | None:
    """The newest of these stamps that can be read."""
    aged = [(seconds_since(stamp, _REFERENCE), stamp) for stamp in stamps if isinstance(stamp, str)]
    readable = [pair for pair in aged if pair[0] is not None]
    return min(readable, key=lambda pair: pair[0])[1] if readable else None


def _idle_age(facts: dict[str, Any], now: datetime) -> float | None:
    """Seconds since the last turn. One stamped ahead of the clock is no reading."""
    age = seconds_since(facts.get("idle_since"), now) if facts.get("idle_since") else None
    return age if age is not None and age >= 0 else None


def _is_size(value: Any) -> bool:
    return type(value) is int and value > 0


def _sent_since_turn(stamp: Any, age: float, now: datetime) -> bool:
    sent = seconds_since(stamp, now) if stamp else None
    return sent is not None and sent <= age


def may_act(facts: dict[str, Any], policy: dict[str, Any], now: datetime) -> bool:
    """Whether this pass falls where a message could help, which is all a caller needs to
    know before it spends a `gh` call on `active`."""
    age = _idle_age(facts, now)
    return (facts.get("agent") == "claude" and facts.get("state") == "idle" and age is not None
            and min(policy["keep_warm_after"], policy["precompact_after"]) <= age < CACHE_LIFETIME_SECONDS)


def warm_plan(facts: dict[str, Any], policy: dict[str, Any], now: datetime) -> str | None:
    """`KEEP_WARM`, `COMPACT` or None, by the table of Decision 15. While a real wake is
    likely the cache is kept. Otherwise it is left to lapse, once compacted while still
    warm, because reprocessing the history uncached costs more than the compaction saves."""
    if not may_act(facts, policy, now):
        return None
    age = _idle_age(facts, now)
    if facts.get("paused") or quiet_window(policy["quiet_hours"], now) or facts.get("active") is False:
        due = (age >= policy["precompact_after"] and _is_size(facts.get("context_tokens"))
               and facts["context_tokens"] > policy["precompact_min_tokens"]
               and not _sent_since_turn(facts.get("compacted_at"), age, now))
        return COMPACT if due else None
    due = (facts.get("active") is True and policy["keep_warm"] and age >= policy["keep_warm_after"]
           and not _sent_since_turn(facts.get("warmed_at"), age, now))
    return KEEP_WARM if due else None


def _usage_size(usage: Any) -> int | None:
    parts = [usage.get(name, 0) for name in _USAGE_FIELDS] if isinstance(usage, dict) else []
    if not all(type(part) is int and part >= 0 for part in parts):
        return None
    return sum(parts) or None


def context_tokens(data: bytes) -> int | None:
    """The context of the main conversation, from the end of its transcript: the last
    non-empty usage, or the size a compaction left, which ends every older record. A
    subagent's turn is another context. The first line of a tail may be cut, and a line
    this code cannot read is skipped, so None means no size was found."""
    for line in reversed(data.splitlines()):
        try:
            row = json.loads(line)
        except (ValueError, RecursionError):
            continue
        if not isinstance(row, dict) or row.get("isSidechain"):
            continue
        if row.get("type") == "system" and row.get("subtype") == "compact_boundary":
            meta = row.get("compactMetadata")
            size = meta.get("postTokens") if isinstance(meta, dict) else None
            return size if _is_size(size) else None
        message = row.get("message")
        size = _usage_size(message.get("usage")) if row.get("type") == "assistant" and isinstance(message, dict) else None
        if size:
            return size
    return None


def _next_compaction(facts: dict[str, Any] | None, policy: dict[str, Any], now: datetime) -> str:
    def reason() -> str | None:
        if facts is None:
            return "no orchestrator"
        if facts.get("agent") != "claude":
            return "not a Claude orchestrator"
        if facts.get("state") != "idle":
            return f"orchestrator {facts.get('state')}"
        if age is None:
            return "no turn end recorded"
        if age >= CACHE_LIFETIME_SECONDS:
            return "the cache has lapsed"
        if _sent_since_turn(facts.get("compacted_at"), age, now):
            return "already compacted"
        if not _is_size(facts.get("context_tokens")):
            return "context size unknown"
        if facts["context_tokens"] <= policy["precompact_min_tokens"]:
            return f"context {facts['context_tokens']} is below {policy['precompact_min_tokens']}"
        return None

    age = _idle_age(facts, now) if facts is not None else None
    why = reason()
    if why:
        return f"no compaction due ({why})"
    at = now + timedelta(seconds=max(0, policy["precompact_after"] - age))
    return f"next compaction {local(at)} if nothing is active then"


def status_line(facts: dict[str, Any] | None, policy: dict[str, Any], now: datetime) -> str:
    """The `doctor` NOTE: what is set and what the next pass may do."""
    keep = f"keep-warm after {duration(policy['keep_warm_after'])}" if policy["keep_warm"] else "keep-warm off"
    windows = ", ".join(policy["quiet_hours"]) or "none"
    applied = " (in force)" if quiet_window(policy["quiet_hours"], now) else ""
    return f"session warm: {keep}; quiet hours {windows}{applied}; {_next_compaction(facts, policy, now)}"
