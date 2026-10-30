"""Pure mapping for Nogging's normalized session lifecycle events (schema 2).

No I/O beyond bounded file reads, no clock, no secret store: callers inject the
timestamp and the redaction function. See openspec/changes/session-wake, design
Decision 2.
"""
from __future__ import annotations

import json
import os
import re
import stat
from typing import Any, Callable

SCHEMA = 2
STDIN_LIMIT = 64 * 1024
EVENTS_ROTATE_BYTES = 256 * 1024
EXCERPT_LIMIT = 300

EVENTS = ("turn_start", "turn_end", "needs_input", "turn_error", "session_end", "blocked", "done", "guard_continue")
# A signal is a fact an agent states about itself, never a classified state.
SIGNALS = ("blocked", "done")
# A stop the guard turned into a continuation: the turn goes on, so no state changes.
GUARD_CONTINUE = "guard_continue"

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
_EMAIL_RE = re.compile(r"[\w.%+\-]+@[\w\-]+(?:\.[\w\-]+)+")
# `redact` knows this host's values and `name=value`. These give a secret away with
# neither, in text from a pane or an exception of some other tool.
_PRIVATE_KEY_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)", re.S)
_SECRET_PAIR_RE = re.compile(
    r"""(["']?[\w.-]*(?:token|secret|password|passwd|api[_-]?key|private[_-]?key|credential|authorization)["']?"""
    r"""\s*[:=]\s*)(?:"[^"]*"|'[^']*'|(?:basic|bearer|token)\s+\S+|\S+)""", re.I)
_SECRET_SHAPES_RE = re.compile(
    r"\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|glpat-[A-Za-z0-9_-]{16,}|npm_[A-Za-z0-9]{16,}"
    r"|pypi-[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9_-]{16,}|[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"
    r"|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[A-Za-z0-9_-]{30,}"
    r"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]{10,}"
    r"|(?-i:(?=[\w-]*[A-Z])(?=[\w-]*[a-z])(?=[\w-]*\d)[\w-]{32,}))\b"
    r"|\bbearer\s+\S+|(?<=://)[^/\s:@]+:[^/\s@]+(?=@)", re.I)
_FIELD_RE = re.compile(r"[^A-Za-z0-9_.:\-]")


def scrub_secrets(text: str) -> str:
    text = _PRIVATE_KEY_RE.sub("***REDACTED***", text)
    text = _SECRET_PAIR_RE.sub(lambda match: match.group(1) + "***REDACTED***", text)
    return _SECRET_SHAPES_RE.sub("***REDACTED***", text)


def clean_excerpt(text: Any, redact: Callable[[str], str] | None = None, limit: int = EXCERPT_LIMIT) -> str | None:
    """Single-line, control-free, redacted, email-scrubbed text of at most `limit` characters."""
    if not isinstance(text, str):
        return None
    if redact is not None:
        text = redact(text)
    text = _EMAIL_RE.sub("***EMAIL***", scrub_secrets(text))
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
    if kind in SIGNALS or kind == GUARD_CONTINUE:
        return None
    if kind == "turn_end":
        return "waiting_background" if background_count(record.get("background_tasks")) else "idle"
    if kind == "turn_error":
        return "limit" if record.get("error") == "rate_limit" else "idle"
    return STATE_MAP.get(kind, "unknown")


def read_events(path: str | os.PathLike[str], limit: int = EVENTS_ROTATE_BYTES) -> list[dict[str, Any]]:
    """Parsed events from the end of a per-session file; junk lines are skipped. The
    file is the session's to replace and an operator's `doctor` reads it, so anything
    but a regular file reads as empty: opening a planted FIFO would block forever."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return []
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


GUARDED_AGENTS = ("claude", "codex", "pi")
GAP_TEXT = {
    "dirty": "uncommitted changes",
    "unpushed": "unpushed commits",
    "no-signal": "no completion signal (run `./scripts/nogg session signal done \"PR #<n> open\"` "
                 "once the pull request is open)",
}
GUARD_MESSAGE = ("You are ending your turn with: {gaps}. Commit, push and open the pull request now. "
                 "If you cannot, run `./scripts/nogg session signal blocked \"<why>\"` and stop. "
                 "Do not answer with a plan.")


def this_turn(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The events since the last `turn_end`. Codex hooks report no `turn_start`, so a
    stop must not count a signal from an earlier turn. Only the guard narrows this
    far: a finished Lead that signalled and went idle has no gap."""
    for index in range(len(events) - 1, -1, -1):
        if events[index].get("event") == "turn_end":
            return events[index + 1:]
    return events


def completion_gaps(git: dict[str, Any] | None, events: list[dict[str, Any]]) -> list[str]:
    """`dirty`, `unpushed` and `no-signal` from injected git facts and the session's
    events. `git` is {"dirty", "upstream", "ahead"}, or None when it is unknown."""
    gaps = []
    if git is not None:
        if git.get("dirty"):
            gaps.append("dirty")
        if not git.get("upstream") or git.get("ahead"):
            gaps.append("unpushed")
    if current_signal(events) is None:
        gaps.append("no-signal")
    return gaps


def guard_message(gaps: list[str]) -> str:
    """The fixed continuation text. It carries gap names only, never agent output."""
    return GUARD_MESSAGE.format(gaps=", ".join(GAP_TEXT[gap] for gap in gaps))


def guard_applies(session: dict[str, Any], events: list[dict[str, Any]], payload: dict[str, Any] | None = None) -> bool:
    """Whether a stop may be continued at all. Only a kicked-off Lead under the
    `autonomous` prompt has the authority to finish; a startup turn before its
    kickoff has no work to complete. A `payload` is a Stop hook's: it blocks only
    when `stop_hook_active` is explicitly False, because that field is the bound on
    Claude and Codex and an unreadable payload must not lose it. `guard_continue`
    backs it up: a stop sequence is never continued twice. Pi passes None."""
    if (session.get("role") != "lead" or session.get("launch_prompt") != "autonomous"
            or session.get("agent") not in GUARDED_AGENTS or not session.get("kickoff_sent_at")):
        return False
    if payload is not None and payload.get("stop_hook_active") is not False:
        return False
    payload = payload or {}
    if payload.get("error") or background_count(payload.get("background_tasks")):
        return False
    # Codex hooks report no `turn_start`, so `turn_end` closes a turn here too: a
    # signal from an earlier turn must not excuse this one.
    for record in reversed(events):
        kind = record.get("event")
        if kind in ("turn_start", "turn_end"):
            return True
        if kind in SIGNALS or kind in ("turn_error", GUARD_CONTINUE):
            return False
    return True


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
