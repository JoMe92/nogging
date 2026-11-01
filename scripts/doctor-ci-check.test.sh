#!/usr/bin/env bash
# `doctor` and the CI reality check (TASK-TPC-004, design Decision 11): a stubbed `gh` on
# PATH, a throwaway repository, and the same exit code in every case.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

source = Path(sys.argv[1]).resolve()

with tempfile.TemporaryDirectory(prefix="doctor-ci-") as temp:
    temp_dir = Path(temp).resolve()
    repo = temp_dir / "repo"
    repo.mkdir()
    git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    git("config", "user.name", "Test")
    git("config", "user.email", "test@test.local")
    git("commit", "--allow-empty", "-qm", "init")
    (repo / "scripts").mkdir()
    shutil.copy2(source / "scripts/nogg", repo / "scripts/nogg")
    (repo / "scripts/nogg").chmod(0o755)
    shutil.copytree(source / "scripts/lib", repo / "scripts/lib")
    for name in ("session-launch", "session-log-writer", "openspec-sandbox", "session-pty-recorder"):
        shutil.copy2(source / "scripts" / name, repo / "scripts" / name)
    (repo / ".nogging").mkdir()
    (repo / ".nogging/config.json").write_text(json.dumps(
        {"beads_command": "bd", "session_state_dir": ".nogging/state/sessions"}))

    stubs = temp_dir / "stubs"
    stubs.mkdir()
    for tool in ("dolt", "bd"):
        body = "echo '[]'" if tool == "bd" else "true"
        (stubs / tool).write_text(f"#!/usr/bin/env bash\n{body}\nexit 0\n")
        (stubs / tool).chmod(0o755)
    gh_log = temp_dir / "gh.log"
    gh_dir = temp_dir / "gh-data"
    gh_dir.mkdir()
    (stubs / "gh").write_text(
        "#!/usr/bin/env bash\n"
        f'echo "$*" >> "{gh_log}"\n'
        f'[ -e "{gh_dir}/offline" ] && exit 1\n'
        'if [ "$1 $2" = "run list" ]; then cat "' + str(gh_dir) + '/runs.json"; exit 0; fi\n'
        'if [ "$1 $2" = "run view" ]; then cat "' + str(gh_dir) + '/jobs-$3.json"; exit 0; fi\n'
        "exit 1\n")
    (stubs / "gh").chmod(0o755)

    env = os.environ.copy()
    env["NOGGING_ROOT"] = str(repo)
    env["PATH"] = f"{stubs}:{os.environ.get('PATH', '')}"

    def doctor():
        return subprocess.run([str(repo / "scripts/nogg"), "doctor"], cwd=repo, env=env,
                              text=True, capture_output=True, timeout=120)

    def gh_calls():
        return gh_log.read_text().splitlines() if gh_log.exists() else []

    def reset():
        gh_log.unlink(missing_ok=True)
        (gh_dir / "offline").unlink(missing_ok=True)
        cache = repo / ".nogging/state/testing/ci-check.json"
        cache.unlink(missing_ok=True)

    def runs(*items):
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))
        data = [{"databaseId": i, "headBranch": "develop", "event": "push", "createdAt": now}
                for i in items]
        (gh_dir / "runs.json").write_text(json.dumps(data))

    def jobs(run_id, *names_and_conclusions):
        (gh_dir / f"jobs-{run_id}.json").write_text(json.dumps(
            {"jobs": [{"name": n, "conclusion": c} for n, c in names_and_conclusions]}))

    def ci_lines(res):
        return [l for l in (res.stdout + res.stderr).splitlines() if "CI" in l and ("WARN" in l or "NOTE" in l)
                and ("job matching" in l or "none is configured" in l or "no test job" in l)]

    baseline = doctor()
    base_code = baseline.returncode

    # No CI configured: a NOTE naming the nightly fallback, no WARN, no gh at all.
    reset()
    res = doctor()
    lines = ci_lines(res)
    assert len(lines) == 1 and lines[0].startswith("NOTE") and "nightly fallback" in lines[0], res.stdout
    assert gh_calls() == [], gh_calls()
    assert res.returncode == base_code

    # The same gap names the timer to enable, with its service, until a run is recorded.
    def enable_notes(res):
        return [l for l in res.stdout.splitlines() if l.startswith("NOTE") and "enable the timer" in l]

    def nightly_warnings(res):
        return [l for l in res.stdout.splitlines() if l.startswith("WARN") and "nightly:" in l]

    timer = enable_notes(res)
    assert len(timer) == 1 and "systemctl --user link" in timer[0] and "systemd/nogg-nightly-" in timer[0], res.stdout

    nightly_last = repo / ".nogging/state/testing/nightly-last.json"
    nightly_last.parent.mkdir(parents=True, exist_ok=True)

    def nightly_record(status):
        nightly_last.write_text(json.dumps(
            {"schema": 1, "run_id": "r1", "at": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
             "status": status, "head": "0123456789abcdef0123", "seconds": 1, "failed": ["tests/a"],
             "log": ".nogging/state/testing/nightly-last.log"}))

    # A failed last run is a WARN with the commit and the log, and no exit code.
    nightly_record("failed")
    res = doctor()
    warned = nightly_warnings(res)
    assert len(warned) == 1 and "0123456789ab" in warned[0] and "nightly-last.log" in warned[0], res.stdout
    assert not enable_notes(res) and res.returncode == base_code, res.stdout

    # A passing last run is quiet: the fallback works.
    nightly_record("passed")
    res = doctor()
    assert not nightly_warnings(res) and not enable_notes(res), res.stdout
    assert res.returncode == base_code
    nightly_last.unlink()

    # A workflow exists but the checkout has no GitHub remote: nothing printed, no gh call.
    (repo / ".github/workflows").mkdir(parents=True)
    (repo / ".github/workflows/ci.yml").write_text("name: ci\non: push\n")
    reset()
    res = doctor()
    assert not ci_lines(res), res.stdout
    assert gh_calls() == [], gh_calls()
    assert res.returncode == base_code

    git("remote", "add", "origin", "https://github.com/example/example.git")

    # A workflow that never runs tests -> WARN naming the branch and the fallback.
    reset()
    runs(11)
    jobs(11, ("lint", "success"), ("build", "success"))
    res = doctor()
    lines = ci_lines(res)
    assert len(lines) == 1 and lines[0].startswith("WARN"), res.stdout
    assert "develop" in lines[0] and "'test'" in lines[0] and "nightly fallback" in lines[0], lines
    assert res.returncode == base_code, (res.returncode, base_code)

    # A cached result: a second doctor calls no gh command.
    before = len(gh_calls())
    res = doctor()
    assert len(ci_lines(res)) == 1 and len(gh_calls()) == before, gh_calls()

    # A red test job counts as having run: nothing printed.
    reset()
    runs(12)
    jobs(12, ("unit test", "failure"))
    res = doctor()
    assert not ci_lines(res), res.stdout
    assert res.returncode == base_code

    # Offline with no cache: nothing printed, the exit code is unchanged.
    reset()
    (gh_dir / "offline").write_text("")
    res = doctor()
    assert not ci_lines(res), res.stdout
    assert res.returncode == base_code

    # Offline with an expired cached WARN: it keeps its own line with its age.
    reset()
    cache = repo / ".nogging/state/testing/ci-check.json"
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps({"result": "none", "last_test_at": None, "checked_at": time.time() - 2 * 86400,
                                 "branch": "develop", "job_pattern": "test"}))
    (gh_dir / "offline").write_text("")
    res = doctor()
    lines = ci_lines(res)
    assert len(lines) == 1 and "2 d ago" in lines[0], res.stdout
    assert res.returncode == base_code
print("doctor-ci-check: ok")
PY
