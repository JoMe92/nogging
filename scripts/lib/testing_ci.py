"""The CI reality check of `doctor` (test-policy-and-test-control, Decision 11): does the
integration branch's CI really run tests? Pure: the caller passes captured `gh` output
through `run_gh`, a clock and the cache, and this module decides. No file, no subprocess."""
import json
import re

RAN, NONE, STALE, ABSENT, UNKNOWN = "ran", "none", "stale", "absent", "unknown"
MAX_CANDIDATES = 3
LIST_LIMIT = 30
REFRESH_SECONDS = 10
NOT_A_TEST_CONCLUSION = ("skipped", "cancelled")
FALLBACK = "the nightly fallback (docs/test-control.md)"


def _stamp(text):
    """An ISO-8601 time as epoch seconds, or None."""
    from datetime import datetime
    try:
        return datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def candidates(runs, branch, now):
    """Runs on `branch`, or pull_request runs, newest first, as (id, created epoch)."""
    found = []
    for run in runs if isinstance(runs, list) else []:
        if not isinstance(run, dict) or run.get("databaseId") is None:
            continue
        created = _stamp(run.get("createdAt"))
        if created is None or created > now + 86400:
            continue
        if run.get("headBranch") == branch or run.get("event") == "pull_request":
            found.append((run["databaseId"], created))
    return sorted(found, key=lambda item: -item[1])


def has_test_job(jobs, pattern):
    """A job whose name matches `pattern` and whose conclusion is not skipped or cancelled.
    A failed job counts: it proves the tests ran."""
    try:
        regex = re.compile(pattern, re.IGNORECASE)
    except re.error:
        return False
    return any(isinstance(job, dict) and regex.search(str(job.get("name", "")))
               and job.get("conclusion") not in NOT_A_TEST_CONCLUSION for job in jobs or [])


def classify(runs, jobs_of, ci, now):
    """`ran`, `stale` or `none` from the run list; `jobs_of(run_id)` returns the jobs of a
    run or None. Runs inside the window are inspected first; only when none exists are
    older ones, to tell `stale` from `none`. Raises LookupError when `jobs_of` fails."""
    window = ci["max_age_days"] * 86400
    found = candidates(runs, ci["branch"], now)
    recent = [item for item in found if now - item[1] <= window]
    for run_id, created in (recent or found)[:MAX_CANDIDATES]:
        jobs = jobs_of(run_id)
        if jobs is None:
            raise LookupError(run_id)
        if has_test_job(jobs, ci["job_pattern"]):
            return {"result": RAN if recent else STALE, "last_test_at": created}
    return {"result": NONE, "last_test_at": None}


def parse_json(text):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def refresh(ci, run_gh, now):
    """One refresh through `run_gh(argv)`, which returns stdout, or None on any failure
    (no gh, not authenticated, offline, timeout). The result is `unknown` on a failure."""
    out = run_gh(["run", "list", "--limit", str(LIST_LIMIT), "--json",
                  "databaseId,headBranch,event,createdAt,conclusion"])
    runs = parse_json(out) if out is not None else None
    if not isinstance(runs, list):
        return {"result": UNKNOWN, "last_test_at": None}

    def jobs_of(run_id):
        payload = parse_json(run_gh(["run", "view", str(run_id), "--json", "jobs"]))
        jobs = payload.get("jobs") if isinstance(payload, dict) else None
        return jobs if isinstance(jobs, list) else None

    try:
        return classify(runs, jobs_of, ci, now)
    except LookupError:
        return {"result": UNKNOWN, "last_test_at": None}


def cache_usable(cache, ci, now):
    """A cached result for this branch and pattern that is at most `cache_seconds` old."""
    return (isinstance(cache, dict) and cache.get("result") in (RAN, NONE, STALE)
            and cache.get("branch") == ci["branch"] and cache.get("job_pattern") == ci["job_pattern"]
            and isinstance(cache.get("checked_at"), (int, float))
            and 0 <= now - cache["checked_at"] <= ci["cache_seconds"])


def entry(result, ci, now):
    """The record to cache."""
    return {"result": result["result"], "last_test_at": result["last_test_at"], "checked_at": now,
            "branch": ci["branch"], "job_pattern": ci["job_pattern"]}


def age_text(seconds):
    seconds = max(0, int(seconds))
    if seconds >= 86400:
        return f"{seconds // 86400} d"
    if seconds >= 3600:
        return f"{seconds // 3600} h"
    return f"{seconds // 60} min"


def doctor_line(result, ci, now, *, nightly_recorded=False, cached_at=None):
    """The `doctor` line for a result, as (level, text), or None for nothing. `cached_at`
    marks an older cached result shown because a refresh found nothing (`unknown`)."""
    kind = result.get("result")
    suffix = f" (checked {age_text(now - cached_at)} ago; GitHub is unreachable now)" if cached_at else ""
    if kind == STALE:
        age = age_text(now - result["last_test_at"]) if result.get("last_test_at") else "more than the window"
        return ("NOTE", f"CI: no test job ran on {ci['branch']} or a pull request for {age} "
                        f"(testing.ci.max_age_days {ci['max_age_days']}){suffix}")
    if kind == NONE:
        return ("WARN", f"CI: no job matching {ci['job_pattern']!r} ran on {ci['branch']} or a pull request; "
                        f"CI may run no tests. Enable {FALLBACK} (testing.ci){suffix}")
    if kind == ABSENT and not nightly_recorded:
        return ("NOTE", f"CI: none is configured, so nothing tests {ci['branch']} but you; "
                        f"enable {FALLBACK}")
    return None


def current(ci, configured, run_gh, now, *, cache=None):
    """(result, new cache entry or None): the CI result, refreshed through `run_gh` only
    when the cache is older than `cache_seconds`. Never raises on a gh problem."""
    if not configured:
        return {"result": ABSENT}, None
    if cache_usable(cache, ci, now):
        return cache, None
    result = refresh(ci, run_gh, now)
    return result, None if result["result"] == UNKNOWN else entry(result, ci, now)


def check(ci, configured, run_gh, now, *, cache=None, nightly_recorded=False):
    """(line, new cache entry or None) for one doctor run. Never raises on a gh problem."""
    result, fresh = current(ci, configured, run_gh, now, cache=cache)
    if result["result"] != UNKNOWN:
        return doctor_line(result, ci, now, nightly_recorded=nightly_recorded), fresh
    older = cache if isinstance(cache, dict) and cache.get("result") in (RAN, NONE, STALE) \
        and isinstance(cache.get("checked_at"), (int, float)) \
        and cache.get("branch") == ci["branch"] and cache.get("job_pattern") == ci["job_pattern"] else None
    if older:
        return doctor_line(older, ci, now, cached_at=older["checked_at"]), None
    return None, None
