"""Read and manage scheduled-loop definitions from the nogg command line."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone

import loop_config
import loop_schedule
import loop_state


def _atomic_bytes(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _host_timezone():
    localtime = Path("/etc/localtime")
    try:
        resolved = localtime.resolve(strict=True)
        marker = "/zoneinfo/"
        text = str(resolved)
        if marker in text:
            return text.split(marker, 1)[1]
    except OSError:
        pass
    from datetime import datetime
    zone = datetime.now().astimezone().tzinfo
    key = getattr(zone, "key", None)
    if key:
        return key
    raise ValueError("cannot determine host IANA timezone; set timezone in loops.json")


def _load(path):
    value = loop_config.load(path)
    if value is None:
        return {"schema_version": 1, "timezone": None, "scheduler": {}, "loops": {}}, True
    # Retain optional omissions and the source formatting-independent structure.
    raw = json.loads(Path(path).read_text(encoding="utf-8"),
                     object_pairs_hook=loop_config._no_duplicate_keys)
    return raw, False


def _write_definitions(path, raw):
    # Validate the serialized form before replacing a prior good version.
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(raw, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        loop_config.load(temporary)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _management_guard(session_record, action):
    if session_record is not None and session_record.get("role") != "orchestrator":
        raise RuntimeError(f"nogg loop {action} is refused inside supervised session "
                           f"{session_record.get('name')} ({session_record.get('role')}); "
                           "only the Orchestration Agent may manage loops")


def _timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _local_utc(instant, zone):
    local = instant.astimezone(zone)
    return f"{local.strftime('%Y-%m-%d %H:%M %Z')} ({instant.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%MZ')})"


def _loop_state(state, name):
    return state.setdefault("loops", {}).setdefault(name, {})


def command(args, *, main_checkout, definitions_path, session_record, multi_machine=False):
    action = args.loop_command
    mutating = action in {"add", "approve", "remove", "pause", "resume"}
    if mutating:
        _management_guard(session_record, action)
    definitions_path = Path(definitions_path)
    main_checkout = Path(main_checkout)
    raw, first_use = _load(definitions_path)
    config = loop_config.load(definitions_path)
    if config is not None:
        loop_config.validate_hosts(config, multi_machine)

    if action == "add":
        if args.name in raw["loops"]:
            raise ValueError(f"loop {args.name!r} already exists")
        timezone_name = raw.get("timezone") or _host_timezone()
        schedule = {}
        if args.every is not None:
            schedule["every"] = args.every
        if args.at:
            schedule["at"] = sorted(args.at)
        for key in ("start", "days", "windows", "grace"):
            value = getattr(args, key)
            if value is not None:
                schedule[key] = value
        if ("every" in schedule) == ("at" in schedule):
            raise ValueError("add requires exactly one of --every or --at")
        run = {"mode": args.mode}
        if args.mode == "send":
            run["target"] = args.target or "orchestrator"
        else:
            for key in ("agent", "tier", "model", "effort", "authority", "max_runtime"):
                value = getattr(args, key)
                if value is not None:
                    run[key] = value
            if not args.agent or not args.tier:
                raise ValueError("launch loops require --agent and --tier")
        loop = {"schedule": schedule, "run": run}
        if args.host:
            loop["host"] = args.host
        usage = {}
        if args.max_used_percent is not None:
            usage["max_used_percent"] = args.max_used_percent
        if args.on_unknown:
            usage["on_unknown"] = args.on_unknown
        if usage:
            loop["usage"] = usage
        raw = {"schema_version": 1, "timezone": timezone_name,
               "scheduler": raw.get("scheduler", {}),
               "loops": {**raw.get("loops", {}), args.name: loop}}
        if args.prompt is not None:
            prompt = args.prompt.encode("utf-8")
        else:
            source = Path(args.prompt_file)
            if source.stat().st_size > loop_config.PROMPT_MAX_BYTES:
                raise ValueError(f"{source}: prompt exceeds 16 KiB")
            with source.open("rb") as stream:
                prompt = stream.read(loop_config.PROMPT_MAX_BYTES + 1)
        if len(prompt) > loop_config.PROMPT_MAX_BYTES:
            raise ValueError("prompt exceeds 16 KiB")
        prompt_path = loop_state.prompt_path(main_checkout, definitions_path, args.name)
        if prompt_path.exists():
            raise ValueError(f"loop prompt already exists: {prompt_path}")
        prompt_path.parent.mkdir(parents=True, exist_ok=True)
        _atomic_bytes(prompt_path, prompt)
        try:
            loop_config.check_prompt(prompt_path)
        except BaseException:
            prompt_path.unlink(missing_ok=True)
            raise
        _write_definitions(definitions_path, raw)
        config = loop_config.load(definitions_path)
        digest = loop_state.approve(main_checkout, definitions_path, config, args.name)
        if first_use:
            print(f"Timezone: {timezone_name}")
        print(f"Added and approved loop {args.name} (prompt SHA-256 {digest}).")
        try:
            rel = definitions_path.resolve().relative_to(main_checkout.resolve())
            ignored = subprocess.run(["git", "check-ignore", "-q", "--", str(rel)], cwd=main_checkout,
                                     check=False, stderr=subprocess.DEVNULL).returncode == 0
        except ValueError:
            ignored = False
        if not ignored:
            print(f"Commit {definitions_path} and {prompt_path} to share this loop definition.")
        return

    if action == "list":
        if config is None:
            config = {"timezone": _host_timezone(), "loops": {}}
        state = loop_state.read_state(main_checkout)
        entries = []
        zone = loop_schedule.parse_schedule({"timezone": config["timezone"], "at": ["00:00"]})["_zone"]
        now = datetime.now(timezone.utc)
        for name, loop in sorted(config["loops"].items()):
            status, approval = loop_state.approval_status(main_checkout, definitions_path, config, name)
            ls = state.get("loops", {}).get(name, {})
            mode = loop["run"]["mode"]
            target = loop["run"].get("target", loop["run"].get("agent", ""))
            run_state = "other-host" if loop.get("host") and loop["host"] != os.uname().nodename else (
                "suspended" if ls.get("suspended") else "paused" if ls.get("paused") else
                "disabled" if not loop["enabled"] else "unapproved" if not status else "enabled")
            slots = loop_schedule.next_slots({"timezone": config["timezone"], **loop["schedule"]}, now, 1)
            next_slot = _local_utc(slots[0], zone)
            last = ls.get("last_outcome", "-")
            entries.append({"name": name, "state": run_state, "schedule": loop["schedule"],
                            "mode": mode, "target": target, "tier": loop["run"].get("tier"),
                            "authority": loop["run"].get("authority", "restricted") if mode == "launch" else None,
                            "next_slot": next_slot, "last_outcome": last,
                            "approved": status})
        if args.json:
            print(json.dumps({"schema_version": 1, "loops": entries}, sort_keys=True))
        else:
            for item in entries:
                extra = f" tier={item['tier']} authority={item['authority']}" if item["mode"] == "launch" else ""
                print(f"{item['name']}  {item['state']}  {item['schedule']}  {item['mode']}:{item['target']}"
                      f"{extra}  next {item['next_slot']}  last {item['last_outcome']}")
        return

    if action in {"show", "log", "approve", "pause", "resume", "remove"}:
        if config is None or args.name not in config["loops"]:
            raise ValueError(f"unknown loop {args.name!r}")
        name, loop = args.name, config["loops"][args.name]
    if action == "approve":
        digest = loop_state.current_hash(main_checkout, definitions_path, config, name)
        run = loop["run"]
        target = run.get("target", run.get("agent", ""))
        tier = run.get("tier", "")
        authority = run.get("authority", "inherited")
        print(f"Approval for {name}: mode={run['mode']} target/agent={target} tier={tier} "
              f"authority={authority} prompt-sha256={digest}")
        recorded = loop_state.approve(main_checkout, definitions_path, config, name)
        print(f"Approved {name} (SHA-256 {recorded}).")
    elif action in {"pause", "resume"}:
        with loop_state.state_lock(main_checkout):
            state = loop_state.read_state(main_checkout)
            item = _loop_state(state, name)
            item["paused"] = action == "pause"
            if action == "resume":
                item.pop("suspended", None)
                item.pop("suspend_reason", None)
                item.pop("consecutive_failures", None)
            loop_state.write_state(main_checkout, state)
        print(f"Loop {name} {action}d.")
    elif action == "remove":
        prompt = loop_state.prompt_path(main_checkout, definitions_path, name)
        raw, _ = _load(definitions_path)
        del raw["loops"][name]
        _write_definitions(definitions_path, raw)
        try:
            prompt.unlink()
        except FileNotFoundError:
            pass
        loop_state.remove_approval(main_checkout, name)
        with loop_state.state_lock(main_checkout):
            state = loop_state.read_state(main_checkout)
            loops = state.get("loops", {})
            active = loops.get(name, {}).get("active_run")
            if active and active.get("mode") == "launch":
                # The next tick stops and retires this run's session.
                loops[name] = {"active_run": active}
            else:
                loops.pop(name, None)
            loop_state.write_state(main_checkout, state)
        print(f"Removed loop {name}; run history is retained.")
    elif action == "show":
        approved, record = loop_state.approval_status(main_checkout, definitions_path, config, name)
        state = loop_state.read_state(main_checkout).get("loops", {}).get(name, {})
        schedule = {"timezone": config["timezone"], **loop["schedule"]}
        parsed = loop_schedule.parse_schedule(schedule)
        slots = loop_schedule.next_slots(schedule, datetime.now(timezone.utc), 5)
        value = {"schema_version": 1, "name": name, "definition": loop,
                 "approval": {"approved": approved,
                              "sha256": record.get("sha256") if record else None},
                 "next_slots": [{"utc": slot.isoformat().replace("+00:00", "Z"),
                                 "local": _local_utc(slot, parsed["_zone"])} for slot in slots],
                 "active_run": state.get("active_run")}
        if args.json:
            print(json.dumps(value, sort_keys=True))
        else:
            print(f"{name}: {loop['run']['mode']} {loop['run'].get('target', loop['run'].get('agent', ''))}; "
                  f"approval={'approved' if approved else 'unapproved'}")
            print(json.dumps(loop, indent=2, sort_keys=True))
            for index, slot in enumerate(slots, 1):
                print(f"next {index}: {_local_utc(slot, parsed['_zone'])}")
            print(f"active run: {state.get('active_run') or '-'}")
    elif action == "log":
        if args.limit < 1:
            raise ValueError("--limit must be a positive integer")
        path = loop_state._safe_path(main_checkout, ".nogging/state/loops/runs.jsonl")
        rows = []
        if path.exists():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except ValueError as exc:
                    raise ValueError(f"invalid run log {path} line {number}: {exc}") from exc
                if isinstance(row, dict) and row.get("loop") == name:
                    rows.append(row)
        rows = list(reversed(rows[-args.limit:]))
        if args.json:
            print(json.dumps({"schema_version": 1, "loop": name, "runs": rows}, sort_keys=True))
        else:
            for row in rows:
                print(json.dumps(row, sort_keys=True))
