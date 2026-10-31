"""Bounded incremental reader for fresh Codex submitted-user-message receipts.

Callers must resolve the exact thread and verify the transcript's session_meta
ID and cwd before creating a snapshot. This module never guesses a transcript.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

POLL_LIMIT = 1 * 1024 * 1024
OPERATION_LIMIT = 4 * 1024 * 1024
TURN_STATE_LIMIT = 1 * 1024 * 1024


TERMINAL_EVENTS = {"task_complete", "turn_aborted", "turn_interrupted", "task_aborted", "task_interrupted"}
EXCERPT_SOURCE_LIMIT = 4000
ERROR_MESSAGE_LIMIT = 200


def last_turn(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Read bounded Codex rollout events and describe the last turn.

    Returns {"state": running|idle|none, "end": task_complete|aborted|None,
    "message": raw last_agent_message or None, "reason": abort reason or None,
    "error": the terminal record's error or None}. `error` is {"kind":
    codex_error_info when it is a string else None, "message": at most 200
    characters, "at": the record's timestamp}; a clean turn, or an error of a
    shape this reader does not know, has none, and a non-string kind is never
    guessed.
    Only a task_started followed by a terminal task event proves an idle turn.
    Unknown event names and unreadable records are ignored so newer Codex
    versions stay readable and nothing is read as finished by guesswork.
    """
    result: dict[str, Any] = {"state": "none", "end": None, "message": None, "reason": None, "error": None}
    try:
        source = Path(path)
        with source.open("rb") as stream:
            stream.seek(max(0, source.stat().st_size - TURN_STATE_LIMIT))
            data = stream.read(TURN_STATE_LIMIT)
        if len(data) == TURN_STATE_LIMIT and not data.startswith(b"{"):
            # The first record may be partial; discard it below.
            data = data.split(b"\n", 1)[-1]
        for line in data.splitlines():
            try:
                record = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if not isinstance(record, dict) or record.get("type") != "event_msg":
                continue
            payload = record.get("payload")
            event = payload.get("type") if isinstance(payload, dict) else None
            if event == "task_started":
                result.update(state="running", end=None, message=None, reason=None, error=None)
            elif event in TERMINAL_EVENTS and result["state"] == "running":
                message = payload.get("last_agent_message")
                reason = payload.get("reason")
                result.update(
                    state="idle",
                    end="task_complete" if event == "task_complete" else "aborted",
                    message=message[:EXCERPT_SOURCE_LIMIT] if isinstance(message, str) else None,
                    reason=reason[:200] if isinstance(reason, str) else None,
                    error=_turn_error(payload.get("error"), record.get("timestamp")))
        return result
    except (OSError, ValueError, TypeError):
        return {"state": "none", "end": None, "message": None, "reason": None, "error": None}


def _turn_error(error: Any, stamp: Any) -> dict[str, Any] | None:
    """The terminal record's error, bounded; None for anything this reader does not know."""
    if not isinstance(error, dict):
        return None
    kind, message = error.get("codex_error_info"), error.get("message")
    if not isinstance(message, str) and not isinstance(kind, str):
        return None
    return {"kind": kind if isinstance(kind, str) else None,
            "message": message[:ERROR_MESSAGE_LIMIT] if isinstance(message, str) else "",
            "at": stamp if isinstance(stamp, str) else None}


def turn_state(path: str | os.PathLike[str]) -> str:
    """Return running, idle or none for the rollout's last turn."""
    return last_turn(path)["state"]


def snapshot_source(path: str | os.PathLike[str], thread_id: str) -> dict[str, Any]:
    """Capture file identity, current EOF and unfinished final line."""
    try:
        source = Path(path)
        stat = source.stat()
        with source.open("rb") as stream:
            start = max(0, stat.st_size - POLL_LIMIT)
            stream.seek(start)
            tail = stream.read()
        partial = tail.rsplit(b"\n", 1)[-1] if tail and not tail.endswith(b"\n") else b""
        return {"thread_id": thread_id, "path": os.fspath(source), "device": stat.st_dev,
                "inode": stat.st_ino, "offset": stat.st_size, "partial": partial, "bytes_read": 0}
    except (OSError, ValueError, TypeError):
        return {"unknown": "source unavailable"}


def persistable_source(snapshot: dict[str, Any]) -> dict[str, Any] | None:
    """Opaque identity and start offset of the unread tail, with no transcript text.

    The unfinished final line is rewound rather than stored, so the restored
    snapshot re-reads it once it is complete."""
    try:
        return {"thread_id": snapshot["thread_id"], "path": snapshot["path"], "device": snapshot["device"],
                "inode": snapshot["inode"], "offset": max(0, snapshot["offset"] - len(snapshot["partial"]))}
    except (KeyError, TypeError):
        return None


def restore_snapshot(source: Any) -> dict[str, Any]:
    """Rebuild a snapshot from `persistable_source`; anything else is unknown."""
    try:
        return {"thread_id": str(source["thread_id"]), "path": str(source["path"]), "device": int(source["device"]),
                "inode": int(source["inode"]), "offset": int(source["offset"]), "partial": b"", "bytes_read": 0}
    except (KeyError, TypeError, ValueError):
        return {"unknown": "no persisted receipt source"}


def _normalize(text: str) -> str:
    return text.replace("\r\n", "\n")


def _user_message(record: Any) -> str | None:
    if not isinstance(record, dict) or record.get("type") != "response_item":
        return None
    item = record.get("payload")
    if not isinstance(item, dict) or item.get("type") != "message" or item.get("role") != "user":
        return None
    content = item.get("content")
    if not isinstance(content, list):
        return None
    parts = []
    for part in content:
        if not isinstance(part, dict) or part.get("type") != "input_text" or not isinstance(part.get("text"), str):
            return None
        parts.append(part["text"])
    return "".join(parts) if parts else None


def read_fresh_receipt(snapshot: dict[str, Any], message: str, *, poll_limit: int = POLL_LIMIT,
                       operation_limit: int = OPERATION_LIMIT) -> tuple[dict[str, Any], dict[str, Any]]:
    """Read only appended complete records; return receipt/unknown and next snapshot."""
    if "unknown" in snapshot:
        return {"status": "unknown", "reason": snapshot["unknown"]}, snapshot
    try:
        path = Path(snapshot["path"])
        stat = path.stat()
        if (stat.st_dev, stat.st_ino) != (snapshot["device"], snapshot["inode"]) or stat.st_size < snapshot["offset"]:
            return {"status": "unknown", "reason": "source replaced or truncated"}, snapshot
        remaining = operation_limit - snapshot["bytes_read"]
        if remaining <= 0:
            return {"status": "unknown", "reason": "operation scan limit exceeded"}, snapshot
        amount = min(poll_limit, remaining)
        with path.open("rb") as stream:
            stream.seek(snapshot["offset"])
            data = stream.read(amount)
        combined = snapshot["partial"] + data
        lines = combined.split(b"\n")
        partial = b"" if combined.endswith(b"\n") else lines.pop()
        complete_lines = lines
        next_snapshot = dict(snapshot)
        next_snapshot.update(offset=snapshot["offset"] + len(data), partial=partial,
                             bytes_read=snapshot["bytes_read"] + len(data))
        if not complete_lines:
            return {"status": "unknown", "reason": "no complete receipt record"}, next_snapshot
        expected = _normalize(message)
        cursor = 0
        for line in complete_lines:
            cursor += len(line) + 1
            if not line:
                continue
            try:
                record = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError):
                return {"status": "unknown", "reason": "unsupported record"}, next_snapshot
            text = _user_message(record)
            if text is not None and _normalize(text) == expected:
                return {"status": "receipt", "thread_id": snapshot["thread_id"],
                        "offset": snapshot["offset"] + cursor,
                        "identity": f"{snapshot['device']}:{snapshot['inode']}:{snapshot['offset'] + cursor}"}, next_snapshot
        return {"status": "unknown", "reason": "no matching fresh user message"}, next_snapshot
    except (OSError, KeyError, TypeError, ValueError):
        return {"status": "unknown", "reason": "source unavailable"}, snapshot
