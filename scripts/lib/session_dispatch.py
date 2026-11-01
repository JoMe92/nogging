"""The pure half of `nogg session dispatch`: one level-triggered decision per pass.

No I/O, no clock and no model: callers inject the gathered facts, the remembered
state, the policy and the time, and `decide` returns the actions. See
openspec/changes/session-wake, design Decisions 6, 7 and 13.

A fact is one session's evidence, and a missing or None value means `unknown`, on
which no action may depend:

    session, role, agent, bead, state   `state` is a classified state, or `gone`
    nudgeable       a kicked-off autonomous Lead on a guarded runtime
    head, gaps      the checkout's HEAD and `completion_gaps`, None when unreadable
    bead_status, sweep                  the Bead and `_sweep_state`
    checks          the `_observe_checks` observation
    signal          {"kind", "reason", "at"}
    turn_error      {"at", "error"} when the last turn ended in a non-limit error
    turn, excerpt   the last event's timestamp and its excerpt
    pane_excerpt, switch_prompt, limit_until, limit_source, limit_at   from the pane or
                    the rollout; `limit_at` is a Codex limit error's own timestamp
    silent_seconds  age of the session log
    kicked_off, started_at, exit_reason, superseded, worktree_record
"""
from __future__ import annotations

import copy
import hashlib
import re
from datetime import datetime, timezone
from typing import Any

SETTLE_SECONDS = 60
NEEDS_INPUT_SECONDS = 120
CHECKS_INTERVAL_SECONDS = 120
BEADS_CACHE_SECONDS = 300
FAILED_CHECKS_SHOWN = 5
DONE_KEYS_KEPT = 64
KEY_PART_CHARS = 80
EXCERPT_LINES = 6

# Retrying these cannot help, so they skip the retry nudge.
PERMANENT_ERRORS = frozenset({"authentication_failed", "billing_error", "invalid_request"})
# What a host-wide hold stops. Items and retirement go on (TASK-SWK-009).
SENDS = frozenset({"nudge", "resume"})

GAP_WORDS = {"dirty": "uncommitted changes", "unpushed": "unpushed commits"}
BLOCK_HINT = "If you cannot, run `./scripts/nogg session signal blocked \"<why>\"` and stop."
NUDGE_GAPS = "Nogging dispatcher: you are idle with {gaps}. Commit, push and open the pull request now. " + BLOCK_HINT
NUDGE_NO_PR = ("Nogging dispatcher: you are idle with a clean tree, no pull request and no signal. "
               "Open the pull request now. " + BLOCK_HINT)
NUDGE_CI = ("Nogging dispatcher: CI is failing on PR #{pr}: {checks}. Repair it in this worktree and push. "
            + BLOCK_HINT)
NUDGE_RETRY = "Nogging dispatcher: your last turn ended in an error. Continue exactly where you left off."
NUDGE_STALL = ("Nogging dispatcher: your session log has been silent for {minutes} minutes. Continue. "
               + BLOCK_HINT)

_CHECK_NAME_DROP = re.compile(r"[^\w .:/()+-]+")
_KEY_DROP = re.compile(r"[^\w:.+@-]+")
_PLAIN_MARK = re.compile(r"[0-9a-fTZ:.+@-]{1,80}")
_DURATION = re.compile(r"^(\d+)([smh]?)$")
_UNITS = {"": 1, "s": 1, "m": 60, "h": 3600}


def seconds(value: Any) -> int:
    """`90`, `90s`, `15m` or `4h` as seconds; ValueError otherwise."""
    match = _DURATION.match(str(value).strip()) if not isinstance(value, bool) else None
    if match is None:
        raise ValueError(f"not a duration: {value!r}")
    return int(match.group(1)) * _UNITS[match.group(2)]


def _is_duration(value: Any) -> bool:
    try:
        return seconds(value) > 0
    except ValueError:
        return False


def _is_bool(value: Any) -> bool:
    return isinstance(value, bool)


def _is_count(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_positive(value: Any) -> bool:
    return _is_count(value) and value > 0


def _is_percent(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value <= 100


def _bad_windows(value: Any) -> list[Any]:
    """What `quiet_hours` holds that is no window. Imported here because session_warm,
    which owns the format, imports this module."""
    from session_warm import is_window
    return [window for window in value if not is_window(window)] if isinstance(value, list) else [value]


def _is_windows(value: Any) -> bool:
    return not _bad_windows(value)


_WANTS = {_is_duration: "a duration such as 90s, 15m or 4h", _is_bool: "true or false",
          _is_count: "a non-negative integer", _is_positive: "a positive integer",
          _is_percent: "a percentage from 0 to 100", _is_windows: 'a list of "HH:MM-HH:MM" windows'}
_WAKE_SCHEMA = {"urgent_quiet": _is_duration, "normal_quiet": _is_duration, "max_hold": _is_duration,
                "min_gap": _is_duration, "max_wakes_per_hour": _is_positive, "remind_after": _is_duration,
                "hold_above_percent": _is_percent, "keep_warm": _is_bool, "keep_warm_after": _is_duration,
                "quiet_hours": _is_windows}
_DISPATCH_SCHEMA = {"enabled": _is_bool, "max_nudges": _is_count, "max_ci_nudges": _is_count,
                    "stall_after": _is_duration, "ci_timeout": _is_duration, "retire_merged": _is_bool,
                    "wake": _WAKE_SCHEMA, "precompact_after": _is_duration,
                    "precompact_min_tokens": _is_positive}
_CONTEXT_SCHEMA = {"auto_compact_window": _is_positive, "idle_compact_min_tokens": _is_positive}
_CONTEXT_ENV = {"auto_compact_window": ("CLAUDE_CODE_AUTO_COMPACT_WINDOW", 200000),
                "idle_compact_min_tokens": ("CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS", 100000)}


def _block_errors(block: Any, where: str, schema: dict[str, Any]) -> list[str]:
    if not isinstance(block, dict):
        return [f"{where}: must be an object"]
    errors = []
    for key, value in block.items():
        check = schema.get(key)
        if check is None:
            errors.append(f"{where}: unknown key {key!r}")
        elif isinstance(check, dict):
            errors.extend(_block_errors(value, f"{where}.{key}", check))
        elif not check(value):
            named = ": " + ", ".join(repr(bad) for bad in _bad_windows(value)) if check is _is_windows else ""
            errors.append(f"{where}.{key}: must be {_WANTS[check]}{named}")
    return errors


def config_errors(config: dict[str, Any]) -> list[str]:
    """Every defect in the `session_dispatch` and `orchestrator_context` blocks."""
    errors = []
    if "session_dispatch" in config:
        errors.extend(_block_errors(config["session_dispatch"], "session_dispatch", _DISPATCH_SCHEMA))
    if "orchestrator_context" in config:
        errors.extend(_block_errors(config["orchestrator_context"], "orchestrator_context", _CONTEXT_SCHEMA))
    return errors


def is_on(block: Any) -> bool:
    """The one test of `session_dispatch.enabled`: only an explicit `false` is off, so a
    missing block or key is on. It reads no other key, because `session signal` must
    answer on a config that `validate` would refuse."""
    return not (isinstance(block, dict) and block.get("enabled") is False)


def context_env(block: Any) -> dict[str, str]:
    """The `orchestrator_context` values as the settings `env` of the orchestrator. A value
    `validate` would refuse keeps its default, and must not cost it a start."""
    block = block if isinstance(block, dict) else {}
    return {name: str(block[key] if _is_positive(block.get(key)) else default)
            for key, (name, default) in _CONTEXT_ENV.items()}


def policy_from(block: dict[str, Any] | None, hold_sends: bool = False) -> dict[str, Any]:
    """The validated block with its defaults, durations in seconds."""
    block = block or {}
    return {"enabled": is_on(block),
            "max_nudges": block.get("max_nudges", 2),
            "max_ci_nudges": block.get("max_ci_nudges", 2),
            "stall_after": seconds(block.get("stall_after", "15m")),
            "ci_timeout": seconds(block.get("ci_timeout", "60m")),
            "retire_merged": block.get("retire_merged") is True,
            "hold_sends": hold_sends}


def spent_budgets(memory: dict[str, Any], policy: dict[str, Any]) -> list[tuple[str, str]]:
    """Each session and budget with no nudge left, for `doctor`."""
    budgets = (("budget", "nudge", policy["max_nudges"]), ("ci", "CI", policy["max_ci_nudges"]))
    return [(name, label) for name, session in sorted((memory.get("sessions") or {}).items())
            for slot, label, limit in budgets if 0 < limit <= (session.get(slot) or {}).get("nudges", 0)]


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def seconds_since(stamp: Any, now: datetime) -> float | None:
    """Seconds since an ISO stamp, negative for one ahead, None when unreadable. A
    stamp without a zone is local time, which is what `resolve_clock_time` returns."""
    try:
        moment = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
        return (now - (moment if moment.tzinfo else moment.astimezone())).total_seconds()
    except (ValueError, OverflowError, OSError):
        return None


def dedupe_key(session: str, kind: str, *marks: Any) -> str:
    """Session, kind and the head or fingerprint that makes this occurrence new. A
    mark can come from an event line, so one that is no stamp or head is hashed: the
    key stays stable and repeats no agent text."""
    marks = [mark if isinstance(mark, str) and _PLAIN_MARK.fullmatch(mark)
             else hashlib.sha256(str(mark).encode()).hexdigest()[:16] for mark in marks]
    return "|".join(_KEY_DROP.sub("", str(part))[:KEY_PART_CHARS] for part in (session, kind, *marks))


def check_names(failed: list[Any]) -> str:
    """Up to FAILED_CHECKS_SHOWN names, bounded and stripped of anything but a label:
    a check name comes from a workflow file and lands in a Lead's prompt."""
    names = [_CHECK_NAME_DROP.sub(" ", str(name)).strip()[:80] for name in failed[:FAILED_CHECKS_SHOWN]]
    return ", ".join(name for name in names if name) or "unnamed checks"


def ci_summary(checks: dict[str, Any]) -> str | None:
    total = checks.get("total")
    if not isinstance(total, int):
        return None
    passed = total - len(checks.get("failed") or []) - len(checks.get("pending") or [])
    return f"{checks.get('status')} ({passed}/{total})"


def _diffstat(checks: dict[str, Any]) -> str | None:
    added, deleted = checks.get("additions"), checks.get("deletions")
    return f"+{added} -{deleted}" if isinstance(added, int) and isinstance(deleted, int) else None


def _queue(fact: dict[str, Any], kind: str, mark: Any, reason: str, next_step: str) -> dict[str, Any]:
    checks = fact.get("checks") or {}
    key = dedupe_key(fact["session"], kind, mark)
    pr = checks.get("pr_number")
    return {"type": "queue", "session": fact["session"], "key": key, "reason": reason,
            "item": {"key": key, "kind": kind, "session": fact["session"], "bead": fact.get("bead"),
                     "pr": pr if type(pr) is int else None, "ci": ci_summary(checks), "diff": _diffstat(checks),
                     "head": (fact.get("head") or "")[:12] or None, "reason": reason, "next": next_step}}


def failure_item(fact: dict[str, Any], action: dict[str, Any], detail: str) -> dict[str, Any]:
    """The `error` item for a resume or retirement that failed. Its action is spent, so
    no later pass can report it again, and it is `sticky` until it has gone out."""
    failure = _queue(fact, "error", action["key"], f"{action['type']} failed: {detail}",
                     f"./scripts/nogg session log {fact['session']}")
    failure["item"]["sticky"] = True
    return failure


def _nudge_or_escalate(fact: dict[str, Any], memory: dict[str, Any], budget: str, limit: int,
                       reason: str, mark: Any, text: str, escalate: Any, now: datetime) -> list[dict[str, Any]]:
    """The ladder both budgets share. An interval of SETTLE_SECONDS separates a
    replayed pass from a Lead that did not react, whose evidence is identical."""
    if fact["state"] != "idle" or not fact.get("nudgeable"):
        return []
    slot = memory.setdefault(budget, {})
    last = seconds_since(slot.get("last_nudge"), now) if slot.get("last_nudge") else None
    if last is not None and last < SETTLE_SECONDS:
        return []
    used = slot.get("nudges", 0)
    if used >= limit:
        return [escalate()]
    return [{"type": "nudge", "session": fact["session"], "reason": reason, "budget": budget, "text": text,
             "key": dedupe_key(fact["session"], reason, mark, used + 1)}]


def _waits_for_reset(fact: dict[str, Any]) -> bool:
    """A limit whose reset time ends it: from an event, from a Codex rollout, or from a
    Codex pane, which does not clear on its own. Any other pane limit is resumed once
    the pane leaves `limit`."""
    source = fact.get("limit_source")
    return source in ("event", "rollout") or (source == "pane" and fact.get("agent") == "codex")


def _limit_step(fact: dict[str, Any], memory: dict[str, Any], now: datetime) -> list[dict[str, Any]] | None:
    """Wait out `limit`, then resume once per limit error: None when no limit is in
    play. Its reset time is what ends it. A newer error (`limit_at`) is a new limit
    with its own reset time and resume key, so one that outlasts the reported reset
    cannot loop; with no readable reset time nothing is sent and one `stuck` item
    stands until the state leaves `limit`."""
    state, limit = fact["state"], memory.get("limit")
    if state == "limit":
        at = fact.get("limit_at")
        if not limit or (at and limit.get("at") != at):
            limit = memory["limit"] = {"since": iso(now), "at": at, "until": fact.get("limit_until")}
        else:
            limit["until"] = limit.get("until") or fact.get("limit_until")
        remaining = seconds_since(limit["until"], now) if limit["until"] else None
        if not _waits_for_reset(fact):
            return []
        if remaining is None:
            reason = "usage limit, reset time unknown"
            if fact.get("excerpt"):
                reason += f": {fact['excerpt']}"
            return [_queue(fact, "stuck", limit.get("at") or limit["since"], reason,
                           f"./scripts/nogg session log {fact['session']}")]
        return [] if remaining < 0 else [_resume(fact, limit)]
    if not limit:
        return None
    if state == "working":
        memory.pop("limit")
        return None
    if state != "idle" and not (state == "needs_input" and fact.get("switch_prompt")):
        return []
    return [_resume(fact, limit)]


def _resume(fact: dict[str, Any], limit: dict[str, Any]) -> dict[str, Any]:
    return {"type": "resume", "session": fact["session"], "reason": "limit-over",
            "key": dedupe_key(fact["session"], "resume", limit.get("at") or limit["since"])}


def _stall_step(fact: dict[str, Any], memory: dict[str, Any], policy: dict[str, Any],
                now: datetime) -> list[dict[str, Any]]:
    """A `working` session whose log went silent. The nudge is still idle-only, so
    the delivery gate holds it from a session that stays `working`, and the second
    period reports it either way. `once` spends it even when held."""
    silent, period = fact.get("silent_seconds"), policy["stall_after"]
    if silent is None or silent < period:
        memory.pop("stall", None)
        return []
    stall = memory.setdefault("stall", {"since": iso(now)})
    if silent >= 2 * period:
        return [_queue(fact, "stalled", stall["since"], f"no log output for {int(silent // 60)} minutes",
                       f"./scripts/nogg session log {fact['session']}")]
    if not fact.get("nudgeable"):
        return []
    return [{"type": "nudge", "session": fact["session"], "reason": "stall", "once": True,
             "text": NUDGE_STALL.format(minutes=int(silent // 60)),
             "key": dedupe_key(fact["session"], "stall", stall["since"])}]


def _turn_error_step(fact: dict[str, Any], memory: dict[str, Any]) -> list[dict[str, Any]] | None:
    """One retry for a transient error, then `error`: None when the last turn was clean."""
    error = fact.get("turn_error")
    if not error:
        memory.pop("retry", None)
        return None
    at, kind, retried = error.get("at"), error.get("error"), memory.get("retry")
    if kind in PERMANENT_ERRORS or (retried and retried != at):
        return [_queue(fact, "error", at, f"turn ended in error {kind or 'unknown'}",
                       f"./scripts/nogg session log {fact['session']}")]
    if retried or fact["state"] != "idle" or not fact.get("nudgeable"):
        return []
    return [{"type": "nudge", "session": fact["session"], "reason": "retry", "retry": at, "text": NUDGE_RETRY,
             "key": dedupe_key(fact["session"], "retry", at)}]


def _retire_step(fact: dict[str, Any], policy: dict[str, Any]) -> list[dict[str, Any]]:
    gaps, checks = fact.get("gaps"), fact.get("checks") or {}
    if (policy["retire_merged"] and fact["state"] == "idle" and fact.get("bead_status") == "closed"
            and fact.get("sweep") == "change-complete" and gaps is not None
            and not set(gaps) & set(GAP_WORDS) and checks.get("head_sha") == fact.get("head")):
        return [{"type": "retire", "session": fact["session"], "reason": "merged, closed and clean",
                 "key": dedupe_key(fact["session"], "retire", fact.get("head"))}]
    return []


def _ci_step(fact: dict[str, Any], memory: dict[str, Any], policy: dict[str, Any],
             now: datetime) -> list[dict[str, Any]]:
    """Pending, red and green checks of an open pull request on this head. The CI
    budget counts across heads and only green restores it: every fix moves the head,
    so a budget reset by that could never reach `ci_stuck`."""
    checks, ci, head = fact["checks"], memory.setdefault("ci", {}), fact.get("head")
    status = checks.get("status")
    if status == "pending":
        if ci.get("pending_head") != head:
            ci.update(pending_head=head, pending_since=iso(now))
        waited = seconds_since(ci["pending_since"], now)
        if waited is None or waited < policy["ci_timeout"]:
            return []
        return [_queue(fact, "ci_timeout", head, f"CI still pending after {int(waited // 60)} minutes",
                       f"gh pr checks {checks.get('pr_number')}")]
    ci.pop("pending_head", None)
    ci.pop("pending_since", None)
    if status == "failing":
        fingerprint = checks.get("fingerprint")
        if fingerprint != ci.get("fingerprint"):
            ci["fingerprint"] = fingerprint
            ci.pop("last_nudge", None)
        names = check_names(checks.get("failed") or [])
        return _nudge_or_escalate(
            fact, memory, "ci", policy["max_ci_nudges"], "ci", fingerprint,
            NUDGE_CI.format(pr=checks.get("pr_number"), checks=names),
            lambda: _queue(fact, "ci_stuck", fingerprint, f"CI still failing: {names}",
                           f"gh pr checks {checks.get('pr_number')}"), now)
    if status == "passing":
        memory["ci"] = {}
        if checks.get("mergeable") == "MERGEABLE":
            return [_queue(fact, "ready_for_review", checks.get("fingerprint"), "CI is green",
                           f"gh pr view {checks.get('pr_number')}")]
    return []


def _worktree_step(fact: dict[str, Any], memory: dict[str, Any], policy: dict[str, Any],
                   now: datetime) -> list[dict[str, Any]]:
    """A settled session that is not working: its pull request and its gaps."""
    checks = fact.get("checks") or {}
    if checks.get("pr_state") == "MERGED":
        return _retire_step(fact, policy)
    errored = _turn_error_step(fact, memory)
    if errored is not None:
        return errored
    gaps, head = fact.get("gaps"), fact.get("head")
    if gaps is None:
        return []
    open_pr = checks.get("pr_state") == "OPEN" and checks.get("head_sha") == head
    if open_pr and checks.get("mergeable") == "CONFLICTING":
        record = fact.get("worktree_record") or "<record>"
        return [_queue(fact, "conflict", head, f"PR #{checks.get('pr_number')} conflicts with develop",
                       f"./scripts/nogg worktree rebase {record}")]
    stuck = lambda reason: _queue(fact, "stuck", head, reason, f"./scripts/nogg session log {fact['session']}")
    unfinished = [GAP_WORDS[gap] for gap in gaps if gap in GAP_WORDS]
    if unfinished:
        text = ", ".join(unfinished)
        return _nudge_or_escalate(fact, memory, "budget", policy["max_nudges"], "gaps", head,
                                  NUDGE_GAPS.format(gaps=text), lambda: stuck(f"idle with {text}"), now)
    if checks.get("status") == "no-pr":
        if "no-signal" not in gaps:
            return []
        return _nudge_or_escalate(fact, memory, "budget", policy["max_nudges"], "no-pr", head, NUDGE_NO_PR,
                                  lambda: stuck("idle, clean, no pull request and no signal"), now)
    return _ci_step(fact, memory, policy, now) if open_pr else []


def _decide_session(fact: dict[str, Any], memory: dict[str, Any], policy: dict[str, Any],
                    now: datetime) -> list[dict[str, Any]]:
    state, name, agent = fact["state"], fact["session"], fact.get("agent")
    held = seconds_since(memory.get("since"), now) or 0
    if state == "gone":
        if held < SETTLE_SECONDS or fact.get("bead_status") != "in_progress" or fact.get("superseded"):
            return []
        return [_queue(fact, "crashed", fact.get("started_at"),
                       f"session gone with its Bead in progress: {fact.get('exit_reason') or 'no exit recorded'}",
                       f"./scripts/nogg session log {name}")]
    limited = None if agent == "antigravity" else _limit_step(fact, memory, now)
    if limited is not None:
        return limited
    if state == "needs_input":
        if held < NEEDS_INPUT_SECONDS:
            return []
        return [_queue(fact, "needs_input", memory["since"], fact.get("pane_excerpt") or "waiting on a prompt",
                       f"./scripts/nogg session attach {name}")]
    if agent == "antigravity":
        return []
    if fact.get("role") == "planning":
        if state != "idle" or held < SETTLE_SECONDS or not fact.get("kicked_off"):
            return []
        return [_queue(fact, "planner_finished", fact.get("turn") or memory["since"],
                       fact.get("excerpt") or "planning session idle after kickoff",
                       f"./scripts/nogg session log {name}")]
    if state == "working":
        return _stall_step(fact, memory, policy, now)
    if held < SETTLE_SECONDS or state not in ("idle", "waiting_background"):
        return []
    signal = fact.get("signal") or {}
    if signal.get("kind") == "blocked":
        return [_queue(fact, "blocked", f"{signal.get('at')}@{fact.get('head')}", signal.get("reason") or "blocked",
                       f"./scripts/nogg session log {name}")]
    sweep = fact.get("sweep") or ""
    if fact.get("bead_status") == "blocked" or sweep.startswith("bead-blocked"):
        return [_queue(fact, "blocked", fact.get("head"), f"Bead {fact.get('bead')} is {sweep or 'blocked'}",
                       f"bd show {fact.get('bead')}")]
    return _worktree_step(fact, memory, policy, now)


def _observe(fact: dict[str, Any], memory: dict[str, Any], now: datetime) -> None:
    """Carry the settle clock and the head budget across passes."""
    state, head = fact["state"], fact.get("head")
    if state != memory.get("state"):
        memory.update(state=state, since=iso(now))
    if state != "working":
        memory.pop("stall", None)
    if head and head != memory.get("head"):
        memory.update(head=head, budget={})


def _decide_remembering(fact: dict[str, Any], session: dict[str, Any], policy: dict[str, Any],
                        now: datetime) -> list[dict[str, Any]]:
    """One session's decision. `state.json` and the checks cache lie inside a tree some
    Leads can write. A memory this code cannot use is forgotten, and a fact it cannot
    use costs that session this pass, so neither can stop the pass for every session."""
    failures = (AttributeError, KeyError, TypeError, ValueError)
    try:
        if not isinstance(session.get("done", []), list):
            raise TypeError("done")
        _observe(fact, session, now)
        return _decide_session(fact, session, policy, now)
    except failures:
        session.clear()
    try:
        _observe(fact, session, now)
        return _decide_session(fact, session, policy, now)
    except failures:
        return []


def decide(facts: list[dict[str, Any]], memory: dict[str, Any], policy: dict[str, Any],
           now: datetime) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """The actions for one pass and the memory to carry forward. Spending an action
    is `record`'s job, so one held back at the send stays due. A queue action is
    never spent: it reports a condition on every pass while it holds, which is what
    keeps the queue level-triggered. A session with no fact any more is forgotten;
    `unknown` keeps what it had."""
    known = memory.get("sessions") if isinstance(memory.get("sessions"), dict) else {}
    next_memory, actions = {**memory, "sessions": {}}, []
    for fact in facts:
        remembered = known.get(fact["session"])
        session = copy.deepcopy(remembered) if isinstance(remembered, dict) else {}
        next_memory["sessions"][fact["session"]] = session
        if fact.get("state", "unknown") == "unknown":
            continue
        chosen = _decide_remembering(fact, session, policy, now)
        actions.extend(action for action in chosen
                       if (action["type"] == "queue" or action["key"] not in session.get("done", []))
                       and not (policy.get("hold_sends") and action["type"] in SENDS))
    return actions, next_memory


def record(memory: dict[str, Any], action: dict[str, Any], now: datetime) -> None:
    """Spend one attempted action: its key, its budget and any step it completes."""
    session = memory["sessions"][action["session"]]
    session["done"] = [*session.get("done", []), action["key"]][-DONE_KEYS_KEPT:]
    if action.get("budget"):
        slot = session.setdefault(action["budget"], {})
        slot.update(nudges=slot.get("nudges", 0) + 1, last_nudge=iso(now))
    if action["type"] == "resume":
        session.pop("limit", None)
    if action.get("retry"):
        session["retry"] = action["retry"]


def enqueue(queue: dict[str, Any], item: dict[str, Any], now: datetime) -> None:
    """Add an item once, by key. session_wake re-evaluates, delivers and drops them."""
    items = queue.setdefault("items", [])
    if not any(existing.get("key") == item["key"] for existing in items):
        items.append({**item, "created_at": iso(now)})


def report_retired(queue: dict[str, Any], fact: dict[str, Any], now: datetime) -> None:
    """A retirement is no item: it is told in the next digest."""
    queue.setdefault("retired", []).append({"session": fact["session"], "bead": fact.get("bead"), "at": iso(now)})
