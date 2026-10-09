#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
import json, os, pathlib, shutil, subprocess, sys, tempfile

source = pathlib.Path(sys.argv[1])
nogg = str(source / "scripts/nogg")
with tempfile.TemporaryDirectory(prefix="nogg discovery acknowledgements ") as directory:
    scratch = pathlib.Path(directory)
    main, first, second = (scratch / name for name in ("main", "first worktree", "second worktree"))
    subprocess.run(["git", "init", "-q", str(main)], check=True)
    (main / ".nogging").mkdir()
    tracker = scratch / "bd"
    tracker.write_text('''#!/usr/bin/env python3
import json, os, sys
issues = json.load(open(os.environ["ACK_FIXTURE"]))
if sys.argv[1] == "list":
    print(json.dumps(issues))
elif sys.argv[1] == "show":
    print(json.dumps([i for i in issues if i["id"] == sys.argv[2]]))
else:
    sys.exit(77)
''')
    tracker.chmod(0o755)
    config = json.loads((source / ".nogging/config.json").read_text())
    config["beads_command"] = str(tracker)
    (main / ".nogging/config.json").write_text(json.dumps(config))
    (main / ".gitignore").write_text(".nogging/state/\n.nogging/locks/\n")
    subprocess.run(["git", "-C", str(main), "add", "."], check=True)
    subprocess.run(["git", "-C", str(main), "-c", "user.name=Fixture", "-c",
                    "user.email=fixture@example.invalid", "commit", "-qm", "seed"], check=True)
    for path in (first, second):
        subprocess.run(["git", "-C", str(main), "worktree", "add", "-q", "--detach", str(path)], check=True)
    ledger = main / ".nogging/state/acknowledged-discoveries.json"
    ledger.parent.mkdir()
    ledger.write_text(json.dumps({"SPEC-main": "2020-01-01T00:00:00+00:00", "SPEC-duplicate": "2024-01-01T00:00:00+00:00"}))
    legacy = {}
    for path, bid, year in ((first, "SPEC-first", 2022), (second, "SPEC-second", 2023)):
        local = path / ".nogging/state/acknowledged-discoveries.json"
        local.parent.mkdir()
        local.write_text(json.dumps({bid: f"{year}-01-01T00:00:00+00:00", "SPEC-duplicate": f"{year}-01-01T00:00:00+00:00"}))
        legacy[path] = local.read_bytes()
    issues = [dict(id=bid, title=bid, notes="human fixture note", status=status, labels=["discovery"])
              for bid, status in (("SPEC-main", "closed"), ("SPEC-first", "closed"),
                                  ("SPEC-second", "open"), ("SPEC-duplicate", "closed"),
                                  ("SPEC-unreviewed-blocked", "blocked"), ("SPEC-unreviewed-open", "open"))]
    fixture = scratch / "issues.json"
    fixture.write_text(json.dumps(issues))
    def env_for(path):
        env = os.environ.copy()
        env.update(NOGGING_ROOT=str(path), ACK_FIXTURE=str(fixture))
        return env
    def call(path, *args, check=True):
        return subprocess.run([nogg, "discoveries", *args], env=env_for(path),
                              text=True, capture_output=True, check=check)
    call(first)
    call(second)
    merged = json.loads(ledger.read_text())
    assert set(merged) == {"SPEC-main", "SPEC-first", "SPEC-second", "SPEC-duplicate"}
    assert merged["SPEC-duplicate"].startswith("2022-")
    backups = ledger.parent / "acknowledged-discoveries.backups"
    saved = {p.read_bytes() for p in backups.glob("*.json")}
    assert all(raw in saved for raw in legacy.values())
    # Concurrent read/merge/write transactions must preserve every addition.
    def worker(index):
        call((main, first, second)[index % 3], "--ack", f"SPEC-concurrent-{index}")
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(worker, range(16)))
    assert all(f"SPEC-concurrent-{index}" in json.loads(ledger.read_text()) for index in range(16))
    # Interrupt the final atomic replacement after backups and temp-file flush.
    previous_env = os.environ.get("NOGGING_ROOT")
    os.environ["NOGGING_ROOT"] = str(first)
    try:
        m = SourceFileLoader("ack_fault", nogg).load_module()
    finally:
        if previous_env is None:
            os.environ.pop("NOGGING_ROOT", None)
        else:
            os.environ["NOGGING_ROOT"] = previous_env
    original = ledger.read_bytes()
    real_replace = os.replace
    def interrupted(src, dst):
        if pathlib.Path(dst) == ledger:
            raise OSError("simulated interruption before commit")
        return real_replace(src, dst)
    with patch.object(m.os, "replace", side_effect=interrupted):
        try:
            m.ack_discoveries(["SPEC-interrupted"])
        except OSError:
            pass
        else:
            raise AssertionError("interrupted write unexpectedly succeeded")
    assert ledger.read_bytes() == original
    assert not list(ledger.parent.glob(ledger.name + ".tmp-*"))
    assert original in {p.read_bytes() for p in backups.glob("*.json")}
    call(second, "--ack", "SPEC-recovered")
    assert "SPEC-recovered" in json.loads(ledger.read_text())
    # A malformed legacy ledger must never cause an existing canonical one to be erased.
    local = first / ".nogging/state/acknowledged-discoveries.json"
    local.write_text("{interrupted legacy JSON")
    original = ledger.read_bytes()
    refusal = call(first, "--ack", "SPEC-refused", check=False)
    assert refusal.returncode and "malformed" in refusal.stderr
    assert ledger.read_bytes() == original
    local.write_bytes(legacy[first])
    # Removing the acknowledging worktree leaves the durable review state intact.
    subprocess.run(["git", "-C", str(main), "worktree", "remove", str(first)], check=True)
    for path in (main, second):
        output = call(path).stdout
        for bid in ("SPEC-main", "SPEC-first", "SPEC-second", "SPEC-duplicate"):
            assert bid not in output
        assert output.index("SPEC-unreviewed-blocked") < output.index("SPEC-unreviewed-open")
        assert "human fixture note" in output
    assert json.loads(ledger.read_text())["SPEC-duplicate"].startswith("2022-")
print("shared acknowledgement migration, backups, concurrent writes, interruption and worktree retirement: ok")
PY
