#!/usr/bin/env bash
# Live supported-runtime session liveness acceptance (TASK-CSL-006, #37-#42).
#
# Covers live acceptance behaviors across supported runtimes and launcher:
#   - First-time launch/kickoff:
#     - Blocked Bead launch refusal before tmux or record creation (#37)
#     - Bare Lead launch emits restricted warning (#38) & kickoff hint (#39)
#     - session kickoff delivers message and records authorized change (#39)
#     - launch with --kickoff delivers kickoff and suppresses hint (#39)
#     - --full-access sets bypassPermissions, accepts disclaimer, preserves floor deny (#40)
#   - Blocked sibling:
#     - Unrelated blocked sibling does not classify runnable assigned work as bead-blocked (#41)
#     - Authorized whole-change scope surfaces change-wide blocker (#41)
#   - Two consecutive ready Beads in one authorized change:
#     - sweep reports active while working first Bead (#41)
#     - sweep stays active when first Bead closes and second Bead is ready (#41)
#     - nudge without --message on empty/placeholder pane executes nothing (#42)
#     - nudge with --message clears and delivers explicit instruction (#42)
#     - change-complete reported once all mapped Beads closed and integration evidenced (#41)
#   - CI transition:
#     - session sweep --checks observes CI passing and reports unchecked (#41)
#     - session checks-ack explicitly acknowledges fingerprint (#41)
#     - transition to new failing CI run resets state to unchecked (#41)
#     - nogg doctor reuses cached checks failure offline without network calls (#41)
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v tmux >/dev/null || ! command -v npm >/dev/null; then
  printf 'SKIP: session liveness acceptance (tmux or npm unavailable)\n'
  exit 0
fi

python3 - "$root" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, tarfile, tempfile, time, uuid

# The installed launcher uses the Linux mount boundary openspec-sandbox;
# mirror packed-session-launch on hosts that prohibit user namespaces.
probe = subprocess.run(['unshare', '--user', '--map-root-user', '--mount', 'true'],
                       capture_output=True)
if probe.returncode:
    print('SKIP: session liveness acceptance (host denies Linux user/mount namespaces)')
    sys.exit(0)

source = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="nogg liveness acc ") as directory:
    scratch = pathlib.Path(directory)
    packed = json.loads(subprocess.check_output(
        ["npm", "pack", "--ignore-scripts", "--json", "--pack-destination", str(scratch)],
        cwd=source, text=True))[0]
    with tarfile.open(scratch / packed["filename"]) as archive:
        archive.extractall(scratch, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
    package = scratch / "package"
    consumer = scratch / "acceptance-consumer"
    consumer.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "develop", str(consumer)], check=True)
    subprocess.run(["git", "-C", str(consumer), "config", "user.name", "Nogging Lead"], check=True)
    subprocess.run(["git", "-C", str(consumer), "config", "user.email", "lead@nogging.bot"], check=True)

    env = {k: v for k, v in os.environ.items()
           if not k.startswith("NOGG_") and k != "NOGGING_ROOT"}
    subprocess.run(["node", str(package / "bin/cli.js"), "init", "--no-beads", "--no-hooks",
                    "--no-systemd"], cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True)

    sock = "nogg-acc-" + uuid.uuid4().hex
    config_path = consumer / ".nogging/config.json"
    config = json.loads(config_path.read_text())
    config.update(session_tmux_socket=sock, session_stop_grace_seconds=0.1,
                  beads_command=str(consumer / "stub-bin/bd"))
    config_path.write_text(json.dumps(config, indent=2))

    binaries = consumer / "stub-bin"
    binaries.mkdir()

    # bd state stored outside consumer git tree
    bd_db_file = scratch / "bd_db.json"
    bd_db = {
        "SPEC-csl1": {"id": "SPEC-csl1", "status": "in_progress", "labels": ["openspec:change:test-change", "openspec:task:TASK-CSL-1"], "dependencies": []},
        "SPEC-csl2": {"id": "SPEC-csl2", "status": "open", "labels": ["openspec:change:test-change", "openspec:task:TASK-CSL-2"], "dependencies": []},
        "SPEC-blocked-sib": {"id": "SPEC-blocked-sib", "status": "blocked", "labels": ["openspec:change:test-change", "openspec:task:TASK-CSL-3"], "dependencies": [{"id": "SPEC-ext", "status": "open", "type": "blocks"}]},
        "SPEC-dep-blocked": {"id": "SPEC-dep-blocked", "status": "open", "labels": ["openspec:change:test-change", "openspec:task:TASK-CSL-4"], "dependencies": [{"id": "SPEC-blocker", "status": "open", "type": "blocks"}]},
        "SPEC-ready": {"id": "SPEC-ready", "status": "open", "labels": ["openspec:change:test-change", "openspec:task:TASK-CSL-5"], "dependencies": [{"id": "SPEC-blocker", "status": "closed", "type": "blocks"}]},
        "SPEC-blocker": {"id": "SPEC-blocker", "status": "open", "labels": [], "dependencies": []},
        "SPEC-ext": {"id": "SPEC-ext", "status": "open", "labels": [], "dependencies": []},
    }
    bd_db_file.write_text(json.dumps(bd_db))

    bd_py = consumer / "stub-bin/bd.py"
    bd_py.write_text(f'''#!/usr/bin/env python3
import json, sys, pathlib

db_file = pathlib.Path("{bd_db_file}")
db = json.loads(db_file.read_text())

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "show":
    bid = sys.argv[2]
    item = db.get(bid)
    if item:
        print(json.dumps([item]))
        sys.exit(0)
    print("[]")
    sys.exit(1)
elif cmd == "dep" and sys.argv[2] == "list":
    bid = sys.argv[3]
    item = db.get(bid)
    deps = item.get("dependencies", []) if item else []
    print(json.dumps(deps))
    sys.exit(0)
elif cmd == "list":
    print(json.dumps(list(db.values())))
    sys.exit(0)
elif cmd == "close":
    bid = sys.argv[2]
    if bid in db:
        db[bid]["status"] = "closed"
        db_file.write_text(json.dumps(db))
    sys.exit(0)
sys.exit(1)
''')
    bd_py.chmod(0o755)

    bd_sh = binaries / "bd"
    bd_sh.write_text(f'#!/bin/sh\nexec python3 "{bd_py}" "$@"\n')
    bd_sh.chmod(0o755)

    runtime_py = consumer / "stub-bin/runtime.py"
    box = (
        "────────────────────────────────────────────────────────────────────────────────\n"
        "❯ \n"
        "────────────────────────────────────────────────────────────────────────────────\n"
        "   ⏵⏵ bypass permissions on\n"
    )
    runtime_py.write_text(f'''#!/usr/bin/env python3
import sys, time
if "--help" in sys.argv:
    print("stub runtime help")
    sys.exit(0)
print("stub agent started", flush=True)
sys.stdout.write({json.dumps(box)})
sys.stdout.flush()
while True:
    time.sleep(0.1)
''')
    runtime_py.chmod(0o755)

    for agent in ("claude", "codex", "pi"):
        a_sh = binaries / agent
        a_sh.write_text(f'#!/bin/sh\nexec python3 "{runtime_py}" "$@"\n')
        a_sh.chmod(0o755)

    gh_file = scratch / "gh_data.json"
    gh_data = {"rows": []}
    gh_file.write_text(json.dumps(gh_data))
    gh_py = binaries / "gh"
    gh_py.write_text(f'''#!/usr/bin/env python3
import json, sys, pathlib
df = pathlib.Path("{gh_file}")
if not df.exists():
    print("[]")
    sys.exit(0)
data = json.loads(df.read_text())
if "pr" in sys.argv and "list" in sys.argv:
    print(json.dumps(data.get("rows", [])))
    sys.exit(0)
sys.exit(1)
''')
    gh_py.chmod(0o755)

    os.environ["PATH"] = str(binaries) + os.pathsep + os.environ["PATH"]
    env.update(PATH=str(binaries) + os.pathsep + env["PATH"],
               NOGGING_ROOT=str(consumer),
               # The fixture runtime is a legacy stub: it paints a prompt but
               # does not redraw it as an interactive Claude CLI would.
               NOGG_TEST_ARGS_DIR=str(scratch))

    change_dir = consumer / "openspec/changes/test-change"
    change_dir.mkdir(parents=True)
    (change_dir / "tasks.md").write_text("""## 1. Implementation
- [ ] TASK-CSL-1 First task
- [ ] TASK-CSL-2 Second task
- [ ] TASK-CSL-3 Third task
- [ ] TASK-CSL-4 Fourth task
- [ ] TASK-CSL-5 Fifth task
""")
    (change_dir / "design.md").write_text("# Design\n")
    (change_dir / "proposal.md").write_text("# Proposal\n")

    subprocess.run(["git", "-C", str(consumer), "add", "."], check=True)
    subprocess.run(["git", "-C", str(consumer), "commit", "-q", "-m", "chore: initialize consumer"], check=True)

    nogg = consumer / "scripts/nogg"

    def run_nogg(*args):
        return subprocess.run([str(nogg)] + list(args), cwd=consumer, env=env, text=True, capture_output=True)

    try:
        # === 1. First-time launch & kickoff (#37, #38, #39, #40) ===
        # 1.1 Blocked launch refusal (#37)
        r_block = run_nogg("session", "launch", "--role", "lead", "--bead", "SPEC-dep-blocked", "--agent", "claude")
        assert "SPEC-dep-blocked has an unmet dependency on SPEC-blocker" in (r_block.stdout + r_block.stderr)

        # 1.2 Bare lead launch warning & kickoff hint (#38, #39)
        r_bare = run_nogg("session", "launch", "--role", "lead", "--bead", "SPEC-ready", "--agent", "claude")
        assert r_bare.returncode == 0
        assert "launched in restricted/manual mode" in r_bare.stdout
        assert "this session will not act until you send it a first message" in r_bare.stdout
        ready_recs = [json.loads(p.read_text()) for p in (consumer / ".nogging/state/sessions").glob("*.json")
                      if "spec-ready" in p.name.lower() and not p.name.endswith(".settings.json")
                      and json.loads(p.read_text()).get("state") == "running"]
        assert len(ready_recs) == 1
        ready_name = ready_recs[0]["name"]

        # The launcher records the session before the runtime has painted its
        # first prompt. Wait for the fixture runtime before exercising kickoff.
        startup_deadline = time.monotonic() + 5
        while time.monotonic() < startup_deadline:
            pane = subprocess.run(["tmux", "-L", sock, "capture-pane", "-t", ready_name, "-p"],
                                  text=True, capture_output=True).stdout
            if "stub agent started" in pane and "❯" in pane:
                break
            time.sleep(0.05)
        assert "stub agent started" in pane and "❯" in pane, f"runtime prompt did not appear: {pane!r}"

        # 1.3 Kickoff execution (#39)
        r_kick = run_nogg("session", "kickoff", ready_name, "--change", "test-change")
        assert r_kick.returncode == 0
        sess_data = json.loads((consumer / f".nogging/state/sessions/{ready_name}.json").read_text())
        assert sess_data.get("authorized_change") == "test-change"

        run_nogg("session", "stop", ready_name)
        run_nogg("session", "cleanup", ready_name)

        # 1.4 Launch with --kickoff (#39)
        r_with_kick = run_nogg("session", "launch", "--role", "lead", "--bead", "SPEC-ready", "--agent", "claude", "--kickoff")
        assert r_with_kick.returncode == 0
        assert "this session will not act until you send it a first message" not in r_with_kick.stdout
        with_kick_recs = [json.loads(p.read_text()) for p in (consumer / ".nogging/state/sessions").glob("*.json")
                          if "spec-ready" in p.name.lower() and not p.name.endswith(".settings.json")
                          and json.loads(p.read_text()).get("state") == "running"]
        assert len(with_kick_recs) == 1
        wk_name = with_kick_recs[0]["name"]
        run_nogg("session", "stop", wk_name)
        run_nogg("session", "cleanup", wk_name)

        # 1.5 Full-access launch (#38, #40)
        r_full = run_nogg("session", "launch", "--role", "lead", "--bead", "SPEC-ready", "--agent", "claude", "--full-access")
        assert r_full.returncode == 0
        assert "launched in restricted/manual mode" not in r_full.stdout
        full_recs = [json.loads(p.read_text()) for p in (consumer / ".nogging/state/sessions").glob("*.json")
                     if "spec-ready" in p.name.lower() and not p.name.endswith(".settings.json")
                     and json.loads(p.read_text()).get("state") == "running"]
        assert len(full_recs) == 1
        full_rec = full_recs[0]
        assert full_rec["profile"] == "trusted"
        settings = json.loads(pathlib.Path(full_rec["effective_settings_path"]).read_text())
        assert settings["permissions"]["defaultMode"] == "bypassPermissions"
        assert settings.get("skipDangerousModePermissionPrompt") is True
        assert any("sudo" in d for d in settings["permissions"].get("deny", []))
        assert any("rm -rf" in d for d in settings["permissions"].get("deny", []))
        run_nogg("session", "stop", full_rec["name"])
        run_nogg("session", "cleanup", full_rec["name"])

        # === 2. Blocked sibling isolation (#41) ===
        r_sib = run_nogg("session", "launch", "--role", "lead", "--bead", "SPEC-csl1", "--agent", "claude")
        assert r_sib.returncode == 0
        sib_recs = [json.loads(p.read_text()) for p in (consumer / ".nogging/state/sessions").glob("*.json")
                    if "spec-csl1" in p.name.lower() and not p.name.endswith(".settings.json")
                    and json.loads(p.read_text()).get("state") == "running"]
        assert len(sib_recs) == 1
        sib_name = sib_recs[0]["name"]
        # Bare kickoff: scope is assigned task SPEC-csl1
        run_nogg("session", "kickoff", sib_name)

        # Poll sweep with a short bounded deadline to account for tmux pane/process settling
        deadline = time.monotonic() + 5
        r_sweep = None
        while time.monotonic() < deadline:
            r_sweep = run_nogg("session", "sweep")
            if sib_name in r_sweep.stdout:
                break
            time.sleep(0.1)
        assert r_sweep is not None and r_sweep.returncode == 0, f"sweep failed: code={getattr(r_sweep, 'returncode', None)}, out={getattr(r_sweep, 'stdout', None)}, err={getattr(r_sweep, 'stderr', None)}"
        assert sib_name in r_sweep.stdout, f"sib_name {sib_name} not in sweep stdout: {r_sweep.stdout}"
        assert "active" in r_sweep.stdout, f"'active' not in sweep stdout: {r_sweep.stdout}"
        assert "bead-blocked" not in r_sweep.stdout, f"'bead-blocked' unexpectedly in sweep stdout: {r_sweep.stdout}"

        # Whole-change scope surfaces bead-blocked if change sibling is blocked
        run_nogg("session", "kickoff", sib_name, "--change", "test-change")
        deadline = time.monotonic() + 5
        r_sweep_ch = None
        while time.monotonic() < deadline:
            r_sweep_ch = run_nogg("session", "sweep")
            if "bead-blocked (SPEC-blocked-sib)" in r_sweep_ch.stdout:
                break
            time.sleep(0.1)
        assert r_sweep_ch is not None and "bead-blocked (SPEC-blocked-sib)" in r_sweep_ch.stdout, f"bead-blocked (SPEC-blocked-sib) not in sweep_ch stdout: {getattr(r_sweep_ch, 'stdout', None)}"

        # Unblock / close the auxiliary tasks and their external blockers
        subprocess.run([str(binaries / "bd"), "close", "SPEC-blocked-sib"], check=True)
        subprocess.run([str(binaries / "bd"), "close", "SPEC-dep-blocked"], check=True)
        subprocess.run([str(binaries / "bd"), "close", "SPEC-ready"], check=True)
        subprocess.run([str(binaries / "bd"), "close", "SPEC-blocker"], check=True)
        subprocess.run([str(binaries / "bd"), "close", "SPEC-ext"], check=True)

        # Working on first Bead SPEC-csl1 under authorized change
        r_sweep_ready = run_nogg("session", "sweep")
        assert "active" in r_sweep_ready.stdout

        # Close first Bead; second Bead SPEC-csl2 is ready
        subprocess.run([str(binaries / "bd"), "close", "SPEC-csl1"], check=True)
        r_sweep2 = run_nogg("session", "sweep")
        assert r_sweep2.returncode == 0
        assert "active" in r_sweep2.stdout

        # Nudge on empty/placeholder pane executes nothing (#42)
        r_nudge_bare = run_nogg("session", "nudge", sib_name)
        assert "nothing was submitted" in r_nudge_bare.stdout or "cannot be positively identified" in r_nudge_bare.stdout
        assert "--message" in r_nudge_bare.stdout

        # Nudge with explicit message sends keys and verifies (#42)
        r_nudge_msg = run_nogg("session", "nudge", sib_name, "--message", "claim and execute SPEC-csl2")
        assert r_nudge_msg.returncode == 0
        assert f"nudged {sib_name}" in r_nudge_msg.stdout

        # Close second Bead and record local integration evidence
        subprocess.run([str(binaries / "bd"), "close", "SPEC-csl2"], check=True)
        base_sha = subprocess.check_output(["git", "-C", str(consumer), "rev-parse", "HEAD"], text=True).strip()
        rec_path = consumer / f".nogging/state/sessions/{sib_name}.json"
        rec_data = json.loads(rec_path.read_text())
        rec_data["integration_evidence"] = {"commit": base_sha, "target_ref": "refs/heads/develop"}
        rec_path.write_text(json.dumps(rec_data, indent=2))

        r_sweep3 = run_nogg("session", "sweep")
        assert r_sweep3.returncode == 0
        assert "change-complete" in r_sweep3.stdout

        run_nogg("session", "stop", sib_name)
        run_nogg("session", "cleanup", sib_name)

        # === 4. CI transition, explicit checks-ack & doctor cache reuse (#41) ===
        r_ci = run_nogg("session", "launch", "--role", "lead", "--bead", "SPEC-ready", "--agent", "claude")
        ci_recs = [json.loads(p.read_text()) for p in (consumer / ".nogging/state/sessions").glob("*.json")
                   if "spec-ready" in p.name.lower() and not p.name.endswith(".settings.json")
                   and json.loads(p.read_text()).get("state") == "running"]
        assert len(ci_recs) == 1
        ci_name = ci_recs[0]["name"]

        gh_data = {
            "rows": [{
                "number": 101,
                "url": "https://github.com/JoMe92/nogging/pull/101",
                "state": "OPEN",
                "headRefOid": base_sha,
                "statusCheckRollup": [{
                    "name": "test",
                    "workflowName": "CI",
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                    "detailsUrl": "https://github.com/runs/1"
                }]
            }]
        }
        gh_file.write_text(json.dumps(gh_data))

        # 4.1 Sweep --checks initial observation (passing, unchecked)
        r_chk1 = run_nogg("session", "sweep", "--checks")
        assert r_chk1.returncode == 0
        assert "checks passing" in r_chk1.stdout
        assert "unchecked" in r_chk1.stdout

        cache_file = consumer / f".nogging/state/sessions/{ci_name}.checks.json"
        assert cache_file.exists()
        cache_data = json.loads(cache_file.read_text())
        fp1 = cache_data["observation"]["fingerprint"]

        # 4.2 Explicit checks-ack acknowledges fingerprint
        r_ack = run_nogg("session", "checks-ack", ci_name, "--fingerprint", fp1)
        assert r_ack.returncode == 0
        r_chk2 = run_nogg("session", "sweep", "--checks")
        assert "acknowledged" in r_chk2.stdout

        # 4.3 New failing CI run appears unchecked
        gh_data["rows"][0]["statusCheckRollup"][0]["conclusion"] = "FAILURE"
        gh_data["rows"][0]["statusCheckRollup"][0]["detailsUrl"] = "https://github.com/runs/2"
        gh_file.write_text(json.dumps(gh_data))

        r_chk3 = run_nogg("session", "sweep", "--checks")
        assert "checks failing" in r_chk3.stdout
        assert "unchecked" in r_chk3.stdout
        assert "failed=test" in r_chk3.stdout

        # 4.4 Doctor reuse of cached checks without network calls
        gh_file.unlink()
        r_doc = run_nogg("doctor")
        assert "checks failing" in r_doc.stdout or "checks failing" in r_doc.stderr

        run_nogg("session", "stop", ci_name)
        run_nogg("session", "cleanup", ci_name)

    finally:
        subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True)

print("ok   - live session liveness acceptance: all scenarios passed")
PY
