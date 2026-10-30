"""Host-local, atomic state and approval helpers for scheduled loops."""
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
from datetime import datetime, timezone
import pwd

import loop_config


def _atomic_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True,
                      default=lambda item: item.isoformat().replace("+00:00", "Z")
                      if isinstance(item, datetime) else str(item))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def read_json(path: Path, default):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read host loop state {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"malformed host loop state {path}: expected an object")
    return value


def state_path(main_checkout) -> Path:
    return _safe_path(main_checkout, ".nogging/state/loops/state.json")


def approvals_path(main_checkout) -> Path:
    return _safe_path(main_checkout, ".nogging/state/loops/approvals.json")


def _safe_path(main_checkout, relative):
    root = Path(main_checkout).resolve()
    path = root / relative
    if not path.resolve().is_relative_to(root):
        raise ValueError(f"loop state path must remain under the main checkout: {path}")
    return path


def prompt_path(main_checkout, definitions_path, name):
    path = loop_config.prompt_path(definitions_path, name)
    if not path.resolve().is_relative_to(Path(main_checkout).resolve()):
        raise ValueError(f"loop prompt path must remain under the main checkout: {path}")
    return path


def read_state(main_checkout):
    return read_json(state_path(main_checkout), {"schema_version": 1, "loops": {}})


def write_state(main_checkout, value):
    _atomic_json(state_path(main_checkout), value)


def _prompt_bytes(main_checkout, definitions_path, name):
    prompt = prompt_path(main_checkout, definitions_path, name)
    loop_config.check_prompt(prompt)
    return prompt.read_bytes()


def current_hash(main_checkout, definitions_path, config, name):
    return loop_config.approval_hash(config["timezone"], config["loops"][name],
                                     _prompt_bytes(main_checkout, definitions_path, name))


def approval_status(main_checkout, definitions_path, config, name):
    entry = read_json(approvals_path(main_checkout), {"schema_version": 1, "loops": {}})
    record = entry.get("loops", {}).get(name)
    if not isinstance(record, dict):
        return False, None
    try:
        expected = current_hash(main_checkout, definitions_path, config, name)
    except (OSError, ValueError):
        return False, record
    return record.get("sha256") == expected, record


def approve(main_checkout, definitions_path, config, name, *, at=None, user=None):
    digest = current_hash(main_checkout, definitions_path, config, name)
    path = approvals_path(main_checkout)
    ledger = read_json(path, {"schema_version": 1, "loops": {}})
    loops = ledger.setdefault("loops", {})
    loops[name] = {"sha256": digest,
                   "approved_at": at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                   "user": user or _os_username()}
    ledger["schema_version"] = 1
    _atomic_json(path, ledger)
    return digest


def _os_username():
    name = pwd.getpwuid(os.getuid()).pw_name
    return str(os.getuid()) if "@" in name else name


def remove_approval(main_checkout, name):
    path = approvals_path(main_checkout)
    ledger = read_json(path, {"schema_version": 1, "loops": {}})
    if ledger.get("loops", {}).pop(name, None) is not None:
        _atomic_json(path, ledger)
