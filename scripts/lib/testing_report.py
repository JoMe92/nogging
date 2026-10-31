"""Test cost as data: what `nogg test report`, `doctor` and the bead view print.

Pure apart from `bead_test_changes`, the one function that runs `git`, and it
takes the runner as an argument. Records are the schema-1 lines of
`testing_runs.py` (design Decision 13): a "run" is a `passed` or `failed` record,
because a `skipped` or `refused` one ran nothing. Nothing here raises on an odd
record; a field that does not read is a record that does not count.
"""
import datetime as dt
import os
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import testing_diff  # noqa: E402
import testing_runs as runs  # noqa: E402
import token_usage_report as usage  # noqa: E402

SCHEMA = "nogg.test.report/v1"
STAGES = ("changed", "commit", "bead", "full")
RAN = ("passed", "failed")
DEFAULT_DAYS = 14
TREND_DAYS = 7
MIN_TREND_RUNS = 3
SLOWEST_LISTED = 10
EPOCH = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)


def when(record):
    """The record's time as an aware datetime, or None."""
    try:
        stamp = dt.datetime.fromisoformat(str(record.get("at")).replace("Z", "+00:00"))
    except ValueError:
        return None
    return stamp if stamp.tzinfo else stamp.replace(tzinfo=dt.timezone.utc)


def seconds_of(record):
    value = record.get("seconds")
    return float(value) if type(value) in (int, float) and value >= 0 else 0.0


def median(values):
    ordered = sorted(values)
    if not ordered:
        return None
    middle = len(ordered) // 2
    return float(ordered[middle]) if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def runs_between(records, start, end, stage=None):
    """Runs that began in [start, end), optionally of one stage."""
    found = []
    for record in records:
        stamp = when(record)
        if (record.get("status") in RAN and stamp is not None and start <= stamp < end
                and (stage is None or record.get("stage") == stage)):
            found.append(record)
    return found


def window_start(now, days):
    """Midnight UTC of the first day of a window that ends with today."""
    today = now.astimezone(dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    return today - dt.timedelta(days=max(days, 1) - 1)


def daily_rows(records, now, days):
    """One row per UTC day and stage with runs: runs, failures, median seconds
    and over-budget runs, oldest day first."""
    start, end = window_start(now, days), now + dt.timedelta(microseconds=1)
    groups = {}
    for record in runs_between(records, start, end):
        key = (when(record).astimezone(dt.timezone.utc).date().isoformat(), record.get("stage") or "?")
        groups.setdefault(key, []).append(record)
    rows = []
    for (day, stage), group in sorted(groups.items(), key=lambda item: (item[0][0], _stage_order(item[0][1]))):
        rows.append({"day": day, "stage": stage, "runs": len(group),
                     "failures": sum(1 for r in group if r["status"] == "failed"),
                     "median_seconds": round(median([seconds_of(r) for r in group]), 1),
                     "over_budget": sum(1 for r in group if r.get("over_budget"))})
    return rows


def _stage_order(stage):
    return STAGES.index(stage) if stage in STAGES else len(STAGES)


def slowest_tests(records, now, days, limit=SLOWEST_LISTED):
    """The slowest tests of the window: the longest time seen per test name."""
    start, end = window_start(now, days), now + dt.timedelta(microseconds=1)
    best = {}
    for record in runs_between(records, start, end):
        for test in record.get("slowest") or []:
            known = best.get(test["name"])
            if known is None or test["seconds"] > known["seconds"]:
                best[test["name"]] = {"name": test["name"], "seconds": test["seconds"],
                                      "stage": record.get("stage"), "at": record.get("at")}
    return sorted(best.values(), key=lambda t: (-t["seconds"], t["name"]))[:limit]


def full_runs(records, now, days):
    """The runs of the full stage in the window, with who asked and why."""
    start, end = window_start(now, days), now + dt.timedelta(microseconds=1)
    return [{"at": r.get("at"), "trigger": r.get("trigger"), "reason": r.get("reason"),
             "status": r.get("status"), "seconds": seconds_of(r), "session": r.get("session"),
             "role": r.get("role"), "bead": r.get("bead")}
            for r in runs_between(records, start, end, "full")]


def week_over_week(records, now):
    """{stage: {...}} for each stage with a run in the last 14 days: the median
    of the last 7 days against the 7 before, and the change in percent. The
    change is None unless both windows hold a run and the earlier median is
    positive; `enough` says whether both windows hold MIN_TREND_RUNS."""
    week = dt.timedelta(days=TREND_DAYS)
    end = now + dt.timedelta(microseconds=1)
    result = {}
    for stage in STAGES:
        current = runs_between(records, now - week, end, stage)
        previous = runs_between(records, now - 2 * week, now - week, stage)
        if not current and not previous:
            continue
        now_median = median([seconds_of(r) for r in current])
        before_median = median([seconds_of(r) for r in previous])
        change = (round((now_median - before_median) / before_median * 100, 1)
                  if now_median is not None and before_median else None)
        result[stage] = {"runs": len(current), "previous_runs": len(previous),
                         "median_seconds": None if now_median is None else round(now_median, 1),
                         "previous_median_seconds": None if before_median is None else round(before_median, 1),
                         "change_percent": change,
                         "enough": len(current) >= MIN_TREND_RUNS and len(previous) >= MIN_TREND_RUNS}
    return result


def _duration(seconds):
    return f"{seconds:.0f} s"


def doctor_notes(records, now, threshold):
    """The NOTE lines `doctor` prints, none of which changes its exit code: a
    stage whose 7-day median grew by `threshold` percent over the 7 days
    before (each window with at least three runs), a stage whose latest run was
    over budget, and a Lead session's `--allow-full` in the last 7 days."""
    notes = []
    for stage, row in week_over_week(records, now).items():
        change = row["change_percent"]
        if row["enough"] and change is not None and change > threshold:
            notes.append(f"test trend: the {stage} stage's median rose {change:.0f}% week over week, from "
                         f"{_duration(row['previous_median_seconds'])} to {_duration(row['median_seconds'])} "
                         f"({row['previous_runs']} and {row['runs']} runs; testing.trend_threshold_percent "
                         f"{threshold:g})")
    for stage in STAGES:
        latest = max(runs_between(records, EPOCH, now + dt.timedelta(microseconds=1), stage),
                     key=when, default=None)
        if latest is not None and latest.get("over_budget"):
            budget = latest.get("budget_seconds")
            notes.append(f"test budget: the latest {stage} run took {_duration(seconds_of(latest))}"
                         + (f", over its {_duration(budget)} budget" if budget is not None else ", over budget")
                         + f" ({latest.get('at')})")
    week_ago = now - dt.timedelta(days=TREND_DAYS)
    leads = [r for r in runs_between(records, week_ago, now + dt.timedelta(microseconds=1), "full")
             if r.get("trigger") == "allow-full" and r.get("role") == "lead"]
    if leads:
        sessions = sorted({r.get("session") or "unnamed" for r in leads})
        notes.append(f"test full: {len(leads)} --allow-full run{'s' if len(leads) != 1 else ''} from a Lead "
                     f"session in the last 7 days ({', '.join(sessions)}); the exception is recorded with its reason")
    return notes


def stage_seconds(records, beads):
    """{bead: {stage: seconds or None}} summed over every run of the Bead; None
    for a stage the Bead never ran."""
    beads = set(beads)
    totals = {b: {stage: None for stage in STAGES} for b in beads}
    for record in records:
        bead, stage = record.get("bead"), record.get("stage")
        if bead in beads and stage in STAGES and record.get("status") in RAN:
            totals[bead][stage] = round((totals[bead][stage] or 0.0) + seconds_of(record), 3)
    return totals


def line_counts(numstat_text):
    """{production, test, generated} added plus deleted lines of `git diff
    --numstat` text, classified like the Bead view; a binary file counts 0."""
    counts = {"production": 0, "test": 0, "generated": 0}
    for entry in numstat_text.splitlines():
        parts = entry.split("\t", 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            counts[usage.classify_path(usage.numstat_path(parts[2]))] += int(parts[0]) + int(parts[1])
    return counts


def budget_message(bead, counts, limits):
    """None when `counts["test"]` is inside `limits` (min, max), or one line
    naming the count and the budget. Below the minimum only matters for a Bead
    that changes production code: a documentation Bead needs no test line."""
    low, high = limits
    tests = counts["test"]
    who = f"Bead {bead}: " if bead else ""
    if tests > high:
        return f"{who}{tests} test lines, above the task_sizing.bead_test_lines maximum of {high}"
    if tests < low and counts["production"] > 0:
        return (f"{who}{tests} test lines for {counts['production']} production lines, "
                f"below the task_sizing.bead_test_lines minimum of {low}")
    return None


def bead_findings(lines, limits):
    """Budget messages for {bead: {commits, production_lines, test_lines}}."""
    found = []
    for bead in sorted(lines or {}):
        row = lines[bead]
        if not row.get("commits"):
            continue
        message = budget_message(bead, {"test": row["test_lines"], "production": row["production_lines"]}, limits)
        if message:
            found.append({"bead": bead, "test_lines": row["test_lines"],
                          "production_lines": row["production_lines"], "message": message})
    return found


DISCOVERY_LABEL = "discovery"


def parse_trailer_log(text):
    """[(sha, subject, reason)] of the commits in `git log --format=%H%x1f%s%x1f
    %(trailers:key=Test-Integrity,valueonly,unfold)%x1e` text that carry a
    non-empty Test-Integrity reason."""
    commits = []
    for chunk in text.split("\x1e"):
        sha, _, rest = chunk.strip("\n").partition("\x1f")
        subject, _, reason = rest.partition("\x1f")
        if sha.strip() and reason.strip():
            commits.append((sha.strip(), subject, reason.strip()))
    return commits


def discovery_gaps(commits, labels_of):
    """One line per Bead whose commit justifies a weakened test with a
    `Test-Integrity:` trailer but whose Bead has no `discovery` label, so the
    note the rule also asks for does not exist (design Decision 10).

    labels_of(bead) -> a set of labels, or None where the tracker is not
    reachable; an unreachable tracker or a subject naming no Bead is no gap."""
    gaps, seen = [], set()
    for sha, subject, reason in commits:
        match = runs.BEAD_TOKEN_RE.search(subject)
        if not match or match.group(1) in seen:
            continue
        bead = match.group(1)
        labels = labels_of(bead)
        if labels is None:
            continue
        seen.add(bead)
        if DISCOVERY_LABEL not in labels:
            gaps.append(f"FLAGGED: commit {sha[:9]} justifies a weakened test (Test-Integrity: {reason}) but Bead "
                        f"{bead} has no `{DISCOVERY_LABEL}` label; record the reason with "
                        f"`bd update {bead} --add-label {DISCOVERY_LABEL} --append-notes \"<why>\"`")
    return gaps


def build_report(records, now, days, beads=()):
    """The `nogg test report --json` document."""
    start = window_start(now, days)
    return {"schema": SCHEMA, "as_of": now.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat(),
            "days": days, "window_from": start.date().isoformat(), "records": len(records),
            "daily": daily_rows(records, now, days), "slowest": slowest_tests(records, now, days),
            "full_runs": full_runs(records, now, days), "week_over_week": week_over_week(records, now),
            "beads": list(beads)}


def render_report(doc):
    """The text of `nogg test report`."""
    if not doc["records"]:
        return ["no test runs recorded yet: they appear after the first `nogg test` run"]
    lines = [f"test runs, last {doc['days']} day{'s' if doc['days'] != 1 else ''} (UTC, from {doc['window_from']})"]
    if not doc["daily"]:
        lines.append("  no runs in this window")
    else:
        lines.append(f"  {'DAY':<10}  {'STAGE':<7}  {'RUNS':>4}  {'FAILED':>6}  {'MEDIAN_S':>8}  {'OVER_BUDGET':>11}")
        for row in doc["daily"]:
            lines.append(f"  {row['day']:<10}  {row['stage']:<7}  {row['runs']:>4}  {row['failures']:>6}  "
                         f"{row['median_seconds']:>8.1f}  {row['over_budget']:>11}")
    if doc["week_over_week"]:
        lines.append("week over week (median seconds, last 7 days against the 7 before)")
        for stage, row in doc["week_over_week"].items():
            change = "n/a" if row["change_percent"] is None else f"{row['change_percent']:+.0f}%"
            before = "-" if row["previous_median_seconds"] is None else f"{row['previous_median_seconds']:.1f}"
            now = "-" if row["median_seconds"] is None else f"{row['median_seconds']:.1f}"
            few = "" if row["enough"] else f"  (fewer than {MIN_TREND_RUNS} runs in a window: no trend)"
            lines.append(f"  {stage:<7}  {before} -> {now}  {change}  ({row['previous_runs']} and {row['runs']} runs){few}")
    if doc["slowest"]:
        lines.append("slowest tests")
        lines.extend(f"  {t['seconds']:>7.1f} s  {t['name']}  ({t['stage']})" for t in doc["slowest"])
    if doc["full_runs"]:
        lines.append("full runs")
        for run in doc["full_runs"]:
            who = run["session"] or run["role"] or "operator shell"
            why = f": {run['reason']}" if run["reason"] else ""
            lines.append(f"  {run['at']}  {run['trigger']}  {run['status']}  {run['seconds']:.0f} s  {who}{why}")
    if doc["beads"]:
        lines.append("Beads outside task_sizing.bead_test_lines")
        lines.extend(f"  {b['message']}" for b in doc["beads"])
    return lines


def bead_test_changes(repo, beads, timeout=60, run=subprocess.run):
    """{bead: {tests_added, tests_deleted, skips_added}} from the diff of each
    Bead's `[<bead>]` commits, analysed as one range by testing_diff, so a test
    moved between two of its commits counts as neither. None when git cannot
    answer. A Bead without commits is absent."""
    beads = {b for b in beads if b}
    if not beads:
        return {}
    git = usage._git_runner(repo, timeout, run)
    wanted = usage.bead_commit_map(git, beads)
    if wanted is None:
        return None
    shas = {b: [sha for sha, tokens in wanted.items() if b in tokens] for b in beads}
    out = {}
    for bead, group in shas.items():
        if not group:
            continue
        text = git("log", "--no-walk=unsorted", "--stdin", "-M", "-U5", "-p", "--no-color", "--no-ext-diff",
                   "--no-merges", "--format=", stdin="\n".join(group) + "\n")
        if text is None:
            return None
        result = testing_diff.analyse(text)
        out[bead] = {"tests_added": len(result.tests_added) - len(result.tests_moved),
                     "tests_deleted": len(result.tests_deleted), "skips_added": len(result.skips_added)}
    return out
