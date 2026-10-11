#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
import json, os, pathlib, shutil, subprocess, sys, tempfile

source = pathlib.Path(sys.argv[1])
m = SourceFileLoader("repository_state", str(source / "scripts/nogg")).load_module()
with tempfile.TemporaryDirectory(prefix="nogg shared state ") as directory:
    scratch = pathlib.Path(directory)
    main, linked = scratch / "main checkout ", scratch / "linked checkout "
    subprocess.run(["git", "init", "-q", str(main)], check=True)
    (main / ".nogging").mkdir()
    shutil.copy2(source / ".nogging/config.json", main / ".nogging/config.json")
    (main / ".gitignore").write_text(".nogging/state/\n.nogging/locks/\n")
    subprocess.run(["git", "-C", str(main), "add", "."], check=True)
    subprocess.run(["git", "-C", str(main), "-c", "user.name=Fixture", "-c",
                    "user.email=fixture@example.invalid", "commit", "-qm", "seed"], check=True)
    subprocess.run(["git", "-C", str(main), "worktree", "add", "-q", "--detach", str(linked)], check=True)
    nested = linked / "nested directory"
    nested.mkdir()
    for cwd in (main, linked, nested):
        state = m.canonical_repository_state(cwd)
        assert pathlib.Path(state["main_checkout"]) == main
        assert pathlib.Path(state["common_dir"]) == main / ".git"
        assert pathlib.Path(state["locks_dir"]) == main / ".nogging/locks"
        assert pathlib.Path(state["state_dir"]) == main / ".nogging/state"
    assert not (main / ".nogging/state").exists()
    assert not (main / ".nogging/locks").exists()
    assert not (linked / ".nogging/state").exists()
    # Exercise the older Git relative-common-dir fallback against real Git.
    real_run = subprocess.run
    def old_git(args, **kwargs):
        if "--path-format=absolute" in args:
            return subprocess.CompletedProcess(args, 0, "--path-format=absolute\n.git\n", "")
        return real_run(args, **kwargs)
    with patch.object(m.subprocess, "run", side_effect=old_git):
        assert m.canonical_repository_state(main)["common_dir"] == str(main / ".git")
    for cwd in (scratch, scratch / "missing"):
        try:
            m.canonical_repository_state(cwd)
        except RuntimeError:
            pass
        else:
            raise AssertionError("non-Git path accepted")
    bare = scratch / "bare.git"
    subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True)
    separate, storage = scratch / "separate checkout", scratch / "git storage"
    subprocess.run(["git", "init", "-q", "--separate-git-dir", str(storage), str(separate)], check=True)
    for cwd in (bare, separate):
        try:
            m.canonical_repository_state(cwd)
        except RuntimeError:
            pass
        else:
            raise AssertionError("unsupported layout accepted")
    env = os.environ.copy()
    env["NOGGING_ROOT"] = str(linked)
    nogg = str(source / "scripts/nogg")
    probe = ('from importlib.machinery import SourceFileLoader; import sys; '
             'm=SourceFileLoader("locations",sys.argv[1]).load_module(); '
             'assert str(m.STATE)==sys.argv[2]+"/.nogging/state"; '
             'assert str(m.LOCKS)==sys.argv[2]+"/.nogging/locks"; '
             'assert str(m.PLANNING_LOCKS)==sys.argv[3]+"/.nogging/locks"')
    subprocess.run([sys.executable, "-c", probe, nogg, str(linked), str(main)], env=env, check=True)
    subprocess.run([nogg, "plan-begin"], env=env, stdout=subprocess.DEVNULL, check=True)
    assert (main / ".nogging/locks/planning.lock").is_file()
    assert not (linked / ".nogging/locks").exists()
    second = env.copy()
    second["NOGGING_ROOT"] = str(main)
    collision = subprocess.run([nogg, "plan-begin"], env=second, capture_output=True)
    assert collision.returncode != 0
    subprocess.run([nogg, "discoveries", "--ack", "SPEC-shared"], env=env,
                   stdout=subprocess.DEVNULL, check=True)
    assert "SPEC-shared" in json.loads((main / ".nogging/state/acknowledged-discoveries.json").read_text())
    subprocess.run([nogg, "plan-end"], env=env, stdout=subprocess.DEVNULL, check=True)
    assert (main / ".nogging/locks/openspec.readonly").is_file()
    assert not (main / ".nogging/locks/planning.lock").exists()
    guard_env = env.copy()
    guard_env["CLAUDE_PROJECT_DIR"] = str(linked)
    blocked = subprocess.run([str(source / "scripts/hooks/pre-tool-use-openspec-guard")],
                             env=guard_env, input=json.dumps({"tool_input": {"file_path": "openspec/project.md"}}),
                             text=True, capture_output=True)
    assert blocked.returncode == 2 and "sentinel" in blocked.stderr
print("canonical main/linked/nested/relative Git state, unsupported layouts and shared boundary: ok")
PY
