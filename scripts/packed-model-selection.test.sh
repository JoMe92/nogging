#!/usr/bin/env bash
# Installed-payload model-selection, tier launch and Claude effort acceptance
# (TASK-SCM-004, TASK-MES-006, TASK-CRE-004).
#
# Packs the package, installs it into a fresh consumer with the packaged
# `bin/cli.js`, and launches real tmux sessions with stub Claude/Codex/Pi/Antigravity
# runtimes through the installed `scripts/nogg` and `scripts/session-launch`.
#
# Covered, against the installed payload rather than the source checkout:
#   - packed init scaffolds .nogging/model-selection.json and docs/nogging/model-selection.md;
#   - installed scripts/nogg models check validates the scaffolded table;
#   - consumer edits to the table survive update byte-for-byte;
#   - update scaffolds an absent table;
#   - tier launch fixtures:
#     - Claude --tier applies table model and forwards its effort via --effort;
#     - Codex --tier applies table model and reasoning effort via wrapper argv;
#     - Antigravity --tier applies table model without effort flag;
#     - explicit --model beats tier model while tier supplies effort;
#     - tier beats profile model and profile effort;
#     - record stores selection_tier and session list displays tier=<tier>;
#     - unknown tier, Pi with --tier, and invalid table refuse before tmux or session record;
#   - `--model` overrides a profile model: the runtime receives the override
#     as separate argv elements and the record/list show source `launch`;
#   - a profile model alone reaches the runtime with source `profile`;
#   - a Codex profile `model_reasoning_effort` reaches Codex as its own
#     `-c model_reasoning_effort="<level>"` argv pair;
#   - a legacy profile passes no model flag and lists `runtime-default`;
#   - a packed update retains the Claude effort helper contract and launches
#     each supported effort from both profile and CLI sources with provenance;
#   - Pi `--model` selection still reaches Pi;
#   - an unsupported reasoning effort refuses before any tmux session or
#     session record exists;
#   - no launch mutates the profile files or the user-global runtime settings.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v tmux >/dev/null || ! command -v npm >/dev/null; then
  printf 'SKIP: packed model-selection regression (tmux or npm unavailable)\n'
  exit 0
fi
python3 - "$root" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, tarfile, tempfile, time, uuid

# The installed launcher refuses without a real OpenSpec fence; mirror the
# other packed live-pane test on hosts that prohibit user namespaces.
probe = subprocess.run(['unshare', '--user', '--map-root-user', '--mount', 'true'],
                       capture_output=True)
if probe.returncode:
    print('SKIP: packed model selection (host denies Linux user/mount namespaces)')
    sys.exit(0)
source = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="nogg packed model ") as directory:
    scratch = pathlib.Path(directory)
    packed = json.loads(subprocess.check_output(
        ["npm", "pack", "--ignore-scripts", "--json", "--pack-destination", str(scratch)],
        cwd=source, text=True))[0]
    with tarfile.open(scratch / packed["filename"]) as archive:
        archive.extractall(scratch, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
    package = scratch / "package"
    consumer = scratch / "consumer with spaces"
    consumer.mkdir()
    subprocess.run(["git", "init", "-q", str(consumer)], check=True)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("NOGG_") and k != "NOGGING_ROOT"}
    home = scratch / "home"
    cache = scratch / "cache"
    cache.mkdir()
    for d in (".claude", ".codex", ".pi/agent", ".gemini/antigravity-cli"):
        (home / d).mkdir(parents=True)
    (home / ".claude/settings.json").write_text(
        '{"model":"global-claude-model","effortLevel":"global-effort-level"}\n')
    (home / ".codex/config.toml").write_text('model = "global-codex-model"\n')
    (home / ".pi/agent/settings.json").write_text('{"defaultModel":"global-pi-model"}\n')
    (home / ".gemini/antigravity-cli/settings.json").write_text('{"toolPermission":"request-review"}\n')
    subprocess.run(["node", str(package / "bin/cli.js"), "init", "--no-beads", "--no-hooks",
                    "--no-systemd"], cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True)
    for name in ("nogg", "session-launch"):
        assert (consumer / "scripts" / name).read_bytes() == (package / "scripts" / name).read_bytes()
    def assert_effort_contract(label):
        contract = json.loads(subprocess.check_output(
            [str(consumer / "scripts/session-launch"), "--contract"], text=True))
        assert "claude-effort-forwarding" in contract["features"], (label, contract)
        assert contract["options"].get("--effort") == 1, (label, contract)
        print(f"packed model selection: {label} exposes Claude effort forwarding")
    assert_effort_contract("init")

    # Scaffold verification (TASK-MES-006): init scaffolds table and doc
    table_file = consumer / ".nogging/model-selection.json"
    template_table = package / "templates/model-selection.json"
    assert table_file.read_bytes() == template_table.read_bytes(), "init did not scaffold model-selection.json"
    assert (consumer / "docs/nogging/model-selection.md").is_file(), "init did not copy model-selection doc"
    subprocess.run([str(consumer / "scripts/nogg"), "models", "check"], cwd=consumer, env=env,
                   stdout=subprocess.DEVNULL, check=True)
    print("packed model selection: init scaffold and models check passed")

    # Consumer edits survive update
    table_data = json.loads(table_file.read_text())
    table_data["agents"]["codex"]["standard"]["effort"] = "high"
    table_file.write_text(json.dumps(table_data, indent=2) + "\n ")
    edited_sha = hashlib.sha256(table_file.read_bytes()).hexdigest()
    subprocess.run(["node", str(package / "bin/cli.js"), "update", "--no-hooks",
                    "--no-systemd"], cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True)
    assert hashlib.sha256(table_file.read_bytes()).hexdigest() == edited_sha, "update mutated edited table"
    print("packed model selection: consumer edits survive update")

    # Update scaffolds an absent table
    table_file.unlink()
    subprocess.run(["node", str(package / "bin/cli.js"), "update", "--no-hooks",
                    "--no-systemd"], cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True)
    assert table_file.read_bytes() == template_table.read_bytes(), "update did not scaffold absent table"
    print("packed model selection: update scaffolds absent table")
    for name in ("nogg", "session-launch"):
        assert (consumer / "scripts" / name).read_bytes() == (package / "scripts" / name).read_bytes()
    assert_effort_contract("update")

    binaries, arguments = scratch / "stub-bin", scratch / "received-args"
    binaries.mkdir()
    arguments.mkdir()
    bd = binaries / "bd"
    bd.write_text('#!/bin/sh\ncase "$1" in show) echo \'[{"id":"SPEC-model"}]\';; dep|list) echo "[]";; *) exit 1;; esac\n')
    bd.chmod(0o755)
    runtime = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
if "--help" in sys.argv:
    print("stub runtime")
    sys.exit(0)
if sys.argv[1:] == ["models"]:
    print("gemini-3.8-flash-low\\tlow\\ngemini-3.8-flash-medium\\tmed\\ngemini-3.8-flash-high\\thigh")
    sys.exit(0)
target = pathlib.Path(os.environ["NOGG_TEST_ARGS_DIR"]) / pathlib.Path(sys.argv[0]).name
target.write_text(json.dumps(sys.argv[1:]))
print("stub ready", flush=True)
while True:
    time.sleep(0.1)
'''
    for agent in ("claude", "codex", "pi", "agy"):
        binary = binaries / agent
        binary.write_text(runtime)
        binary.chmod(0o755)
    config_path = consumer / ".nogging/config.json"
    config = json.loads(config_path.read_text())
    sock = "nogg-packed-model-" + uuid.uuid4().hex
    config.update(session_tmux_socket=sock, session_stop_grace_seconds=0.1)
    config_path.write_text(json.dumps(config))
    env.update(HOME=str(home), XDG_CACHE_HOME=str(cache), NOGGING_ROOT=str(consumer),
               NOGG_TEST_ARGS_DIR=str(arguments), PATH=str(binaries) + os.pathsep + env["PATH"])
    nogg = consumer / "scripts/nogg"
    profiles = consumer / ".nogging/launch-profiles"
    sessions = consumer / ".nogging/state/sessions"
    (profiles / "model.json").write_text(
        '{"permissions":{"defaultMode":"default","deny":[]},"model":"claude-opus-5-5"}\n')
    (profiles / "effort.json").write_text(
        '{"permissions":{"defaultMode":"default","deny":[]},"effort":"high"}\n')
    (profiles / "model.codex.toml").write_text(
        'sandbox = "workspace-write"\nask_for_approval = "on-request"\nnetwork_access = false\n'
        'model = "gpt-6-sol"\nmodel_reasoning_effort = "high"\n')
    (profiles / "bad-effort.codex.toml").write_text(
        'sandbox = "workspace-write"\nask_for_approval = "on-request"\nnetwork_access = false\n'
        'model_reasoning_effort = "turbo"\n')

    def snapshot():
        user_globals = [
            home / ".claude/settings.json",
            home / ".codex/config.toml",
            home / ".pi/agent/settings.json",
        ]
        files = sorted(p for p in (list(profiles.rglob("*")) + user_globals) if p.is_file())
        snap = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
        agy_settings = home / ".gemini/antigravity-cli/settings.json"
        if agy_settings.is_file():
            snap["agy_tool_permission"] = json.loads(agy_settings.read_text()).get("toolPermission")
        return snap

    def records():
        return [json.loads(p.read_text()) for p in sessions.glob("*.json")
                if not p.name.endswith(".settings.json")] if sessions.is_dir() else []

    def tmux_sessions():
        out = subprocess.run(["tmux", "-L", sock, "list-sessions", "-F", "#S"],
                             capture_output=True, text=True)
        return out.stdout.split() if out.returncode == 0 else []

    def launch(label, agent, extra, model_args, absent, source, listed, tier=None, expect_notice=None):
        received = arguments / (agent if agent != "antigravity" else "agy")
        received.unlink(missing_ok=True)
        before = snapshot()
        result = subprocess.run([str(nogg), "session", "launch", "--role", "lead",
                                 "--bead", "SPEC-model", "--agent", agent] + extra,
                                cwd=consumer, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode == 0, (label, result.stderr)
        output = result.stdout + result.stderr
        if expect_notice:
            assert expect_notice in output, (label, output)
        deadline = time.monotonic() + 5
        while not received.exists():
            assert time.monotonic() < deadline, f"{label}: {agent} never started"
            time.sleep(0.02)
        argv = json.loads(received.read_text())
        for i in range(len(argv) - len(model_args) + 1):
            if argv[i:i + len(model_args)] == model_args:
                break
        else:
            raise AssertionError(f"{label}: {model_args} not contiguous in {argv}")
        for flag in absent:
            assert flag not in argv, f"{label}: unexpected {flag} in {argv}"
        [record] = [r for r in records() if r["state"] == "running"]
        assert record["model_source"] == source, (label, record)
        if tier is not None:
            assert record.get("selection_tier") == tier, (label, record)
        listing = subprocess.run([str(nogg), "session", "list"], cwd=consumer, env=env,
                                 text=True, capture_output=True, check=True).stdout
        row = next(line for line in listing.splitlines() if record["name"] in line)
        assert listed in row, (label, row)
        assert snapshot() == before, f"{label}: profile or user-global setting mutated"
        for verb in ("stop", "cleanup"):
            subprocess.run([str(nogg), "session", verb, record["name"]], cwd=consumer, env=env,
                            stdout=subprocess.DEVNULL, check=True, timeout=10)
        print(f"packed model selection: {label} passed")

    def launch_claude_effort(label, level, source, override):
        profile = profiles / "effort.json"
        profile_level = "high" if override else level
        profile.write_text(json.dumps({"permissions": {"defaultMode": "default", "deny": []},
                                       "effort": profile_level}) + "\n")
        extra = ["--profile", str(profile)]
        if override:
            extra += ["--effort", level]
        received = arguments / "claude"
        received.unlink(missing_ok=True)
        before = snapshot()
        result = subprocess.run([str(nogg), "session", "launch", "--role", "lead",
                                 "--bead", "SPEC-model", "--agent", "claude"] + extra,
                                cwd=consumer, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode == 0, (label, result.stderr)
        deadline = time.monotonic() + 5
        while not received.exists():
            assert time.monotonic() < deadline, f"{label}: Claude did not start"
            time.sleep(0.02)
        argv = json.loads(received.read_text())
        assert argv.count("--effort") == 1, (label, argv)
        assert argv[argv.index("--effort") + 1] == level, (label, argv)
        [record] = [r for r in records() if r["state"] == "running"]
        assert record["reasoning_effort"] == level, (label, record)
        assert record["reasoning_effort_source"] == source, (label, record)
        settings = json.loads((sessions / f"{record['name']}.settings.json").read_text())
        assert "effort" not in settings, (label, settings)
        listing = subprocess.run([str(nogg), "session", "list"], cwd=consumer, env=env,
                                 text=True, capture_output=True, check=True).stdout
        row = next(line for line in listing.splitlines() if record["name"] in line)
        assert f"effort={level} ({source})" in row, (label, row)
        assert snapshot() == before, f"{label}: profile or user-global setting mutated"
        for verb in ("stop", "cleanup"):
            subprocess.run([str(nogg), "session", verb, record["name"]], cwd=consumer, env=env,
                           stdout=subprocess.DEVNULL, check=True, timeout=10)
        print(f"packed model selection: {label} passed")

    try:
        # Pre-existing SCM-004 scenarios
        launch("claude override beats profile", "claude",
               ["--profile", str(profiles / "model.json"), "--model", "claude-sonnet-5-5"],
               ["--model", "claude-sonnet-5-5"], ["claude-opus-5-5"], "launch", "claude-sonnet-5-5")
        launch("claude profile model", "claude", ["--profile", str(profiles / "model.json")],
               ["--model", "claude-opus-5-5"], [], "profile", "claude-opus-5-5")
        launch("claude legacy profile", "claude", [], [], ["--model"], "runtime-default",
               "runtime-default")
        for level in ("low", "medium", "high", "xhigh", "max"):
            launch_claude_effort(f"Claude profile effort {level}", level, "profile", False)
            launch_claude_effort(f"Claude override effort {level}", level, "launch", True)
        launch("codex override with profile effort", "codex",
               ["--profile", str(profiles / "model.codex.toml"), "--model", "gpt-6-luna"],
               ["--model", "gpt-6-luna"], ["gpt-6-sol"], "launch", "gpt-6-luna effort=high (profile)")
        launch("codex profile effort argv", "codex",
               ["--profile", str(profiles / "model.codex.toml")],
               ["-c", 'model_reasoning_effort="high"'], [], "profile", "gpt-6-sol effort=high (profile)")
        launch("codex legacy profile", "codex", [], [], ["--model"], "runtime-default",
               "runtime-default")
        launch("pi model override", "pi", ["--model", "pi-model-x"], ["--model", "pi-model-x"],
               [], "launch", "pi-model-x")

        # Tier launch fixtures (TASK-MES-006)
        launch("claude routine tier", "claude", ["--tier", "routine"],
               ["--model", "claude-sonnet-5-5", "--effort", "low"], ["--reasoning-effort"], "launch",
               "claude-sonnet-5-5 effort=low (launch) tier=routine", tier="routine")
        launch("codex standard tier", "codex", ["--tier", "standard"],
               ["--model", "gpt-6-luna", "-c", 'model_reasoning_effort="medium"'], [], "launch",
               "gpt-6-luna effort=medium (launch) tier=standard", tier="standard")
        launch("codex complex tier", "codex", ["--tier", "complex"],
               ["--model", "gpt-6.1-sol", "-c", 'model_reasoning_effort="high"'], [], "launch",
               "gpt-6.1-sol effort=high (launch) tier=complex", tier="complex")
        launch("antigravity complex tier", "agy", ["--tier", "complex"],
               ["--model", "gemini-3.8-flash-high"], ["--reasoning-effort"], "launch",
               "gemini-3.8-flash-high tier=complex", tier="complex")

        # Tier precedence fixtures
        launch("codex model override beats tier", "codex",
               ["--tier", "standard", "--model", "gpt-6.1-sol"],
               ["--model", "gpt-6.1-sol", "-c", 'model_reasoning_effort="medium"'], [], "launch",
               "gpt-6.1-sol effort=medium (launch) tier=standard", tier="standard")
        launch("codex tier beats profile", "codex",
               ["--profile", str(profiles / "model.codex.toml"), "--tier", "routine"],
               ["--model", "gpt-6-luna", "-c", 'model_reasoning_effort="low"'], ["gpt-6-sol"], "launch",
               "gpt-6-luna effort=low (launch) tier=routine", tier="routine")

        # Refusal fixtures: invalid effort, unknown tier, Pi with tier, invalid table
        before, prior = snapshot(), len(records())
        result = subprocess.run([str(nogg), "session", "launch", "--role", "lead", "--bead",
                                 "SPEC-model", "--agent", "codex", "--profile",
                                 str(profiles / "bad-effort.codex.toml")],
                                cwd=consumer, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode != 0 and "model_reasoning_effort" in result.stderr, result.stderr
        assert len(records()) == prior and not tmux_sessions(), "invalid effort created session state"
        assert snapshot() == before
        print("packed model selection: unsupported reasoning effort refused before tmux/record")

        # Unknown tier refusal
        before, prior = snapshot(), len(records())
        result = subprocess.run([str(nogg), "session", "launch", "--role", "lead", "--bead",
                                 "SPEC-model", "--agent", "claude", "--tier", "trivial"],
                                cwd=consumer, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode != 0 and "is not a model-selection tier" in result.stderr, result.stderr
        assert len(records()) == prior and not tmux_sessions(), "unknown tier created session state"
        assert snapshot() == before
        print("packed model selection: unknown tier refused before tmux/record")

        # Pi with tier refusal
        before, prior = snapshot(), len(records())
        result = subprocess.run([str(nogg), "session", "launch", "--role", "lead", "--bead",
                                 "SPEC-model", "--agent", "pi", "--tier", "routine"],
                                cwd=consumer, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode != 0 and "is not supported for agent 'pi'" in result.stderr, result.stderr
        assert len(records()) == prior and not tmux_sessions(), "pi tier created session state"
        assert snapshot() == before
        print("packed model selection: Pi with tier refused before tmux/record")

        # Invalid table refusal
        table_backup = table_file.read_bytes()
        try:
            bad_table = json.loads(table_backup.decode("utf-8"))
            del bad_table["tiers"]["routine"]
            table_file.write_text(json.dumps(bad_table))
            before, prior = snapshot(), len(records())
            result = subprocess.run([str(nogg), "session", "launch", "--role", "lead", "--bead",
                                     "SPEC-model", "--agent", "claude", "--tier", "routine"],
                                    cwd=consumer, env=env, text=True, capture_output=True, timeout=15)
            assert result.returncode != 0 and "is invalid" in result.stderr, result.stderr
            assert len(records()) == prior and not tmux_sessions(), "invalid table created session state"
            assert snapshot() == before
            print("packed model selection: invalid table refused before tmux/record")
        finally:
            table_file.write_bytes(table_backup)
    finally:
        subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True)
PY
