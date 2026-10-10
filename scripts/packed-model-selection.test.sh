#!/usr/bin/env bash
# Installed-payload model-selection acceptance (TASK-SCM-004, issue #51).
#
# Packs the package, installs it into a fresh consumer with the packaged
# `bin/cli.js`, and launches real tmux sessions with stub Claude/Codex/Pi
# runtimes through the installed `scripts/nogg` and `scripts/session-launch`.
#
# Covered, against the installed payload rather than the source checkout:
#   - `--model` overrides a profile model: the runtime receives the override
#     as separate argv elements and the record/list show source `launch`;
#   - a profile model alone reaches the runtime with source `profile`;
#   - a Codex profile `model_reasoning_effort` reaches Codex as its own
#     `-c model_reasoning_effort="<level>"` argv pair;
#   - a legacy profile passes no model flag and lists `runtime-default`;
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
    for d in (".claude", ".codex", ".pi/agent"):
        (home / d).mkdir(parents=True)
    (home / ".claude/settings.json").write_text('{"model":"global-claude-model"}\n')
    (home / ".codex/config.toml").write_text('model = "global-codex-model"\n')
    (home / ".pi/agent/settings.json").write_text('{"defaultModel":"global-pi-model"}\n')
    subprocess.run(["node", str(package / "bin/cli.js"), "init", "--no-beads", "--no-hooks",
                    "--no-systemd"], cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True)
    for name in ("nogg", "session-launch"):
        assert (consumer / "scripts" / name).read_bytes() == (package / "scripts" / name).read_bytes()
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
target = pathlib.Path(os.environ["NOGG_TEST_ARGS_DIR"]) / pathlib.Path(sys.argv[0]).name
target.write_text(json.dumps(sys.argv[1:]))
print("stub ready", flush=True)
while True:
    time.sleep(0.1)
'''
    for agent in ("claude", "codex", "pi"):
        binary = binaries / agent
        binary.write_text(runtime)
        binary.chmod(0o755)
    config_path = consumer / ".nogging/config.json"
    config = json.loads(config_path.read_text())
    sock = "nogg-packed-model-" + uuid.uuid4().hex
    config.update(session_tmux_socket=sock, session_stop_grace_seconds=0.1)
    config_path.write_text(json.dumps(config))
    env.update(HOME=str(home), NOGGING_ROOT=str(consumer), NOGG_TEST_ARGS_DIR=str(arguments),
               PATH=str(binaries) + os.pathsep + env["PATH"])
    nogg = consumer / "scripts/nogg"
    profiles = consumer / ".nogging/launch-profiles"
    sessions = consumer / ".nogging/state/sessions"
    (profiles / "model.json").write_text(
        '{"permissions":{"defaultMode":"default","deny":[]},"model":"claude-opus-5-5"}\n')
    (profiles / "model.codex.toml").write_text(
        'sandbox = "workspace-write"\nask_for_approval = "on-request"\nnetwork_access = false\n'
        'model = "gpt-6-sol"\nmodel_reasoning_effort = "high"\n')
    (profiles / "bad-effort.codex.toml").write_text(
        'sandbox = "workspace-write"\nask_for_approval = "on-request"\nnetwork_access = false\n'
        'model_reasoning_effort = "turbo"\n')

    def snapshot():
        files = sorted(p for base in (profiles, home) for p in base.rglob("*") if p.is_file())
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}

    def records():
        return [json.loads(p.read_text()) for p in sessions.glob("*.json")
                if not p.name.endswith(".settings.json")] if sessions.is_dir() else []

    def tmux_sessions():
        out = subprocess.run(["tmux", "-L", sock, "list-sessions", "-F", "#S"],
                             capture_output=True, text=True)
        return out.stdout.split() if out.returncode == 0 else []

    def launch(label, agent, extra, model_args, absent, source, listed):
        received = arguments / agent
        received.unlink(missing_ok=True)
        before = snapshot()
        result = subprocess.run([str(nogg), "session", "launch", "--role", "lead",
                                 "--bead", "SPEC-model", "--agent", agent] + extra,
                                cwd=consumer, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode == 0, (label, result.stderr)
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
        listing = subprocess.run([str(nogg), "session", "list"], cwd=consumer, env=env,
                                 text=True, capture_output=True, check=True).stdout
        row = next(line for line in listing.splitlines() if record["name"] in line)
        assert listed in row, (label, row)
        assert snapshot() == before, f"{label}: profile or user-global setting mutated"
        for verb in ("stop", "cleanup"):
            subprocess.run([str(nogg), "session", verb, record["name"]], cwd=consumer, env=env,
                           stdout=subprocess.DEVNULL, check=True, timeout=10)
        print(f"packed model selection: {label} passed")

    try:
        launch("claude override beats profile", "claude",
               ["--profile", str(profiles / "model.json"), "--model", "claude-sonnet-5-5"],
               ["--model", "claude-sonnet-5-5"], ["claude-opus-5-5"], "launch", "claude-sonnet-5-5")
        launch("claude profile model", "claude", ["--profile", str(profiles / "model.json")],
               ["--model", "claude-opus-5-5"], [], "profile", "claude-opus-5-5")
        launch("claude legacy profile", "claude", [], [], ["--model"], "runtime-default",
               "runtime-default")
        launch("codex override with profile effort", "codex",
               ["--profile", str(profiles / "model.codex.toml"), "--model", "gpt-6-luna"],
               ["--model", "gpt-6-luna"], ["gpt-6-sol"], "launch", "gpt-6-luna effort=high")
        launch("codex profile effort argv", "codex",
               ["--profile", str(profiles / "model.codex.toml")],
               ["-c", 'model_reasoning_effort="high"'], [], "profile", "gpt-6-sol effort=high")
        launch("codex legacy profile", "codex", [], [], ["--model"], "runtime-default",
               "runtime-default")
        launch("pi model override", "pi", ["--model", "pi-model-x"], ["--model", "pi-model-x"],
               [], "launch", "pi-model-x")
        before, prior = snapshot(), len(records())
        result = subprocess.run([str(nogg), "session", "launch", "--role", "lead", "--bead",
                                 "SPEC-model", "--agent", "codex", "--profile",
                                 str(profiles / "bad-effort.codex.toml")],
                                cwd=consumer, env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode != 0 and "model_reasoning_effort" in result.stderr, result.stderr
        assert len(records()) == prior and not tmux_sessions(), "invalid effort created session state"
        assert snapshot() == before
        print("packed model selection: unsupported reasoning effort refused before tmux/record")
    finally:
        subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True)
PY
