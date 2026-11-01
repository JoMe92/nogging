"""Pure allow-lists, scrubbing, joins, and the Bead list and detail of `nogg dashboard`.

Everything that may reach a client passes through here. A field that is not named in
an allow-list does not exist for the API: the Bead `owner`, `created_by` and
`assignee`, a session's command, prompt, working directory, log path, host, process
identifiers and grants, a stderr text. Free text passes `scrub`, which replaces
e-mail-like and token-like strings and home-directory paths. It is best effort: it
catches the common shapes and nothing more, and the docs say so.

The reader snapshots of the data contract are built from `allow_bead` and
`allow_session`, so the process never holds a raw record. The list and change views
below are derived from those snapshots.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone

BEAD_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
CHANGE_PREFIX = "openspec:change:"
EXIT_REASON_LIMIT = 200
LINE_LIMIT = 200
STATUS_ORDER = ("open", "in_progress", "blocked", "deferred", "closed")

# Allow-listed Bead: the fields of design Decision 9, in the order they are served.
BEAD_FIELDS = ("id", "title", "status", "priority", "issue_type", "labels", "description", "notes",
               "close_reason", "parent", "created_at", "started_at", "closed_at", "updated_at",
               "dependency_count", "dependent_count", "dependencies")
DEPENDENCY_FIELDS = ("issue_id", "depends_on_id", "type", "created_at")
# The list form leaves the long texts to the detail view and adds the joined fields.
LONG_TEXT = ("description", "notes", "close_reason")
LIST_FIELDS = tuple(name for name in BEAD_FIELDS if name not in LONG_TEXT) + ("change", "ready")
SESSION_FIELDS = ("name", "agent", "requested_model", "reasoning_effort", "selection_tier", "role",
                  "bead_id", "planning_id", "state", "started_at", "ended_at", "exit_reason")
TEST_STAGES = ("changed", "commit", "bead", "full")
TEST_RAN = ("passed", "failed")


# --- the scrubber -----------------------------------------------------------------

# The address pattern is anchored to the start of a run of its own characters, so a long
# run with no `@` is scanned once and not once per start position.
_EMAIL = re.compile(r"(?<![\w.%+\-])[\w.%+\-]+?(?:@|%40)[\w\-]+(?:\.[\w\-]+)*")
_USERINFO = re.compile(r"(?<=://)[^/\s@:]+:[^/\s@]+@")
_STOP = r"[^/\s'\"`<>()\[\]{},;:]"
_HOME = re.compile(rf"(?:(?:/var|/mnt/[A-Za-z])?/(?:home|Users)/{_STOP}+|/root(?![A-Za-z0-9_.-])"
                   rf"|[A-Za-z]:[\\/]+Users[\\/]+[^\\/\s'\"`<>()\[\]{{}},;:]+)")
_TILDE_USER = re.compile(r"(?<![\w/~])~[A-Za-z][\w.\-]*(?=/)")
_PREFIXED = re.compile(
    r"(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_\-]{16,}"
    r"|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|glpat-[A-Za-z0-9_\-]{16,}|AIza[0-9A-Za-z_\-]{30,}"
    r"|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*)")
# `GITHUB_TOKEN=…`, `"password": "…"`, `Authorization: Basic …`: a key word, then a value.
_KEYED = re.compile(r"(?i)(?<![A-Za-z])((?:token|secret|password|passwd|api[_-]?key|authorization|credential)s?\w*[\"']?"
                    r"\s*[:=]\s*[\"']?(?:(?:basic|bearer|token)\s+)?)([A-Za-z0-9_+/=\-]{6,})")
_BEARER = re.compile(r"(?i)\b(bearer\s+)([A-Za-z0-9_+/=.\-]{12,})")
_LONG = re.compile(r"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9_\-])")
_HEX = re.compile(r"[0-9a-fA-F]+")


def _keyed(match):
    # A value with no digit is a word such as "constant-time", not a secret.
    return match.group(0) if not re.search(r"\d", match.group(2)) else f"{match.group(1)}[secret]"


def _long(match):
    value = match.group(0)
    if not (re.search(r"\d", value) and re.search(r"[A-Za-z]", value)):
        return value
    if _HEX.fullmatch(value) and len(value) in (40, 64):
        return value                       # a Git object name, which the evidence notes list
    if value.count("-") >= 4:
        return value                       # a hyphenated name such as a session name
    return "[secret]"


def scrub(text):
    """`text` with e-mail-like and token-like strings and home-directory paths replaced.
    Best effort, and documented as such. None for anything that is not text."""
    if not isinstance(text, str):
        return None
    text = _USERINFO.sub("[secret]@", text)
    text = _EMAIL.sub("[address]", text)
    text = _HOME.sub("~", text)
    text = _TILDE_USER.sub("~", text)
    text = _PREFIXED.sub("[secret]", text)
    text = _KEYED.sub(_keyed, text)
    text = _BEARER.sub(lambda m: f"{m.group(1)}[secret]", text)
    return _LONG.sub(_long, text)


def first_line(text, limit=EXIT_REASON_LIMIT):
    """The scrubbed first non-empty line of `text`, at most `limit` characters, or None.
    The scrub runs before the cut, so a cut never leaves half of an address behind."""
    if not isinstance(text, str):
        return None
    for line in text.splitlines():
        line = line.strip()
        if line:
            return scrub(line[:4 * limit])[:limit] or None
    return None


# --- field types ------------------------------------------------------------------

_FRACTION = re.compile(r"(\.\d{6})\d+")


def utc_iso(value):
    """`value` as a UTC ISO string with seconds, or None when it is no timestamp."""
    if not isinstance(value, str) or not value:
        return None
    text = _FRACTION.sub(r"\1", value.strip())
    text = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    moment = moment.replace(tzinfo=timezone.utc) if moment.tzinfo is None else moment.astimezone(timezone.utc)
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


def _line(value, limit=LINE_LIMIT):
    """A short scrubbed single line, or None."""
    return scrub(value.strip()[:4 * limit])[:limit] if isinstance(value, str) and value.strip() else None


def _count(value):
    return value if type(value) is int and value >= 0 else None


def _bead_id(value):
    return value if isinstance(value, str) and BEAD_ID.fullmatch(value) else None


def allow_dependency(raw):
    if not isinstance(raw, dict):
        return None
    entry = {"issue_id": _bead_id(raw.get("issue_id")), "depends_on_id": _bead_id(raw.get("depends_on_id")),
             "type": _line(raw.get("type"), 32), "created_at": utc_iso(raw.get("created_at"))}
    return entry if entry["issue_id"] and entry["depends_on_id"] else None


def allow_bead(raw):
    """The allow-listed Bead of `raw`, or None for anything that is no Bead."""
    if not isinstance(raw, dict) or not _bead_id(raw.get("id")):
        return None
    labels = raw.get("labels")
    deps = raw.get("dependencies")
    priority = raw.get("priority")
    return {"id": raw["id"],
            "title": scrub(raw["title"]) if isinstance(raw.get("title"), str) else None,
            "status": _line(raw.get("status"), 32),
            "priority": priority if type(priority) is int else None,
            "issue_type": _line(raw.get("issue_type"), 32),
            "labels": sorted({label for label in (_line(item) for item in labels) if label})
            if isinstance(labels, list) else [],
            "description": scrub(raw.get("description")),
            "notes": scrub(raw.get("notes")),
            "close_reason": scrub(raw.get("close_reason")),
            "parent": _bead_id(raw.get("parent")),
            "created_at": utc_iso(raw.get("created_at")),
            "started_at": utc_iso(raw.get("started_at")),
            "closed_at": utc_iso(raw.get("closed_at")),
            "updated_at": utc_iso(raw.get("updated_at")),
            "dependency_count": _count(raw.get("dependency_count")),
            "dependent_count": _count(raw.get("dependent_count")),
            "dependencies": [entry for entry in map(allow_dependency, deps) if entry]
            if isinstance(deps, list) else []}


def allow_session(raw):
    """The allow-listed session of a record, or None for anything that is no session.
    The exit reason is its scrubbed first line; no other free text is carried."""
    if not isinstance(raw, dict) or not _line(raw.get("name")):
        return None
    return {"name": _line(raw["name"]), "agent": _line(raw.get("agent"), 64),
            "requested_model": _line(raw.get("requested_model"), 100),
            "reasoning_effort": _line(raw.get("reasoning_effort"), 32),
            "selection_tier": _line(raw.get("selection_tier"), 32),
            "role": _line(raw.get("role"), 32), "bead_id": _bead_id(raw.get("bead_id")),
            "planning_id": _line(raw.get("planning_id"), 100), "state": _line(raw.get("state"), 32),
            "started_at": utc_iso(raw.get("started_at")), "ended_at": utc_iso(raw.get("ended_at")),
            "exit_reason": first_line(raw.get("exit_reason"))}


def allow_test_record(raw):
    """The five fields of a test record that the dashboard keeps, or None."""
    if not isinstance(raw, dict) or raw.get("stage") not in TEST_STAGES:
        return None
    seconds = raw.get("seconds")
    return {"bead": _bead_id(raw.get("bead")), "stage": raw["stage"], "at": utc_iso(raw.get("at")),
            "seconds": round(float(seconds), 3) if type(seconds) in (int, float) and seconds >= 0 else None,
            "status": _line(raw.get("status"), 16)}


def stage_seconds(records):
    """{bead: {stage: seconds or None}} summed over the runs that ran, like the test report."""
    totals = {}
    for record in records:
        bead, stage = record["bead"], record["stage"]
        if bead is None:
            continue
        stages = totals.setdefault(bead, {name: None for name in TEST_STAGES})
        if record["status"] in TEST_RAN and record["seconds"] is not None:
            stages[stage] = round((stages[stage] or 0.0) + record["seconds"], 3)
    return totals


# --- the Bead list and the change list ---------------------------------------------

def change_of(bead):
    """The value of the Bead's `openspec:change:` label, or None."""
    for label in bead.get("labels") or ():
        if label.startswith(CHANGE_PREFIX) and len(label) > len(CHANGE_PREFIX):
            return label[len(CHANGE_PREFIX):]
    return None


# The label classes of the table filter: a Bead carries a class when one of its labels is
# exactly the name (`discovery`) or starts with it and a colon (`openspec:task:TASK-1`).
LABEL_CLASSES = ("openspec:task", "discovery")


def label_classes(bead):
    """The label classes of the Bead, in `LABEL_CLASSES` order."""
    labels = bead.get("labels") or ()
    return [name for name in LABEL_CLASSES
            if any(label == name or label.startswith(name + ":") for label in labels)]


def _facet(counts, order=None):
    """[{value, count}] of a counter: `order` first, then the rest sorted, None last."""
    known = [value for value in (order or ()) if value in counts]
    rest = sorted((value for value in counts if value not in known and value is not None),
                  key=lambda value: (str(type(value)), value))
    return [{"value": value, "count": counts[value]} for value in known + rest + ([None] if None in counts else [])]


def bead_facets(beads):
    """The filter choices of the table with the number of Beads behind each, over all Beads:
    `status`, `type`, `priority`, `change` and `label`. A Bead without a change counts under
    the value None, so it stays reachable through the filter."""
    counts = {name: {} for name in ("status", "type", "priority", "change", "label")}
    for bead in beads:
        for name, value in (("status", bead.get("status")), ("type", bead.get("issue_type")),
                            ("priority", bead.get("priority")), ("change", change_of(bead))):
            counts[name][value] = counts[name].get(value, 0) + 1
        for name in label_classes(bead):
            counts["label"][name] = counts["label"].get(name, 0) + 1
    return {"status": _facet(counts["status"], STATUS_ORDER), "type": _facet(counts["type"]),
            "priority": _facet(counts["priority"]), "change": _facet(counts["change"]),
            "label": _facet(counts["label"], LABEL_CLASSES)}


def bead_list(snapshot):
    """`data` of /api/v1/beads: every Bead without its long texts, with `change` and `ready`,
    and the `facets` the table filters offer, counted over all Beads."""
    ready = set(snapshot.get("ready") or ())
    rows = []
    for bead in snapshot.get("beads") or ():
        row = {name: bead.get(name) for name in LIST_FIELDS if name not in ("change", "ready")}
        row["change"], row["ready"] = change_of(bead), bead["id"] in ready
        rows.append(row)
    return {"beads": rows, "facets": bead_facets(snapshot.get("beads") or ())}


def change_list(snapshot):
    """`data` of /api/v1/changes: per change the Bead counts by status. Beads without a
    change label form one entry whose `change` is null, so they stay reachable."""
    ready = set(snapshot.get("ready") or ())
    groups, ready_counts = {}, {}
    for bead in snapshot.get("beads") or ():
        change = change_of(bead)
        group = groups.setdefault(change, {name: 0 for name in STATUS_ORDER})
        status = bead.get("status") or "unknown"
        group[status] = group.get(status, 0) + 1
        ready_counts[change] = ready_counts.get(change, 0) + (bead["id"] in ready)
    rows = []
    for change in sorted(groups, key=lambda value: (value is None, value or "")):
        rows.append({"change": change, "total": sum(groups[change].values()), "ready": ready_counts[change],
                     "by_status": groups[change]})
    return {"changes": rows}
