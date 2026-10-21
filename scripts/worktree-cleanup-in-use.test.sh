#!/usr/bin/env bash
# fixture-backend-pin: allow - cleanup only; launches no session
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/test-env.sh"
unset HERDR_* TMUX TMUX_TMPDIR

python3 - "$repo_root/scripts/nogg" "$repo_root/.nogging/config.json" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch

nogg_path, config_path = sys.argv[1:]
checks = 0

def check(condition, message):
    global checks
    checks += 1
    if not condition:
        raise AssertionError(message)

def git(path, *args):
    return subprocess.run(["git", "-C", str(path), *args], check=True,
                          text=True, capture_output=True).stdout.strip()

def fixture():
    temp = tempfile.TemporaryDirectory(prefix="worktree-cleanup-in-use-")
    root = Path(temp.name) / "repo"
    worktree = Path(temp.name) / "linked"
    (root / ".nogging/state/worktrees").mkdir(parents=True)
    (root / ".nogging/state/sessions").mkdir(parents=True)
    (root / ".nogging/config.json").write_text(Path(config_path).read_text())
    subprocess.run(["git", "init", "-q", "-b", "develop", str(root)], check=True)
    git(root, "config", "user.name", "Worktree Test")
    git(root, "config", "user.email", "worktree-test@example.invalid")
    (root / "tracked.txt").write_text("base\n")
    git(root, "add", "tracked.txt")
    git(root, "commit", "-q", "-m", "chore: fixture [SPEC-test]")
    subprocess.run(["git", "-C", str(root), "worktree", "add", "-q", "-b",
                    "fix/fixture", str(worktree)], check=True)
    (worktree / "tracked.txt").write_text("integrated\n")
    git(worktree, "commit", "-qam", "fix: fixture [SPEC-test]")
    git(root, "merge", "-q", "--ff-only", "fix/fixture")
    record_path = root / ".nogging/state/worktrees/implementation--fixture.json"
    record = {"path": str(worktree), "branch": "fix/fixture", "kind": "implementation"}
    record_path.write_text(json.dumps(record, sort_keys=True) + "\n")
    os.environ["NOGGING_ROOT"] = str(root)
    module = SourceFileLoader("nogg_cleanup_test", nogg_path).load_module()
    return temp, root, worktree, record_path, module

def assert_refused(case, points=None, session=None, cwd=None, cwd_inside=False, unreadable=False):
    temp, root, worktree, record_path, module = fixture()
    try:
        tracked_before = (worktree / "tracked.txt").read_bytes()
        branch_before = git(root, "rev-parse", "refs/heads/fix/fixture")
        record_before = record_path.read_bytes()
        if session:
            directory = root / ".nogging/state/sessions"
            session_record = dict(session)
            if session_record.get("working_dir") == "$nested":
                session_record["working_dir"] = str(worktree / "nested")
            (directory / "active.json").write_text(json.dumps(session_record))
        if unreadable:
            def failed_mount_read():
                raise OSError("injected read failure")
            module.mount_points = failed_mount_read
        else:
            gitdir = Path(git(worktree, "rev-parse", "--absolute-git-dir"))
            values = {"$worktree": worktree, "$nested": worktree / "nested", "$gitdir": gitdir}
            module.mount_points = lambda: {
                str(Path(values.get(point, point)).resolve()) for point in (points or [])
            }
        caller_cwd = worktree / "nested" if cwd_inside else (cwd or root)
        with patch.object(module.os, "getcwd", return_value=str(caller_cwd)):
            try:
                module.cleanup_worktree(record_path.name)
            except RuntimeError as exc:
                error = str(exc)
            else:
                raise AssertionError(f"{case}: cleanup unexpectedly succeeded")
        check(worktree.is_dir(), f"{case}: worktree directory was removed")
        check((worktree / "tracked.txt").read_bytes() == tracked_before,
              f"{case}: tracked file changed")
        check(git(root, "rev-parse", "refs/heads/fix/fixture") == branch_before,
              f"{case}: branch changed")
        check(record_path.read_bytes() == record_before, f"{case}: record changed")
        check(case in error, f"{case}: expected refusal detail, got: {error}")
    finally:
        temp.cleanup()
        os.environ.pop("NOGGING_ROOT", None)

assert_refused("mounted into this process's sandbox", points=["$worktree"])
assert_refused("mounted into this process's sandbox", points=["$nested"])
assert_refused("mounted into this process's sandbox", points=["$gitdir"])
assert_refused("cannot read the mount table", unreadable=True)
assert_refused("current directory", cwd_inside=True)
assert_refused("active session active-one", session={
    "name": "active-one", "state": "running", "working_dir": "$nested"})

temp, root, worktree, record_path, module = fixture()
try:
    (root / ".nogging/state/sessions/owner.json").write_text(json.dumps({
        "name": "owner", "state": "idle", "working_dir": str(worktree)}))
    module.mount_points = lambda: set()
    os.environ["NOGG_SESSION_NAME"] = "owner"
    module.cleanup_worktree(record_path.name)
    check(not worktree.exists(), "own active session record incorrectly blocked cleanup")
    check(not record_path.exists(), "successful cleanup retained its worktree record")
finally:
    temp.cleanup()
    os.environ.pop("NOGG_SESSION_NAME", None)
    os.environ.pop("NOGGING_ROOT", None)
print(f"worktree cleanup in-use guards: ok ({checks} invariants)")
PY
