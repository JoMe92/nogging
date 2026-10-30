"""The pure half of `nogg pause`: when a pause ends, its state and what it reports.

No clock and no host: callers inject the time, the known loops and the audit rows. See
openspec/changes/session-wake, design Decision 16.

`pause.json` holds `schema`, `started_at`, `until`, `keep_loops`, `set_by` and
`compacted_at`. It lies in the shared checkout, which a restricted Codex Lead and Pi can
write, so it is no trust boundary. A broken pause must not silently stop work: whatever
no `nogg pause` could have written reads as not paused, so a planted file cannot pass
the 60-day bound, and a text field cannot reach a session unshaped.
"""
from __future__ import annotations

import errno
import json
import os
import re
import stat
import tempfile
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from session_dispatch import dedupe_key, iso

SCHEMA = 1
MAX_DAYS = 60
MAX_AGE_DAYS = 3660
MAX_BYTES = 64 * 1024
HOST_SESSION = "host"
FINISHED_KINDS = frozenset({"ready_for_review", "planner_finished"})
FINISHED_CHARS = 200

_UNTIL = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T[0-9]{2}:[0-9]{2})?")
_DAYS = re.compile(r"[0-9]{1,6}")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")


def local(moment: datetime) -> str:
    return moment.astimezone().strftime("%Y-%m-%d %H:%M %Z")


def duration(seconds: float) -> str:
    minutes, hours = int(seconds // 60), int(seconds // 3600)
    if minutes == 0:
        return "under 1m"
    if hours == 0:
        return f"{minutes}m"
    if hours < 24:
        return f"{hours}h {minutes % 60}m"
    return f"{hours // 24}d {hours % 24}h"


def _moment(value: Any) -> datetime | None:
    """An aware stamp, or None: a stamp without a zone is nothing this code wrote."""
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else None


def read_regular(path: Any, limit: int, tail: bool = False) -> bytes:
    """At most `limit` bytes of a regular file, its last ones with `tail`. The open neither
    follows a link nor waits on a planted FIFO, because the state, the queue and the audit
    log lie in the shared checkout and every tick reads them. OSError for anything else."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        status = os.fstat(stream.fileno())
        if not stat.S_ISREG(status.st_mode):
            raise OSError(errno.EINVAL, "not a regular file")
        if tail:
            stream.seek(max(0, status.st_size - limit))
        return stream.read(limit)


def set_aside(path: Any) -> None:
    """Move what is no regular file out of the way of an append, which would block on a
    planted FIFO or write through a link."""
    try:
        if stat.S_ISREG(os.lstat(path).st_mode):
            return
    except FileNotFoundError:
        return
    os.replace(path, f"{path}.corrupt.{uuid.uuid4().hex}")


def parse_end(until: str | None, days: str | None, now: datetime) -> datetime:
    """The end of a pause. ValueError names what is wrong with it."""
    if (until is None) == (days is None):
        raise ValueError("give exactly one of --until and --days")
    if days is not None:
        if not _DAYS.fullmatch(days):
            raise ValueError(f"--days must be a whole number of days: {days!r}")
        if int(days) > MAX_DAYS:
            raise ValueError(f"--days must be at most {MAX_DAYS}: {days}")
        end = now + timedelta(days=int(days))
    else:
        if not _UNTIL.fullmatch(until):
            raise ValueError(f"--until must be YYYY-MM-DD or YYYY-MM-DDTHH:MM in local time: {until!r}")
        try:
            end = datetime.fromisoformat(until).astimezone()
        except (ValueError, OverflowError, OSError) as exc:
            raise ValueError(f"--until is no valid local time: {until!r}") from exc
    if end <= now:
        raise ValueError(f"the end {local(end)} is not in the future")
    if end - now > timedelta(days=MAX_DAYS):
        raise ValueError(f"the end {local(end)} is more than {MAX_DAYS} days away")
    return end


def kept_loops(names: list[str], known: Any) -> list[str]:
    unknown = sorted(set(names) - set(known))
    if unknown:
        raise ValueError(f"--keep-loop names an unknown loop: {', '.join(unknown)}")
    return sorted(set(names))


def begin(previous: dict[str, Any] | None, end: datetime, keep: list[str], set_by: str,
          now: datetime) -> dict[str, Any]:
    """A new pause, or one replacing `previous`: same start and same one compaction."""
    previous = previous or {}
    return {"schema": SCHEMA, "started_at": previous.get("started_at") or iso(now), "until": iso(end),
            "keep_loops": keep, "set_by": set_by, "compacted_at": previous.get("compacted_at")}


def _problem(value: Any, now: datetime) -> str | None:
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        return "not a pause of this version"
    started, until = _moment(value.get("started_at")), _moment(value.get("until"))
    if started is None or until is None or until <= started:
        return "no usable start and end"
    if until - now > timedelta(days=MAX_DAYS):
        return f"an end more than {MAX_DAYS} days away"
    if started > now or now - started > timedelta(days=MAX_AGE_DAYS):
        return "a start no pause can have"
    keep = value.get("keep_loops")
    if not isinstance(keep, list) or not all(isinstance(name, str) and _NAME.fullmatch(name) for name in keep):
        return "no usable kept loops"
    if not isinstance(value.get("set_by"), str) or not _NAME.fullmatch(value["set_by"]):
        return "no usable setter"
    if value.get("compacted_at") is not None and _moment(value["compacted_at"]) is None:
        return "no usable compaction time"
    return None


def read(path: Any, now: datetime) -> tuple[dict[str, Any] | None, str | None]:
    """(state, problem): both None without a file, and a state only for a usable one."""
    try:
        data = read_regular(path, MAX_BYTES + 1)
    except FileNotFoundError:
        return None, None
    except OSError as exc:
        return None, exc.strerror or "unreadable"
    if len(data) > MAX_BYTES:
        return None, f"larger than {MAX_BYTES} bytes"
    try:
        value = json.loads(data)
    except (ValueError, RecursionError):
        return None, "not valid JSON"
    problem = _problem(value, now)
    if problem:
        return None, problem
    return {key: value.get(key) for key in ("schema", "started_at", "until", "keep_loops", "set_by",
                                            "compacted_at")}, None


def write(path: Any, state: dict[str, Any]) -> None:
    """Atomically, so that a reader sees a whole pause and a crash leaves the old one."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(state, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def clear(path: Any) -> None:
    Path(path).unlink(missing_ok=True)


def is_active(state: dict[str, Any] | None, now: datetime) -> bool:
    return bool(state) and now < _moment(state["until"])


def is_due(state: dict[str, Any] | None, now: datetime) -> bool:
    """Past its end and not ended yet, which the next pass does."""
    return bool(state) and not is_active(state, now)


def until_text(state: dict[str, Any]) -> str:
    return local(_moment(state["until"]))


def status(state: dict[str, Any] | None, now: datetime, problem: str | None = None) -> dict[str, Any]:
    if is_active(state, now):
        left = int((_moment(state["until"]) - now).total_seconds())
        return {"paused": True, "started_at": state["started_at"], "until": state["until"], "seconds_left": left,
                "keep_loops": state["keep_loops"], "set_by": state["set_by"]}
    view: dict[str, Any] = {"paused": False}
    if state:
        view["ended_at"] = state["until"]
    if problem:
        view["problem"] = problem
    return view


def status_lines(view: dict[str, Any]) -> list[str]:
    if not view["paused"]:
        if view.get("ended_at"):
            return [f"not paused: the pause ended at {local(_moment(view['ended_at']))} and is not cleared yet"]
        if view.get("problem"):
            return [f"not paused: pause.json cannot be used ({view['problem']})"]
        return ["not paused"]
    return [f"paused until {local(_moment(view['until']))} ({duration(view['seconds_left'])} left)",
            f"started {local(_moment(view['started_at']))} by {view['set_by']}",
            "kept loops: " + (", ".join(view["keep_loops"]) or "none")]


def summarize(rows: list[dict[str, Any]], state: dict[str, Any]) -> dict[str, Any]:
    """What the audit log says happened since the start. An item counts once, by its
    last outcome. The log is writable like the state, so it only ever gives counts and
    names of a safe shape."""
    started = _moment(state["started_at"])
    last, finished = {}, set()
    for row in rows:
        moment = _moment(row.get("time"))
        if moment is None or moment < started:
            continue
        action, outcome, session = row.get("action"), row.get("outcome"), row.get("session")
        if action == "item" and isinstance(row.get("key"), str) and outcome in ("queued", "cleared"):
            last[row["key"]] = outcome
            done = isinstance(row.get("kind"), str) and row["kind"] in FINISHED_KINDS
        else:
            done = action == "retire" and outcome == "done"
        if done and isinstance(session, str) and _NAME.fullmatch(session):
            finished.add(session)
    return {"seen": len(last), "cleared": sum(1 for outcome in last.values() if outcome == "cleared"),
            "finished": sorted(finished)}


def _finished_text(names: list[str]) -> str:
    shown: list[str] = []
    for name in names:
        if len(", ".join([*shown, name])) > FINISHED_CHARS:
            break
        shown.append(name)
    more = len(names) - len(shown)
    return ", ".join(shown) + (f" +{more} more" if more else "")


def resumed_item(state: dict[str, Any], rows: list[dict[str, Any]], now: datetime) -> dict[str, Any] | None:
    """The one summary of a pause in which something happened, else None. Nothing can
    derive it again, so it is `sticky`, and its key is the pause, so an end repeated
    after a crash adds no second one."""
    seen = summarize(rows, state)
    if not seen["seen"]:
        return None
    length = duration((now - _moment(state["started_at"])).total_seconds())
    reason = f"paused {length}: {seen['seen']} item(s) seen, {seen['cleared']} cleared on their own"
    if seen["finished"]:
        reason += "; finished: " + _finished_text(seen["finished"])
    key = dedupe_key(HOST_SESSION, "resumed", state["started_at"])
    return {"key": key, "kind": "resumed", "session": HOST_SESSION, "bead": None, "pr": None, "ci": None,
            "diff": None, "head": None, "reason": reason, "next": "./scripts/nogg session inbox", "sticky": True}
