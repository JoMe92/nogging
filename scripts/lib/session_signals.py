"""Pure mapping for Nogging's normalized session lifecycle events (schema 2).

No I/O beyond bounded file reads, no clock, no secret store: callers inject the
timestamp and the redaction function. See openspec/changes/session-wake, design
Decision 2.
"""
from __future__ import annotations

import json
import os
import re
from typing import Any, Callable

SCHEMA = 2
STDIN_LIMIT = 64 * 1024
EVENTS_ROTATE_BYTES = 256 * 1024
EXCERPT_LIMIT = 300

EVENTS = ("turn_start", "turn_end", "needs_input", "turn_error", "session_end", "blocked", "done")
# A signal is a fact an agent states about itself, never a classified state.
SIGNALS = ("blocked", "done")

# Only these Claude `Notification` types are questions to a person.
QUESTION_NOTIFICATIONS = frozenset({
    "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
})

STATE_MAP = {
    "turn_start": "working",
    "turn_end": "idle",
    "needs_input": "needs_input",
    "session_end": "ended",
}

SOURCES = {"claude": "claude-hook", "codex": "codex-hook", "pi": "pi-extension"}

_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f  ]+")
_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+")
_FIELD_RE = re.compile(r"[^A-Za-z0-9_.:\-]")


def clean_excerpt(text: Any, redact: Callable[[str], str] | None = None, limit: int = EXCERPT_LIMIT) -> str | None:
    """Single-line, control-free, redacted, email-scrubbed text of at most `limit` characters."""
    if not isinstance(text, str):
        return None
    if redact is not None:
        text = redact(text)
    text = _EMAIL_RE.sub("***EMAIL***", text)
    text = " ".join(_CONTROL_RE.sub(" ", text).split())
    if len(text) > limit:
        text = text[:limit - 1].rstrip() + "…"
    return text or None


def _token(value: Any) -> str | None:
    """A short identifier field (error kind, notification type), never free text."""
    if not isinstance(value, str):
        return None
    value = _FIELD_RE.sub("", value)[:64]
    return value or None


def background_count(value: Any) -> int:
    """Count of background tasks still in flight from an int or a list of tasks."""
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return max(0, value)
    if isinstance(value, list):
        done = {"completed", "complete", "failed", "killed", "cancelled", "stopped", "exited"}
        return sum(1 for task in value
                   if not (isinstance(task, dict) and str(task.get("status", "")).lower() in done))
    return 0


def read_payload(raw: bytes | str | None) -> dict[str, Any]:
    """Hook JSON from at most STDIN_LIMIT bytes; anything unusable is an empty payload."""
    if not raw:
        return {}
    try:
        if isinstance(raw, bytes):
            raw = raw[:STDIN_LIMIT].decode("utf-8", "replace")
        value = json.loads(raw[:STDIN_LIMIT])
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def is_recorded(event: str, payload: dict[str, Any]) -> bool:
    """False for a `Notification` that is not a question (for example `idle_prompt`)."""
    if event != "needs_input":
        return True
    kind = payload.get("notification_type")
    return kind is None or kind in QUESTION_NOTIFICATIONS


def build_event(session: str, event: str, payload: dict[str, Any] | None, timestamp: str, agent: str | None = None,
                redact: Callable[[str], str] | None = None) -> dict[str, Any]:
    """One schema 2 line holding the whitelisted fields only."""
    payload = payload if isinstance(payload, dict) else {}
    message = payload.get("last_assistant_message")
    if message is None:
        message = payload.get("last_agent_message")
    return {
        "schema": SCHEMA,
        "timestamp": timestamp,
        "session": session,
        "event": event,
        "source": SOURCES.get(agent or "", "hook"),
        "error": _token(payload.get("error")),
        "notification_type": _token(payload.get("notification_type")),
        "background_tasks": background_count(payload.get("background_tasks")),
        "excerpt": clean_excerpt(message, redact),
    }


def build_signal(session: str, kind: str, reason: str, timestamp: str,
                 redact: Callable[[str], str] | None = None) -> dict[str, Any]:
    """A `blocked` or `done` line: a fact, with the reason as its excerpt."""
    if kind not in SIGNALS:
        raise ValueError(f"unknown signal {kind!r}; choose blocked or done")
    excerpt = clean_excerpt(reason, redact)
    if excerpt is None:
        raise ValueError("a signal needs a non-empty reason")
    return {"schema": SCHEMA, "timestamp": timestamp, "session": session, "event": kind,
            "source": "session-signal", "error": None, "notification_type": None,
            "background_tasks": 0, "excerpt": excerpt}


def event_state(record: dict[str, Any]) -> str | None:
    """The classified state one event implies, or None for a signal (not a state)."""
    kind = record.get("event")
    if kind in SIGNALS:
        return None
    if kind == "turn_end":
        return "waiting_background" if background_count(record.get("background_tasks")) else "idle"
    if kind == "turn_error":
        return "limit" if record.get("error") == "rate_limit" else "idle"
    return STATE_MAP.get(kind, "unknown")


def read_events(path: str | os.PathLike[str], limit: int = EVENTS_ROTATE_BYTES) -> list[dict[str, Any]]:
    """Parsed events from the end of a per-session file; junk lines are skipped."""
    try:
        with open(path, "rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - limit))
            data = stream.read()
    except OSError:
        return []
    records = []
    for line in data.splitlines():
        try:
            record = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue
        if isinstance(record, dict) and isinstance(record.get("event"), str):
            records.append(record)
    return records


def latest_state(records: list[dict[str, Any]]) -> tuple[str | None, dict[str, Any] | None]:
    """State and event of the newest state-bearing record; signals are skipped."""
    for record in reversed(records):
        state = event_state(record)
        if state is not None:
            return state, record
    return None, None


def current_signal(records: list[dict[str, Any]]) -> dict[str, Any] | None:
    """The newest `blocked`/`done` signal, unless a later turn has started since."""
    for record in reversed(records):
        if record.get("event") == "turn_start":
            return None
        if record.get("event") in SIGNALS:
            return record
    return None


HERDR_STATES = {"blocked": "needs_input", "done": "idle", "idle": "idle", "working": "working"}
# Pane states herdr has no word for; they stay visible when herdr reports a status.
PANE_REFINEMENTS = frozenset({"limit", "waiting_background"})


def herdr_state(status: Any) -> str | None:
    """The classified state herdr's `agent_status` documents, or None.

    `blocked` is an approval UI (needs_input) and `done` an unseen `idle`. Neither
    proves the work is finished, and `unknown` proves nothing."""
    return HERDR_STATES.get(status) if isinstance(status, str) else None


def resolve_state(event: str | None, rollout: str | None, pane: str | None,
                  herdr: str | None = None) -> tuple[str, str]:
    """One evidence order for every agent: event, rollout, herdr, then pane.

    An `idle` from an event or rollout yields to a live `working` herdr status or
    pane, so a turn whose start hook was lost is still seen. `unknown` stays
    `unknown`: no source infers completion. `herdr` is the raw `agent_status`.
    Returns (state, source)."""
    pane = pane if pane not in (None, "unknown") else None
    herdr_live = herdr_state(herdr)
    if herdr_live is not None and pane in PANE_REFINEMENTS:
        herdr_live = None
    live, live_source = (herdr_live, "herdr") if herdr_live is not None else (pane, "pane")
    if event == "ended":
        return event, "event"
    if rollout == "working":
        return "working", "rollout"
    if event is not None:
        if live is not None and (event == "needs_input" or (event == "idle" and live == "working")):
            return live, live_source
        return event, "event"
    if rollout is not None:
        if rollout == "idle" and live == "working":
            return "working", live_source
        return rollout, "rollout"
    if live is not None:
        return live, live_source
    return "unknown", "none"
