"""The heavy-test slots: one host-wide `flock` set under a fixed path.

The path is fixed rather than `$TMPDIR`, because a per-session `TMPDIR` would
split the cap, and it is not under `$HOME`, which a sandboxed session cannot
write. `flock` binds to the inode, so a slot works across repositories, worktrees
and the namespaces of a fenced session; the kernel frees it when the holder dies,
however it dies, so nothing goes stale. Python descriptors are close-on-exec, so
a stray daemon started by a test cannot keep a slot.

A limit is load management, not a safety boundary: when the directory cannot be
used the caller runs without a slot and says so.
"""
from __future__ import annotations

import fcntl
import os
import re
import stat
import time

POLL_SECONDS = 5
STAGE_RE = re.compile(r"[a-z0-9-]{1,32}")
# A test keeps real slots out of its fixtures, and may only shorten the poll.
ROOT_OVERRIDE = "NOGG_TEST_SLOT_ROOT"
POLL_OVERRIDE = "NOGG_TEST_SLOT_POLL_SECONDS"


class SlotsUnusable(Exception):
    """The slot directory or a slot file cannot be used."""


def slot_root(environ=None, uid=None):
    environ = os.environ if environ is None else environ
    return environ.get(ROOT_OVERRIDE) or f"/tmp/nogg-test-slots-{os.getuid() if uid is None else uid}"


def poll_seconds(environ=None):
    environ = os.environ if environ is None else environ
    try:
        override = float(environ.get(POLL_OVERRIDE, POLL_SECONDS))
    except ValueError:
        return POLL_SECONDS
    return override if 0 < override < POLL_SECONDS else POLL_SECONDS


def prepare(root):
    """Make sure `root` is a private directory of ours. `/tmp` is world-writable,
    so a name someone else created first is refused rather than trusted."""
    try:
        os.mkdir(root, 0o700)
    except FileExistsError:
        pass
    except OSError as exc:
        raise SlotsUnusable(f"cannot create {root}: {exc.strerror}") from exc
    try:
        info = os.lstat(root)
    except OSError as exc:
        raise SlotsUnusable(f"cannot read {root}: {exc.strerror}") from exc
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise SlotsUnusable(f"{root} is not a private directory of this user")


def _open_slot(root, number):
    path = f"{root}/slot.{number}"
    try:
        return os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as exc:
        raise SlotsUnusable(f"cannot open {path}: {exc.strerror}") from exc


def try_acquire(root, count, stage):
    """The descriptor of a slot taken now, or None when every slot is held. The
    holder keeps the descriptor open for the whole run; its stage is written into
    the slot, so a run that gives up can name what it waited for."""
    for number in range(1, count + 1):
        fd = _open_slot(root, number)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            continue
        except OSError as exc:
            os.close(fd)
            raise SlotsUnusable(f"cannot lock {root}/slot.{number}: {exc.strerror}") from exc
        try:
            os.ftruncate(fd, 0)
            os.pwrite(fd, stage.encode(), 0)
        except OSError:
            pass   # the name is a courtesy; the lock is the slot
        return fd
    return None


def holders(root, count):
    """The stages holding slots right now, in slot order; `unknown` for a holder
    that wrote no valid name."""
    stages = []
    for number in range(1, count + 1):
        try:
            fd = os.open(f"{root}/slot.{number}", os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            continue
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                name = os.read(fd, 64).decode("ascii", "replace")
                stages.append(name if STAGE_RE.fullmatch(name) else "unknown")
            except OSError:
                continue
        finally:
            os.close(fd)
    return stages


def acquire(root, count, stage, wait_seconds, on_wait=None, poll=POLL_SECONDS,
            clock=time.monotonic, sleep=time.sleep):
    """`(fd, waited_seconds)`, with fd None when the wait ran out. `on_wait` runs
    once, when the wait starts. Raises SlotsUnusable when the slots cannot be used."""
    prepare(root)
    start = clock()
    fd = try_acquire(root, count, stage)
    if fd is not None:
        return fd, 0.0
    if on_wait:
        on_wait(holders(root, count))
    while True:
        remaining = wait_seconds - (clock() - start)
        if remaining <= 0:
            return None, clock() - start
        sleep(min(poll, remaining))
        fd = try_acquire(root, count, stage)
        if fd is not None:
            return fd, clock() - start
