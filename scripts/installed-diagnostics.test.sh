#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import json, os, pathlib, re, subprocess, sys, tempfile

source = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="nogg installed diagnostics ") as directory:
    consumer = pathlib.Path(directory) / "consumer"
    consumer.mkdir()
    subprocess.run(["git", "init", "-q", str(consumer)], check=True)
    env = os.environ.copy()
    env.pop("NOGGING_ROOT", None)
    env.pop("NOGG_SESSION_NAME", None)
    subprocess.run(["node", str(source / "bin/cli.js"), "init", "--no-beads",
                    "--no-systemd", "--no-hooks"], cwd=consumer, env=env,
                   stdout=subprocess.DEVNULL, check=True)
    config = json.loads((consumer / ".nogging/config.json").read_text())
    assert "claim_stale_seconds" not in config
    # Exercise the actual installed self-tests with the minimal consumer config.
    result = subprocess.run([str(consumer / "scripts/test")], cwd=consumer,
                            env=env, text=True, capture_output=True, timeout=180)
    if result.returncode:
        print(result.stdout + result.stderr)
        raise AssertionError("installed self-tests failed with supported optional defaults")
    for document in (consumer / "docs/nogging").glob("*.md"):
        for target in re.findall(r"\]\(([^)]+)\)", document.read_text()):
            target = target.split("#", 1)[0]
            if not target or re.match(r"[a-zA-Z][\w+.-]*:", target):
                continue
            assert (document.parent / target).exists(), f"broken installed link: {document.name}: {target}"
    env["NOGGING_ROOT"] = str(consumer)
    # Import only the diagnostic layer: host tools/tracker are irrelevant here.
    probe = ('from importlib.machinery import SourceFileLoader; import json,sys; '
             'm=SourceFileLoader("diagnostics",sys.argv[1]).load_module(); '
             'print(json.dumps(m.session_helper_diagnostics()))')
    def checks():
        return json.loads(subprocess.check_output(
            [sys.executable, "-c", probe, str(consumer / "scripts/nogg")], env=env, text=True))
    assert all(ok for _, ok in checks())
    launcher = consumer / "scripts/session-launch"
    original = launcher.read_bytes()
    launcher.unlink()
    assert any(not ok and "session-launch" in name and "missing" in name for name, ok in checks())
    launcher.write_bytes(original)
    launcher.chmod(0o644)
    assert any(not ok and "not executable" in name for name, ok in checks())
    launcher.chmod(0o755)
    contract = json.loads(subprocess.check_output([str(launcher), "--contract"], text=True))
    contract["options"].pop("--resume")
    launcher.write_text('#!/usr/bin/env python3\nprint(' + repr(json.dumps(contract)) + ')\n')
    assert any(not ok and "--resume" in name for name, ok in checks())
    launcher.write_bytes(original)
    writer = consumer / "scripts/session-log-writer"
    writer.unlink()
    assert any(not ok and "session-log-writer" in name for name, ok in checks())
    verdict = subprocess.run([str(consumer / "scripts/nogg"), "doctor"], cwd=consumer,
                             env=env, text=True, capture_output=True, timeout=10)
    assert verdict.returncode != 0
    assert any(line.startswith("FAIL") and "session-log-writer" in line
               for line in verdict.stdout.splitlines())
    assert "Traceback" not in verdict.stderr
print("installed minimal-config self-tests, documentation links and helper diagnostics: ok")
PY
