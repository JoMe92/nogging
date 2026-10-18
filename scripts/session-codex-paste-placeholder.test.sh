#!/usr/bin/env bash
# TASK-LCD-003: Codex may collapse a long paste to one Pasted Content token.
# Exercise real send, nudge, kickoff and composer verification with a stateful
# pane substrate; no legacy mock bypass or live Codex process is involved.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
agents="$scratch/agents"
mkdir -p "$agents" "$scratch/codex"
# Install the test's own Codex stub before the shared stubs, which preserve it.
cat >"$agents/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$agents/codex"
stub_agent_binaries "$agents"
export PATH="$agents:$PATH" CODEX_HOME="$scratch/codex"
for name in $(compgen -e); do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_TMPDIR|TMUX_STUB_DIR|TMUX_STATEFUL_STUB) unset "$name" ;; esac
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" "$scratch" <<'PY'
import json, pathlib, sys
from importlib.machinery import SourceFileLoader
from types import SimpleNamespace
from unittest.mock import patch

root, scratch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
m = SourceFileLoader("session_codex_paste_placeholder", str(root / "scripts/nogg")).load_module()
assert not m._is_legacy_mock(), "the real delivery path must run"

EMPTY = "OpenAI Codex\n\n› \x1b[2mAsk Codex to do anything\x1b[0m\n"
TIMING = {"session_submit_delay_seconds": 0.1,
          "session_submit_verify_delay_seconds": 0.1,
          "session_delivery_timeout_seconds": 1.0,
          "session_startup_timeout_seconds": 1.0}

class Clock:
    now = 0.0
    def monotonic(self): return self.now
    def sleep(self, seconds): self.now += seconds
    def time(self): return 1_800_000_000 + self.now

class Pane:
    def __init__(self, collapse=True, swallow=0, never=False):
        self.capabilities = SimpleNamespace(capture_attributes=True, agent_status=True)
        self.text, self.typed, self.keys = EMPTY, [], []
        self.status, self.collapse, self.swallow, self.never = "idle", collapse, swallow, never
        self.enters = 0
    def action(self, name, operation, *args, **kwargs):
        if operation == "capture": return self.text
        if operation == "send_text":
            value = args[0]
            self.typed.append(value)
            if self.collapse and (len(value) >= 200 or "\n" in value):
                count = max(1, len(value) - 74)  # Codex's count need not equal Python length.
                self.text = f"› [Pasted Content {count} chars]\n"
            else:
                self.text = f"› {value}\n"
            return None
        if operation == "send_keys":
            key = args[0]
            self.keys.append(key)
            if key == "enter":
                self.enters += 1
                if not self.never and self.enters > self.swallow:
                    self.text, self.status = EMPTY, "working"
            elif key == "ctrl+u":
                self.text = EMPTY
            return None
        if operation == "agent_status": return self.status
        raise AssertionError((operation, args))

def message(n=1074):
    return ("Codex delivery regression check: " + "carry out the mapped task and record evidence; " * 40)[:n]

def run_delivery(pane, text, mode="send"):
    clock = Clock()
    with patch.object(m, "time", SimpleNamespace(monotonic=clock.monotonic,
                                                   sleep=clock.sleep, time=clock.time)), \
         patch.object(m, "backend_for_name", return_value=(pane, {})), \
         patch.object(m, "session_action", side_effect=pane.action):
        return m._deliver_pane_locked("probe", "codex", text, mode=mode,
                                      timing=TIMING, baseline_status="idle")

LONG = message()
assert len(LONG) == 1074

# A clean baseline owns exactly one collapsed paste. Count is deliberately not
# tied to message length; 1000 is the observed Codex rendering.
pane = Pane()
pane.action("probe", "send_text", LONG)
pane.text = "› [Pasted Content 1000 chars]\n"
with patch.object(m, "backend_for_name", return_value=(pane, {})), \
     patch.object(m, "session_action", side_effect=pane.action):
    state = m._delivery_composer_state("probe", "codex", LONG, clean_baseline=True)
    assert state == "pending", f"clean baseline plus one Codex paste token classified as {state}"

# The actual pane send path types once, submits once, and accepts the token.
pane = Pane()
run_delivery(pane, LONG)
assert pane.typed == [LONG] and pane.enters == 1, (pane.typed, pane.keys)

# A multi-line message is eligible even below the length threshold.
MULTILINE = "line one\n" + "line two " * 15
pane = Pane()
run_delivery(pane, MULTILINE)
assert pane.typed == [MULTILINE] and pane.enters == 1

# The exact planning kickoff composed by production code is also accepted.
planning = {"role": "planning", "planning_id": "planning-robustness",
            "description": "harden-planning-sessions", "working_dir": "/tmp"}
with patch.object(m, "planning_launch_workdir", return_value="/tmp/hps007-consumer-plan-close-order-extra-path-000000"):
    kickoff = m._kickoff_message("probe", planning)
assert len(kickoff) >= 866
pane = Pane()
run_delivery(pane, kickoff)
assert pane.typed == [kickoff] and pane.enters == 1

# Nudge and kickoff share the same verified pane-delivery behavior when queue
# transport has no bound thread. These call the real public operations.
def exercise_public(operation, text):
    pane = Pane()
    clock = Clock()
    state_dir = scratch / operation
    sessions = state_dir / "sessions"
    sessions.mkdir(parents=True)
    rec = {"name": "probe", "agent": "codex", "role": "lead", "bead_id": "SPEC-test",
           "state": "running", "started_at": "launch-1", "working_dir": str(state_dir),
           "backend": "tmux", "backend_ref": {"name": "probe", "socket": "unused"}}
    with patch.object(m, "CFG", {**m.CFG, "session_state_dir": str(sessions)}):
        m.write_session(sessions / "probe.json", rec)
        def required(_name): return (sessions / "probe.json", rec)
        with patch.object(m, "time", SimpleNamespace(monotonic=clock.monotonic,
                                                       sleep=clock.sleep, time=clock.time)), \
             patch.object(m, "validate_session_timing_config", return_value=TIMING), \
             patch.object(m, "backend_for_name", return_value=(pane, {})), \
             patch.object(m, "session_action", side_effect=pane.action), \
             patch.object(m, "_require_running", side_effect=required), \
             patch.object(m, "await_session_input_ready", return_value=None):
            if operation == "nudge": m.session_nudge("probe", text)
            else: m.session_kickoff("probe")
    assert pane.typed == [text] and pane.enters == 1, (operation, pane.typed, pane.keys)

exercise_public("nudge", LONG)
exercise_public("kickoff", LONG)

# Foreign/pre-existing, duplicate, image, too-short, and no-baseline tokens
# remain unowned and are never submitted.
bad = ("› [Pasted Content 1000 chars] operator text\n",
       "› [Pasted Content 1000 chars]\n› [Pasted Content 20 chars]\n",
       "› [Image #1]\n", "› [Pasted Content 12 chars]\n")
for shown in bad:
    pane = Pane()
    pane.text = shown
    with patch.object(m, "backend_for_name", return_value=(pane, {})), \
         patch.object(m, "session_action", side_effect=pane.action):
        assert m._delivery_composer_state("probe", "codex", LONG, clean_baseline=True) == "other", shown
    assert m._delivery_composer_state("probe", "codex", LONG) != "pending", shown

for text in ("short", "short\nsecond line"):
    pane = Pane()
    with patch.object(m, "backend_for_name", return_value=(pane, {})), \
         patch.object(m, "session_action", side_effect=pane.action):
        assert m._delivery_composer_state("probe", "codex", text, clean_baseline=True) == "empty"

# A repeated Enter after one swallowed Enter is bounded; an unsubmitted buffer
# is reported as failure, never as successful delivery.
pane = Pane(swallow=1)
run_delivery(pane, LONG)
assert pane.enters == 2 and pane.typed == [LONG]
pane = Pane(never=True)
try:
    run_delivery(pane, LONG)
except RuntimeError:
    pass
else:
    raise AssertionError("unsubmitted collapsed paste was reported successful")
assert pane.enters == 2 and pane.typed == [LONG]

print("Codex paste placeholder: real send, nudge and kickoff paths passed")
PY
