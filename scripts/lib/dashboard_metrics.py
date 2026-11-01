"""Pure start-page statistics of `nogg dashboard` (design Decision 10): Bead counts by status,
closed Beads over time and by change, cycle and lead time, project age and the activity series
(panels 1 to 6), then agent-hours, agents with models and tiers, tokens, commits and lines, and
test cost (panels 7 to 11).

Every function takes plain snapshots, the reader snapshots of the data contract, and returns
plain data. A missing snapshot (`None`: the source is absent, loading or unavailable) is read
as absent, and a block built from it says so. No block ever turns missing data into a zero: a
period before a source's first record is a gap (`None`), and a statistic with nothing to
average has no value (`None`).

Definitions the docs repeat:

* Cycle time is `closed_at - started_at` and lead time is `closed_at - created_at`, for
  closed Beads. A closed Bead with no `started_at` is excluded from the cycle time and
  counted. A negative duration (a clock that ran backwards) is excluded and counted.
* The median of an even number of values is the mean of the two middle ones. The p90 is the
  nearest rank: the value at position ceil(0.9 * n) of the sorted values.
* Days are UTC days, the unit the chart buckets use.
* Reopened Beads are not visible: the list holds the latest close only.
* Agent-hours are the sum of `ended_at - started_at` of finished sessions, counted on the UTC
  day a session started. Parallel sessions add up, so the sum is never elapsed time. The
  orchestrator's hours are reported apart, a session with no `ended_at` is "running" and adds
  nothing, and a session that ends before it starts is excluded and counted.
* Tokens are `fresh_input + output` of the known counters only. A sum with an unknown counter
  is flagged (`unknown`), never completed; no cost, no quota share and no provider total.
* Commits are those whose subject carries a Bead token; the others are one count.
* Test cost sums the seconds of the `nogg test` runs that ran (passed or failed) per stage.
"""
from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs

import dashboard_model as model

STATUSES = ("open", "in_progress", "blocked", "closed", "deferred")
RANGES = {"7d": 7, "30d": 30, "90d": 90, "all": None}
DEFAULT_RANGE = "30d"
TOP_CHANGES = 10
# Upper edges, in seconds, of the cycle and lead time histogram, with their labels. The last
# bin has no upper edge.
BINS = ((3600, "< 1 h"), (4 * 3600, "1-4 h"), (12 * 3600, "4-12 h"), (86400, "12-24 h"),
        (3 * 86400, "1-3 d"), (7 * 86400, "3-7 d"), (14 * 86400, "7-14 d"), (None, "14 d +"))
ACTIVITY = ("created", "closed", "commits", "sessions", "tests")
ORCHESTRATOR = "orchestrator"
TOP_MODELS = 10


def parse(value):
    """A UTC datetime of an ISO string, or None for anything that is no timestamp."""
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith(("Z", "z")) else value
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    return moment.replace(tzinfo=timezone.utc) if moment.tzinfo is None else moment.astimezone(timezone.utc)


def stamp(moment):
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z") if moment else None


def day_of(moment):
    return moment.astimezone(timezone.utc).date()


# --- statistics ---------------------------------------------------------------------

def median(values):
    """The median, or None for no values (never 0)."""
    ordered = sorted(values)
    if not ordered:
        return None
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def percentile(values, share):
    """The nearest-rank percentile (`share` between 0 and 1), or None for no values."""
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[max(1, math.ceil(share * len(ordered))) - 1]


def histogram(durations):
    """[{label, upper, count}] over the fixed bins; every bin is listed so a bar of 0 means
    "no Bead in this bin" when there are durations, and the block is empty when there are none."""
    counts = [0] * len(BINS)
    for seconds in durations:
        for index, (upper, _) in enumerate(BINS):
            if upper is None or seconds < upper:
                counts[index] += 1
                break
    return [{"label": label, "upper": upper, "count": counts[index]} for index, (upper, label) in enumerate(BINS)]


def duration_block(beads, start_field, window_start):
    """Median, p90 and a histogram of `closed_at - <start_field>` for the closed Beads that
    closed in the window, and the count of Beads left out and why."""
    durations, missing, backwards = [], 0, 0
    for bead in beads:
        if bead.get("status") != "closed":
            continue
        end = parse(bead.get("closed_at"))
        if end is None or (window_start and end < window_start):
            continue
        start = parse(bead.get(start_field))
        if start is None:
            missing += 1
        elif end < start:
            backwards += 1
        else:
            durations.append((end - start).total_seconds())
    block = {"state": "ready" if durations else "empty", "count": len(durations),
             "excluded": {"no_start": missing, "backwards": backwards},
             "median_seconds": median(durations), "p90_seconds": percentile(durations, 0.9),
             "bins": histogram(durations) if durations else []}
    return block


# --- blocks -------------------------------------------------------------------------

def status_block(beads):
    """Open, in progress, blocked, closed and deferred counts, matching `bd`. A status the
    dashboard does not know is counted apart and not added to a known one."""
    if beads is None:
        return {"state": "absent"}
    counts = {name: 0 for name in STATUSES}
    other = 0
    for bead in beads["beads"]:
        status = bead.get("status")
        if status in counts:
            counts[status] += 1
        else:
            other += 1
    return {"state": "ready" if beads["beads"] else "empty", "counts": counts, "other": other,
            "total": len(beads["beads"]), "ready": len(beads.get("ready") or ())}


def project_block(beads, git, now):
    """The root commit date, the first Bead date and the age in days. The age counts from the
    root commit, and from the first Bead only when Git has no root commit."""
    first_bead = min((moment for moment in (parse(bead.get("created_at")) for bead in beads["beads"]) if moment),
                     default=None) if beads else None
    root = parse((git or {}).get("root_commit_at"))
    basis = "root_commit" if root else "first_bead" if first_bead else None
    since = root or first_bead
    if since is None:
        return {"state": "absent", "root_commit_at": None, "first_bead_at": None, "age_days": None, "basis": None}
    return {"state": "ready", "root_commit_at": stamp(root), "first_bead_at": stamp(first_bead),
            "age_days": max(0, (day_of(now) - day_of(since)).days), "basis": basis}


def closed_events(beads, window_start):
    closed = [bead for bead in beads["beads"] if bead.get("status") == "closed"]
    events, untimed = [], 0
    for bead in closed:
        moment = parse(bead.get("closed_at"))
        if moment is None:
            untimed += 1
        elif window_start is None or moment >= window_start:
            events.append({"at": stamp(moment), "change": change_of(bead)})
    events.sort(key=lambda event: event["at"])
    return events, untimed


def change_of(bead):
    for label in bead.get("labels") or ():
        if label.startswith("openspec:change:") and len(label) > len("openspec:change:"):
            return label[len("openspec:change:"):]
    return None


def closed_block(beads, window_start, first_bead, now):
    """Closed Beads in the window as raw timestamps; the browser buckets them by day or week.
    `floor` is the first Bead date: before it there is no data, and the chart shows a gap."""
    if beads is None:
        return {"state": "absent"}
    events, untimed = closed_events(beads, window_start)
    return {"state": "ready" if events else "empty", "events": events, "without_time": untimed,
            "floor": stamp(first_bead), "since": stamp(window_start), "until": stamp(now)}


def by_change_block(events, beads_present):
    """Closed Beads by change: the top ten, the rest as one "other" entry, and the Beads
    with no change label as `change: null`."""
    if not beads_present:
        return {"state": "absent"}
    counts = {}
    for event in events:
        counts[event["change"]] = counts.get(event["change"], 0) + 1
    named = sorted(((change, count) for change, count in counts.items() if change is not None),
                   key=lambda item: (-item[1], item[0]))
    top, rest = named[:TOP_CHANGES], named[TOP_CHANGES:]
    rows = [{"change": change, "closed": count} for change, count in top]
    if None in counts:
        rows.append({"change": None, "closed": counts[None]})
    return {"state": "ready" if rows or rest else "empty", "rows": rows,
            "other": {"changes": len(rest), "closed": sum(count for _, count in rest)} if rest else None}


def daily(counts, floor, first_day, last_day):
    """The value of each day from `first_day` to `last_day` (dates, inclusive) as a list of
    {day, value}. A day before `floor` (a date; the first day the source has records) has
    `value: None`, a gap, and never 0. A day from the floor on with no record has 0, because
    the source covers it. A source with no floor is a gap over the whole span."""
    rows, day = [], first_day
    while day <= last_day:
        rows.append({"day": day.isoformat(),
                     "value": None if floor is None or day < floor else counts.get(day.isoformat(), 0)})
        day += timedelta(days=1)
    return rows


def _tally(moments):
    counts = {}
    for moment in moments:
        if moment is not None:
            key = day_of(moment).isoformat()
            counts[key] = counts.get(key, 0) + 1
    return counts


def _floor_of(moments, declared=None):
    values = [moment for moment in [*moments, parse(declared)] if moment is not None]
    return day_of(min(values)) if values else None


def activity_sources(snapshots):
    """{series: (day counts, floor day or None)} for the series with a source. A source that
    is absent has no entry, so the page says "not available here" for it."""
    sources = {}
    beads = snapshots.get("beads")
    if beads is not None:
        created = [parse(bead.get("created_at")) for bead in beads["beads"]]
        closed = [parse(bead.get("closed_at")) for bead in beads["beads"] if bead.get("status") == "closed"]
        floor = _floor_of(created)
        sources["created"] = (_tally(created), floor)
        sources["closed"] = (_tally(closed), floor)
    git = snapshots.get("git")
    if git is not None:
        commits = [parse(commit.get("at")) for commit in git.get("commits") or ()]
        sources["commits"] = (_tally(commits), _floor_of(commits, git.get("floor")))
    sessions = snapshots.get("sessions")
    if sessions is not None:
        starts = [parse(item.get("started_at")) for item in sessions["sessions"]]
        sources["sessions"] = (_tally(starts), _floor_of(starts, sessions.get("floor")))
    tests = snapshots.get("tests")
    if tests is not None:
        runs = [parse(item.get("at")) for item in tests["records"]]
        sources["tests"] = (_tally(runs), _floor_of(runs, tests.get("floor")))
    return sources


def activity_block(snapshots, window_start, now):
    """The activity timeline: one daily series per source over the window, each with its
    own floor. A series whose source is absent is listed as absent."""
    sources = activity_sources(snapshots)
    floors = [floor for _, floor in sources.values() if floor]
    last = day_of(now)
    if not floors:
        return {"state": "absent" if not sources else "empty", "days": [], "series": {
            name: {"state": "absent"} for name in ACTIVITY if name not in sources}}
    first = max(day_of(window_start), min(floors)) if window_start else min(floors)
    first = min(first, last)
    series = {}
    for name in ACTIVITY:
        if name not in sources:
            series[name] = {"state": "absent"}
            continue
        counts, floor = sources[name]
        series[name] = {"state": "ready" if floor else "empty", "floor": floor.isoformat() if floor else None,
                        "values": [row["value"] for row in daily(counts, floor, first, last)]}
    days = [(first + timedelta(days=offset)).isoformat() for offset in range((last - first).days + 1)]
    return {"state": "ready", "days": days, "series": series}


# --- panels 7 to 11: usage ------------------------------------------------------------

def _rounded(value, places=2):
    return None if value is None else round(value, places)


def _span(floor, window, now):
    """(first, last) day of a series: the window's first day, or the series' floor for the whole
    history, to today. A window that opens before the floor keeps its early days, whose values
    are gaps, so the chart says where the records begin instead of starting late."""
    last = day_of(now)
    first = day_of(window) if window else floor
    return min(first or last, last), last


def agent_hours_block(sessions, window, now):
    """Panel 7. Agent-hours of finished sessions per UTC start day, the orchestrator's hours
    and the running sessions apart. Sessions are records of this host only."""
    if sessions is None:
        return {"state": "absent"}
    records = sessions["sessions"]
    floor = _floor_of([parse(item.get("started_at")) for item in records], sessions.get("floor"))
    hours, orchestrator_hours, per_day = 0.0, 0.0, {}
    counted = {"agents": 0, "orchestrator": 0}
    planning, untimed, backwards = 0, 0, 0
    running = {"agents": 0, "orchestrator": 0}
    for item in records:
        kind = "orchestrator" if item.get("role") == ORCHESTRATOR else "agents"
        started, ended = parse(item.get("started_at")), parse(item.get("ended_at"))
        if started is None:
            untimed += 1
            continue
        if ended is None:
            running[kind] += 1                      # present tense: a running session is not in the window
            continue
        if window and started < window:
            continue
        if ended < started:
            backwards += 1
            continue
        seconds = (ended - started).total_seconds()
        counted[kind] += 1
        if kind == "orchestrator":
            orchestrator_hours += seconds / 3600
            continue
        hours += seconds / 3600
        key = day_of(started).isoformat()
        per_day[key] = per_day.get(key, 0.0) + seconds / 3600
        if item.get("bead_id") is None and (item.get("planning_id") or item.get("role") == "planning"):
            planning += 1
    first, last = _span(floor, window, now)
    rows = daily(per_day, floor, first, last) if floor else []
    return {"state": "ready" if records else "empty", "floor": floor.isoformat() if floor else None,
            "hours": _rounded(hours), "sessions": counted["agents"], "planning_sessions": planning,
            "orchestrator": {"hours": _rounded(orchestrator_hours), "sessions": counted["orchestrator"],
                             "running": running["orchestrator"]},
            "running": running["agents"], "excluded": {"untimed": untimed, "backwards": backwards},
            "days": [row["day"] for row in rows], "values": [_rounded(row["value"]) for row in rows]}


def agents_block(sessions, tokens, window):
    """Panel 8. Per agent: sessions, hours, the models that were REQUESTED (from the session
    records) and the selection tiers; apart, the models that were OBSERVED (from usage), whole
    history, with their known tokens. The two are never merged into one list."""
    requested = {"state": "absent"}
    if sessions is not None:
        agents = {}
        for item in sessions["sessions"]:
            started, ended = parse(item.get("started_at")), parse(item.get("ended_at"))
            if started is None or (window and started < window and ended is not None):
                continue
            row = agents.setdefault(item.get("agent"), {"agent": item.get("agent"), "sessions": 0, "running": 0,
                                                       "hours": 0.0, "orchestrator_sessions": 0,
                                                       "models": {}, "tiers": {}})
            row["sessions"] += 1
            orchestrator = item.get("role") == ORCHESTRATOR
            row["orchestrator_sessions"] += orchestrator
            if ended is None:
                row["running"] += 1
            elif ended >= started and not orchestrator:
                row["hours"] += (ended - started).total_seconds() / 3600
            for field, bucket in (("requested_model", "models"), ("selection_tier", "tiers")):
                row[bucket][item.get(field)] = row[bucket].get(item.get(field), 0) + 1
        rows = [{**row, "hours": _rounded(row["hours"]),
                 "models": _counted(row["models"], "model"), "tiers": _counted(row["tiers"], "tier")}
                for row in sorted(agents.values(), key=lambda r: (-r["sessions"], str(r["agent"])))]
        requested = {"state": "ready" if rows else "empty", "rows": rows}
    observed = {"state": "absent"}
    if tokens is not None:
        rows = []
        for name, work in (tokens.get("by_model") or {}).items():
            known, unknown = _known(work)
            rows.append({"model": name, "known": known, "unknown": unknown})
        rows.sort(key=lambda r: (-r["known"], r["model"]))
        observed = {"state": "ready" if rows else "empty", "rows": rows[:TOP_MODELS],
                    "other": {"models": len(rows) - TOP_MODELS, "known": sum(r["known"] for r in rows[TOP_MODELS:])}
                    if len(rows) > TOP_MODELS else None, "scope": "all"}
    states = (requested["state"], observed["state"])
    return {"state": "absent" if states == ("absent", "absent") else "ready", "requested": requested,
            "observed": observed}


def _counted(counts, name):
    return [{name: key, "sessions": count}
            for key, count in sorted(counts.items(), key=lambda item: (-item[1], str(item[0])))]


def _known(work):
    """(known tokens, has unknown) of a `work`: fresh input plus output, never the provider
    total. A counter nobody could prove marks the sum, it is not counted as zero."""
    tokens, unknown = work.get("tokens") or {}, work.get("unknown_counters") or {}
    known = (tokens.get("fresh_input_tokens") or 0) + (tokens.get("output_tokens") or 0)
    return known, bool(unknown.get("fresh_input_tokens") or unknown.get("output_tokens"))


def tokens_block(tokens, window, now):
    """Panel 9. Known tokens (`fresh_input + output`) per UTC day and runtime. Each runtime
    starts at its own floor, so an earlier day is a gap; an unknown counter flags the day and
    the sums; runtimes with partial data are named. No cost and no quota share."""
    if tokens is None:
        return {"state": "absent"}
    floors = {name: parse(value) for name, value in (tokens.get("floors") or {}).items()}
    floors = {name: day_of(moment) for name, moment in floors.items() if moment}
    by_day = tokens.get("by_day") or {}
    partial = sorted(set(tokens.get("partial") or ()))
    names = sorted(set(floors) | set(partial) | {name for day in by_day.values() for name in day})
    result = {"partial": partial, "pending_batches": tokens.get("pending_batches") or 0}
    if not floors:
        return {"state": "empty", "runtimes": [], "days": [], **result, "headline": None, "floor": None}
    earliest = min(floors.values())
    first, last = _span(earliest, window, now)
    start_text, runtimes = first.isoformat(), []
    total_known = total_fresh = total_output = 0
    total_unknown, covered = False, False
    for name in names:
        floor, counts, flagged, fresh, output = floors.get(name), {}, [], 0, 0
        for day, per_runtime in by_day.items():
            work = per_runtime.get(name)
            if work is None or day < start_text:
                continue
            known, unknown = _known(work)
            counts[day] = known
            fresh += work["tokens"].get("fresh_input_tokens") or 0
            output += work["tokens"].get("output_tokens") or 0
            if unknown:
                flagged.append(day)
        rows = daily(counts, floor, first, last) if floor else [
            {"day": day, "value": None} for day in (d["day"] for d in daily({}, None, first, last))]
        has_days = bool(floor and floor <= last)
        known_sum = sum(counts.values())
        covered = covered or has_days
        total_known += known_sum
        total_fresh += fresh
        total_output += output
        total_unknown = total_unknown or bool(flagged)
        runtimes.append({"runtime": name, "floor": floor.isoformat() if floor else None,
                         "known": known_sum if has_days else None, "fresh_input": fresh, "output": output,
                         "unknown": bool(flagged), "unknown_days": sorted(flagged), "partial": name in partial,
                         "values": [row["value"] for row in rows]})
    return {"state": "ready", "floor": earliest.isoformat(), "days": [row["day"] for row in daily({}, None, first, last)],
            "runtimes": runtimes, **result,
            "headline": {"known": total_known if covered else None, "unknown": total_unknown,
                         "fresh_input": total_fresh, "output": total_output}}


def commits_block(git, window, now):
    """Panel 10. Commits carrying a Bead token with their production and test lines per UTC
    day; the commits with no token are one count. Commits may include unmerged work."""
    if git is None:
        return {"state": "absent"}
    commits = git.get("commits") or ()
    moments = [parse(commit.get("at")) for commit in commits]
    floor = _floor_of(moments, git.get("floor"))
    base = {"tokenless_commits": git.get("tokenless_commits") or 0}
    if floor is None:
        return {"state": "empty", **base, "floor": None, "days": [], "commits": [], "production": [], "test": [],
                "totals": None}
    commits_by, production, test, totals, unknown = {}, {}, {}, {"commits": 0, "production_lines": 0, "test_lines": 0}, 0
    for commit, moment in zip(commits, moments):
        if moment is None or (window and moment < window):
            continue
        day = day_of(moment).isoformat()
        commits_by[day] = commits_by.get(day, 0) + 1
        totals["commits"] += 1
        lines = (commit.get("production_lines"), commit.get("test_lines"))
        if not all(type(value) is int and value >= 0 for value in lines):
            unknown += 1
            continue
        production[day] = production.get(day, 0) + lines[0]
        test[day] = test.get(day, 0) + lines[1]
        totals["production_lines"] += lines[0]
        totals["test_lines"] += lines[1]
    first, last = _span(floor, window, now)
    series = {name: [row["value"] for row in daily(counts, floor, first, last)]
              for name, counts in (("commits", commits_by), ("production", production), ("test", test))}
    return {"state": "ready", **base, "floor": floor.isoformat(), "totals": {**totals, "lines_unknown": unknown},
            "days": [row["day"] for row in daily({}, floor, first, last)], **series}


def test_cost_block(tests, window, now):
    """Panel 11. Seconds spent in `nogg test` runs per stage and per UTC day, from the
    retained run records. Rotation moves the floor, so it reads "records kept from"."""
    if tests is None:
        return {"state": "absent"}
    records = tests["records"]
    floor = _floor_of([parse(item.get("at")) for item in records], tests.get("floor"))
    stages = {name: {"runs": 0, "failed": 0, "seconds": 0.0, "durations": [], "per_day": {}} for name in model.TEST_STAGES}
    untimed = not_run = 0
    for item in records:
        moment = parse(item.get("at"))
        if moment is None:
            untimed += 1
            continue
        if window and moment < window:
            continue
        seconds = item.get("seconds")
        if item.get("status") not in model.TEST_RAN or seconds is None:
            not_run += 1
            continue
        stage = stages[item["stage"]]
        stage["runs"] += 1
        stage["failed"] += item["status"] == "failed"
        stage["seconds"] += seconds
        stage["durations"].append(seconds)
        key = day_of(moment).isoformat()
        stage["per_day"][key] = stage["per_day"].get(key, 0.0) + seconds
    first, last = _span(floor, window, now)
    rows = {name: [_rounded(row["value"], 1) for row in daily(stage["per_day"], floor, first, last)]
            for name, stage in stages.items()}
    return {"state": "ready" if floor else "empty", "floor": floor.isoformat() if floor else None,
            "excluded": {"not_run": not_run, "untimed": untimed},
            "days": [row["day"] for row in daily({}, floor, first, last)] if floor else [],
            "stages": [{"stage": name, "runs": stage["runs"], "failed": stage["failed"],
                        "seconds": _rounded(stage["seconds"], 1) if stage["runs"] else None,
                        "median_seconds": _rounded(median(stage["durations"]), 1), "values": rows[name]}
                       for name, stage in stages.items()]}


def usage_view(snapshots, window, now):
    return {"agent_hours": agent_hours_block(snapshots["sessions"], window, now),
            "agents": agents_block(snapshots["sessions"], snapshots["tokens"], window),
            "tokens": tokens_block(snapshots["tokens"], window, now),
            "commits": commits_block(snapshots["git"], window, now),
            "test_cost": test_cost_block(snapshots["tests"], window, now)}


# --- the view -----------------------------------------------------------------------

def window_start(range_name, now):
    """The first instant of the window, or None for the whole history."""
    days = RANGES[range_name]
    return None if days is None else datetime.combine(day_of(now) - timedelta(days=days - 1),
                                                      datetime.min.time(), timezone.utc)


def parse_range(query):
    """The range of a /api/v1/summary query: absent means the default, anything else that is
    not one of the four ranges, or a repeated or extra field, is a ValueError."""
    fields = parse_qs(query, keep_blank_values=True, max_num_fields=4)
    if set(fields) - {"range"} or any(len(values) > 1 for values in fields.values()):
        raise ValueError("unknown or repeated field")
    name = fields.get("range", [DEFAULT_RANGE])[0]
    if name not in RANGES:
        raise ValueError("unknown range")
    return name


def summary_view(snapshots, now=None, range_name=DEFAULT_RANGE):
    """`data` of /api/v1/summary: panels 1 to 11 of the start page. `snapshots` maps a source
    name to its reader snapshot; a name that is missing or None is an absent source."""
    if range_name not in RANGES:
        raise ValueError(f"unknown range: {range_name}")
    now = now or datetime.now(timezone.utc)
    snapshots = {name: snapshots.get(name) for name in ("beads", "sessions", "tests", "git", "tokens")}
    beads = snapshots["beads"]
    start = window_start(range_name, now)
    project = project_block(beads, snapshots["git"], now)
    first_bead = parse(project["first_bead_at"])
    closed = closed_block(beads, start, first_bead, now)
    absent = {"state": "absent"}
    return {"range": range_name, "since": stamp(start), "until": stamp(now),
            "status": status_block(beads), "project": project, "closed": closed,
            "by_change": by_change_block(closed.get("events", []), beads is not None),
            "cycle": duration_block(beads["beads"], "started_at", start) if beads else absent,
            "lead": duration_block(beads["beads"], "created_at", start) if beads else absent,
            "activity": activity_block(snapshots, start, now), **usage_view(snapshots, start, now)}
