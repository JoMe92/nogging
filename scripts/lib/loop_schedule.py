"""Pure schedule parsing and slot calculations for Nogging loops."""
from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

UTC = timezone.utc
_EVERY = re.compile(r"([1-9][0-9]*)([mhdw])\Z")
_TIME = re.compile(r"([01][0-9]|2[0-3]):([0-5][0-9])\Z")
_DATETIME = re.compile(r"(\d{4}-\d{2}-\d{2})T([01][0-9]|2[0-3]):([0-5][0-9])\Z")
_WEEKDAYS = {name: index for index, name in enumerate(("mon", "tue", "wed", "thu", "fri", "sat", "sun"))}


def _fail(key: str, reason: str) -> ValueError:
    return ValueError(f"{key}: {reason}")


def _parse_time(value, key: str) -> time:
    if not isinstance(value, str) or not _TIME.fullmatch(value):
        raise _fail(key, "expected HH:MM")
    hour, minute = map(int, value.split(":"))
    return time(hour, minute)


def _aware(value, key: str = "datetime") -> datetime:
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as exc:
            raise _fail(key, "expected an ISO datetime") from exc
    if not isinstance(value, datetime) or value.tzinfo is None:
        raise _fail(key, "expected a timezone-aware datetime")
    return value.astimezone(UTC)


def _local_candidates(naive: datetime, zone: ZoneInfo) -> list[datetime]:
    """Resolve wall time; gaps move to their first valid instant, overlaps use fold 0."""
    for offset in range(0, 181):
        wall = naive + timedelta(minutes=offset)
        found = []
        for fold in (0, 1):
            local = wall.replace(tzinfo=zone, fold=fold)
            instant = local.astimezone(UTC)
            if instant.astimezone(zone).replace(tzinfo=None) == wall:
                found.append(instant)
        unique = sorted(set(found))
        if unique:
            return [unique[0]]
    return []


def _window_parts(value: str, key: str) -> tuple[time, time]:
    if not isinstance(value, str) or value.count("-") != 1:
        raise _fail(key, "expected HH:MM-HH:MM")
    start_text, end_text = value.split("-")
    start, end = _parse_time(start_text, key), _parse_time(end_text, key)
    if start == end:
        raise _fail(key, "window endpoints must differ")
    return start, end


def parse_schedule(schedule: dict) -> dict:
    """Validate and normalize a schedule object without performing I/O."""
    if not isinstance(schedule, dict):
        raise _fail("schedule", "expected an object")
    allowed = {"timezone", "every", "at", "start", "days", "windows", "grace"}
    unknown = set(schedule) - allowed
    if unknown:
        raise _fail(sorted(unknown)[0], "unknown key")
    if "timezone" not in schedule or not isinstance(schedule["timezone"], str):
        raise _fail("timezone", "required IANA timezone")
    try:
        zone = ZoneInfo(schedule["timezone"])
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise _fail("timezone", "unknown IANA timezone") from exc
    if ("every" in schedule) == ("at" in schedule):
        raise _fail("every", "exactly one of every or at is required")

    result = {"timezone": schedule["timezone"], "_zone": zone}
    if "every" in schedule:
        every = schedule["every"]
        match = _EVERY.fullmatch(every) if isinstance(every, str) else None
        if not match:
            raise _fail("every", "expected an interval such as 5m, 2h, 1d or 1w")
        amount, unit = int(match.group(1)), match.group(2)
        if unit in "mh" and (amount * (1 if unit == "m" else 60) < 5 or amount * (1 if unit == "m" else 60) >= 1440):
            raise _fail("every", "minute/hour intervals must be at least 5 minutes and under 24 hours")
        result.update(every=(amount, unit))
    else:
        at = schedule["at"]
        if not isinstance(at, list) or not at:
            raise _fail("at", "expected a non-empty list of times")
        result["at"] = [_parse_time(item, "at") for item in at]
        if result["at"] != sorted(set(result["at"])):
            raise _fail("at", "times must be sorted and unique")

    if "start" in schedule:
        start = schedule["start"]
        if not isinstance(start, str):
            raise _fail("start", "expected HH:MM or YYYY-MM-DDTHH:MM")
        match = _DATETIME.fullmatch(start)
        if match:
            try:
                result["start"] = datetime.fromisoformat(start)
            except ValueError as exc:
                raise _fail("start", "invalid local datetime") from exc
        else:
            result["start"] = _parse_time(start, "start")
    else:
        result["start"] = time(0, 0)
    if "every" in result:
        amount, unit = result["every"]
        if unit in "dw" and amount > 1 and not isinstance(result["start"], datetime):
            raise _fail("start", "intervals longer than one day require YYYY-MM-DDTHH:MM")
        if unit in "mh" and isinstance(result["start"], datetime):
            raise _fail("start", "minute/hour intervals require HH:MM")

    if "days" in schedule:
        days = schedule["days"]
        if not isinstance(days, list) or any(day not in _WEEKDAYS for day in days):
            raise _fail("days", "expected weekday names mon through sun")
        if len(set(days)) != len(days):
            raise _fail("days", "weekdays must be unique")
        result["days"] = frozenset(_WEEKDAYS[day] for day in days)
    else:
        result["days"] = None
    if "windows" in schedule:
        windows = schedule["windows"]
        if not isinstance(windows, list) or not windows:
            raise _fail("windows", "expected a non-empty list")
        result["windows"] = [_window_parts(item, "windows") for item in windows]
    else:
        result["windows"] = None
    if "grace" in schedule:
        grace = schedule["grace"]
        if isinstance(grace, bool) or not isinstance(grace, int) or grace < 0:
            raise _fail("grace", "expected a non-negative integer number of seconds")
        result["grace"] = timedelta(seconds=grace)
    else:
        result["grace"] = None
    return result


def _iter_dates(start: date, end: date):
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def _raw_wall_slots(parsed: dict, start_date: date, end_date: date):
    zone, every = parsed["_zone"], parsed.get("every")
    if every:
        amount, unit = every
        anchor = parsed["start"]
        if unit in "mh":
            anchor_time = anchor
            step = timedelta(minutes=amount if unit == "m" else amount * 60)
            for day in _iter_dates(start_date - timedelta(days=1), end_date):
                base = datetime.combine(day, anchor_time)
                wall = base
                next_anchor = base + timedelta(days=1)
                while wall < next_anchor:
                    yield wall, day
                    wall += step
        else:
            step_days = amount * (7 if unit == "w" else 1)
            if isinstance(anchor, datetime):
                anchor_date, anchor_time = anchor.date(), anchor.time()
            else:
                anchor_date, anchor_time = start_date, anchor
            for day in _iter_dates(start_date - timedelta(days=step_days), end_date):
                if (day - anchor_date).days % step_days == 0:
                    yield datetime.combine(day, anchor_time), day
    else:
        for day in _iter_dates(start_date - timedelta(days=1), end_date):
            for at in parsed["at"]:
                yield datetime.combine(day, at), day


def _window_status(parsed: dict, wall: datetime, opening_day: date):
    windows = parsed["windows"]
    if not windows:
        return True, None, opening_day.weekday()
    t = wall.time()
    for begin, end in windows:
        crosses = begin > end
        if (begin <= t < end) if not crosses else (t >= begin or t < end):
            opened = opening_day if t >= begin else opening_day - timedelta(days=1)
            end_day = opened + timedelta(days=1) if crosses else opened
            end_wall = datetime.combine(end_day, end)
            end_utc = _local_candidates(end_wall, parsed["_zone"])[0]
            return True, end_utc, opened.weekday()
    return False, None, opening_day.weekday()


def _slots_between(parsed: dict, start: datetime, end: datetime) -> list[datetime]:
    zone = parsed["_zone"]
    local_start = start.astimezone(zone).date() - timedelta(days=2)
    local_end = end.astimezone(zone).date() + timedelta(days=2)
    slots = set()
    for wall, opening_day in _raw_wall_slots(parsed, local_start, local_end):
        allowed, _, weekday = _window_status(parsed, wall, opening_day)
        if not allowed or (parsed["days"] is not None and weekday not in parsed["days"]):
            continue
        for instant in _local_candidates(wall, zone):
            if start < instant <= end:
                slots.add(instant)
    return sorted(slots)


def next_slots(schedule: dict, after: datetime, n: int) -> list[datetime]:
    """Return the next n UTC slots strictly later than an aware datetime."""
    if isinstance(n, bool) or not isinstance(n, int) or n < 0:
        raise _fail("n", "expected a non-negative integer")
    if n == 0:
        return []
    parsed = parse_schedule(schedule)
    after = _aware(after, "after")
    # A broad horizon handles sparse day/week schedules without unbounded scans.
    end = after + timedelta(days=max(370, n * 14))
    slots = _slots_between(parsed, after, end)
    while len(slots) < n:
        end += timedelta(days=max(370, n * 14))
        slots.extend(_slots_between(parsed, slots[-1] if slots else after, end))
    return slots[:n]


def due(schedule: dict, last_evaluated: datetime, now: datetime) -> dict | None:
    """Return the latest due slot and older missed-slot bounds, or None."""
    parsed = parse_schedule(schedule)
    last_evaluated, now = _aware(last_evaluated, "last_evaluated"), _aware(now, "now")
    if now <= last_evaluated:
        return None
    slots = _slots_between(parsed, last_evaluated, now)
    if not slots:
        return None
    older = slots[:-1]
    return {"slot": slots[-1], "count": len(slots),
            "missed_first": older[0] if older else None,
            "missed_last": older[-1] if older else None}


def _window_end_for(parsed: dict, slot: datetime) -> datetime | None:
    if not parsed["windows"]:
        return None
    local = slot.astimezone(parsed["_zone"])
    allowed, end, _ = _window_status(parsed, local.replace(tzinfo=None), local.date())
    return end if allowed else None


def deadline(schedule: dict, slot: datetime) -> datetime:
    """Return the earliest of grace expiry, next slot, and containing window end."""
    parsed = parse_schedule(schedule)
    slot = _aware(slot, "slot")
    grace = parsed["grace"]
    if grace is None:
        if "every" in parsed:
            amount, unit = parsed["every"]
            seconds = amount * {"m": 60, "h": 3600, "d": 86400, "w": 604800}[unit]
            grace = timedelta(seconds=max(60, min(seconds / 2, 1800)))
        else:
            grace = timedelta(minutes=30)
    limits = [slot + grace, next_slots(schedule, slot, 1)[0]]
    window_end = _window_end_for(parsed, slot)
    if window_end is not None:
        limits.append(window_end)
    return min(limits)
