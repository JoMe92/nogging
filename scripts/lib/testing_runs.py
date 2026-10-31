"""The run records of `nogg test`: schema 1, the append with its rotation, and the
test detail read from JUnit XML or a `<seconds>\\t<name>` timings file.

A record is append-only JSON in the main checkout, so every worktree feeds one
trend. A restricted Lead can write the file, so it is no trust boundary: readers
go through `read_records`, which validates every field. A record never holds the
command line, because a command may hold a secret.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import json
import math
import os
import re
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

SCHEMA = 1
RECORD_FILE = "runs.jsonl"
ROTATED_FILE = "runs.jsonl.1"
LOCK_FILE = "runs.lock"
ROTATE_BYTES = 5 * 1024 * 1024
MAX_RESULT_BYTES = 32 * 1024 * 1024
SLOWEST_KEPT = 10
SLOWEST_PRINTED = 5
FAILED_NAMES_KEPT = 5
MAX_TEXT = 200
MAX_REASON = 500
STATUSES = ("passed", "failed", "skipped", "refused")
BEAD_TOKEN_RE = re.compile(r"\[([A-Za-z][A-Za-z0-9]*-[A-Za-z0-9.]+)\]")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]+")
TEXT_FIELDS = ("id", "at", "stage", "trigger", "bead", "session", "role", "branch", "head")
COUNT_FIELDS = ("tests", "failed_tests", "skipped_tests")
NUMBER_FIELDS = ("seconds", "wait_seconds", "budget_seconds")


def clean_text(value, limit=MAX_TEXT):
    """`value` as one bounded line of text, or None. Test names and reasons come
    from runners and agents, and they end up in a terminal and a digest."""
    if value is None:
        return None
    return CONTROL_RE.sub(" ", str(value)).strip()[:limit] or None


def _seconds(value):
    """A non-negative finite number from `value`, or None."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) and number >= 0 else None


def slowest_tests(tests, limit=SLOWEST_KEPT):
    """The `limit` slowest of `[{name, seconds}]`, ties in name order."""
    return sorted(tests, key=lambda test: (-test["seconds"], test["name"]))[:limit]


def _empty_detail():
    return {"tests": None, "failed_tests": None, "skipped_tests": None, "slowest": [], "failed_names": []}


def merge_details(details):
    """One detail from several commands' details; a count is null only when no
    command reported it."""
    merged, slowest, names = _empty_detail(), [], []
    for detail in details:
        if detail is None:
            continue
        for key in COUNT_FIELDS:
            if detail.get(key) is not None:
                merged[key] = (merged[key] or 0) + detail[key]
        slowest.extend(detail.get("slowest") or [])
        names.extend(detail.get("failed_names") or [])
    merged["slowest"] = slowest_tests(slowest)
    merged["failed_names"] = names[:FAILED_NAMES_KEPT]
    return merged


def _readable(path):
    try:
        return 0 < os.path.getsize(path) <= MAX_RESULT_BYTES
    except OSError:
        return False


def parse_junit(path):
    """The detail of a JUnit XML file, or None when it is missing, malformed or
    above the size limit. A runner's broken file is "no detail", never a failure."""
    if not _readable(path):
        return None
    tests = failed = skipped = 0
    timed, names, seen_root = [], [], False
    try:
        for _event, element in ET.iterparse(path, events=("end",)):
            tag = element.tag.rsplit("}", 1)[-1]
            if tag in ("testsuite", "testsuites"):
                seen_root = True
            if tag != "testcase":
                continue
            tests += 1
            children = {child.tag.rsplit("}", 1)[-1] for child in element}
            failed += bool(children & {"failure", "error"})
            skipped += "skipped" in children
            name = clean_text(".".join(filter(None, (element.get("classname"), element.get("name"))))) or "unnamed"
            timed.append({"name": name, "seconds": _seconds(element.get("time")) or 0.0})
            if children & {"failure", "error"} and len(names) < FAILED_NAMES_KEPT:
                names.append(name)
            element.clear()
    except (ET.ParseError, OSError, ValueError):
        return None
    if not seen_root:
        return None
    return {"tests": tests, "failed_tests": failed, "skipped_tests": skipped, "slowest": slowest_tests(timed),
            "failed_names": names}


def parse_timings(path):
    """The detail of a `<seconds>\\t<name>` file, or None when any line is
    malformed. Timings say what ran and how long, not what failed."""
    if not _readable(path):
        return None
    timed = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                seconds, tab, name = line.rstrip("\n").partition("\t")
                seconds, name = _seconds(seconds), clean_text(name)
                if not tab or seconds is None or not name:
                    return None
                timed.append({"name": name, "seconds": seconds})
    except (OSError, ValueError):
        return None
    if not timed:
        return None
    return {"tests": len(timed), "failed_tests": None, "skipped_tests": None, "slowest": slowest_tests(timed)}


def read_detail(steps):
    """The merged detail of `steps` that ran; JUnit wins over timings per step."""
    return merge_details(parse_junit(step["junit"]) or parse_timings(step["timings"]) for step in steps)


def bead_from_subjects(subjects):
    """The Bead of the newest commit subject carrying an `[<id>]` token, or None."""
    for subject in subjects:
        match = BEAD_TOKEN_RE.search(subject)
        if match:
            return match.group(1)
    return None


def new_id():
    return uuid.uuid4().hex


def build_record(*, stage, trigger, status, exit_code, seconds=0.0, wait_seconds=0.0, budget_seconds=None,
                 over_budget=False, reason=None, bead=None, session=None, role=None, branch=None, head=None,
                 detail=None, at=None, run_id=None):
    """One schema-1 record. There is deliberately no `command` argument."""
    detail = detail or _empty_detail()
    return {
        "schema": SCHEMA,
        "id": run_id or new_id(),
        "at": at or dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "stage": stage,
        "trigger": trigger,
        "reason": clean_text(reason, MAX_REASON),
        "status": status,
        "exit": exit_code,
        "seconds": round(seconds, 3),
        "wait_seconds": round(wait_seconds, 3),
        "budget_seconds": budget_seconds,
        "over_budget": bool(over_budget),
        "bead": clean_text(bead),
        "session": clean_text(session),
        "role": clean_text(role),
        "branch": clean_text(branch),
        "head": clean_text(head),
        "tests": detail.get("tests"),
        "failed_tests": detail.get("failed_tests"),
        "skipped_tests": detail.get("skipped_tests"),
        "slowest": detail.get("slowest") or [],
        "failed_names": detail.get("failed_names") or [],
    }


def _write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def append_record(directory, record, rotate_bytes=ROTATE_BYTES):
    """Append `record` as one line, rotating a full file to `runs.jsonl.1` first.
    The lock is held only for this, so two runs cannot both rotate and lose the
    older file. Raises OSError; the caller reports it and keeps the test result."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, sort_keys=True, ensure_ascii=True) + "\n"
    lock = os.open(directory / LOCK_FILE, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / RECORD_FILE
        try:
            if path.stat().st_size > rotate_bytes:
                os.replace(path, directory / ROTATED_FILE)
        except FileNotFoundError:
            pass
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            _write_all(fd, line.encode())
        finally:
            os.close(fd)
    finally:
        os.close(lock)


def _valid_slowest(value):
    if not isinstance(value, list) or len(value) > SLOWEST_KEPT:
        return None
    tests = []
    for test in value:
        if not isinstance(test, dict) or not isinstance(test.get("name"), str):
            return None
        seconds = test.get("seconds")
        if type(seconds) not in (int, float) or _seconds(seconds) is None:
            return None
        tests.append({"name": clean_text(test["name"]) or "unnamed", "seconds": seconds})
    return tests


def valid_record(value):
    """A clean copy of the parsed line `value`, or None when any field is wrong."""
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        return None
    if value.get("status") not in STATUSES or type(value.get("exit")) is not int:
        return None
    if type(value.get("over_budget")) is not bool:
        return None
    record = {"schema": SCHEMA, "status": value["status"], "exit": value["exit"],
              "over_budget": value["over_budget"]}
    for key in TEXT_FIELDS + ("reason",):
        field = value.get(key)
        if field is not None and not isinstance(field, str):
            return None
        record[key] = clean_text(field, MAX_REASON if key == "reason" else MAX_TEXT)
    if not record["id"] or not record["at"] or not record["stage"]:
        return None
    for key in COUNT_FIELDS:
        count = value.get(key)
        if count is not None and (type(count) is not int or count < 0):
            return None
        record[key] = count
    for key in NUMBER_FIELDS:
        number = value.get(key)
        if number is not None and (type(number) not in (int, float) or _seconds(number) is None):
            return None
        record[key] = number
    names = value.get("failed_names", [])
    if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
        return None
    record["failed_names"] = [clean_text(name) or "unnamed" for name in names[:FAILED_NAMES_KEPT]]
    record["slowest"] = _valid_slowest(value.get("slowest", []))
    return record if record["slowest"] is not None else None


def read_records(directory):
    """Every valid record, oldest first, across the rotated and current files. A
    line that does not validate is dropped, and an unreadable file reads as empty."""
    records = []
    for name in (ROTATED_FILE, RECORD_FILE):
        try:
            with open(Path(directory) / name, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    try:
                        record = valid_record(json.loads(line))
                    except ValueError:
                        continue
                    if record is not None:
                        records.append(record)
        except OSError:
            continue
    return records


def prune_logs(directory, keep):
    """Keep the newest `keep` `*.log` files; a file another run removed is fine."""
    logs = []
    for path in Path(directory).glob("*.log"):
        try:
            logs.append((path.stat().st_mtime, path))
        except OSError:
            continue
    for _mtime, path in sorted(logs, key=lambda item: (item[0], str(item[1])), reverse=True)[keep:]:
        try:
            path.unlink()
        except OSError:
            continue
