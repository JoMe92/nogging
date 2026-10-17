#!/usr/bin/env bash
# Regression for #203: Claude's composer clips the HEAD of a long input (only the
# last visual rows stay visible), so delivery verification must recognise a visibly
# clipped view of the operation's own message and still refuse foreign text. The
# real composer classification and submit verification run against a stateful
# substrate; no test-mode bypass is involved.
set -euo pipefail
for name in $(compgen -e); do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_TMPDIR|TMUX_STUB_DIR|TMUX_STATEFUL_STUB) unset "$name" ;; esac
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
from types import SimpleNamespace
from unittest.mock import patch

m = SourceFileLoader("composer_clip", f"{sys.argv[1]}/scripts/nogg").load_module()
assert not m._is_legacy_mock(), "the real verification path must run"
R = "─" * 30
EMPTY_CLAUDE, EMPTY_AGY = f"{R}\n❯ \n{R}\n", f"{R}\n> \n{R}\n"
VISIBLE = 8

ROWS = [f"Step {i:02d}: carry out the mapped task slice {i} and record evidence for it" for i in range(1, 15)]
assert len(ROWS) > 10
MSG = "\n".join(ROWS)

def claude_box(rows):
    return f"{R}\n❯ {rows[0]}\n" + "".join(f"  {r}\n" for r in rows[1:]) + f"{R}\n"
def agy_box(rows):
    return f"{R}\n> {rows[0]}\n" + "".join(f"  {r}\n" for r in rows[1:]) + f"{R}\n"

class Clock:
    now = 0.0
    def monotonic(self): return self.now
    def sleep(self, seconds): self.now += seconds

class Substrate:
    def __init__(self, attributes, agent, visible_rows=ROWS[-VISIBLE:], swallow=0, never=False):
        self.capabilities = SimpleNamespace(capture_attributes=attributes, agent_status=True)
        self.agent, self.visible, self.swallow, self.never = agent, visible_rows, swallow, never
        self.box = claude_box if agent == "claude" else agy_box
        self.empty = EMPTY_CLAUDE if agent == "claude" else EMPTY_AGY
        self.pane, self.typed, self.enters = self.empty, [], 0
    def capture(self, ref, attributes=False): return self.pane
    def send_text(self, ref, text):
        self.typed.append(text)
        self.pane = self.box(self.visible)       # head scrolled out of the composer
    def send_keys(self, ref, key, check=True):
        if key == "enter":
            self.enters += 1
            if not self.never and self.enters > self.swallow:
                self.pane = self.empty
    def agent_status(self, ref): return "idle"

def deliver(sub, agent, message=MSG):
    clock = Clock()
    rec = {"name": "w", "agent": agent}
    try:
        with patch.object(m, "time", SimpleNamespace(monotonic=clock.monotonic, sleep=clock.sleep, time=clock.monotonic)), \
             patch.object(m, "backend_for_name", return_value=(sub, {})):
            m._deliver_pane_locked("w", agent, message, baseline_status="idle")
        return "ok"
    except RuntimeError as exc:
        return str(exc)

for attributes in (True, False):
    # The fixture itself must be the clipped suffix the orchestrator observed.
    sub = Substrate(attributes, "claude")
    probe = m._claude_prompt_box_text(claude_box(ROWS[-VISIBLE:]))
    assert MSG.endswith(probe.replace("\n  ", "\n").strip()) and len(probe) < len(MSG)

    # A clipped long Claude input is this operation's own message: one Enter, no retype.
    sub = Substrate(attributes, "claude")
    assert deliver(sub, "claude") == "ok" and sub.enters == 1 and sub.typed == [MSG], (attributes, sub.enters)

    # A swallowed first Enter is retried once while the clipped text is still pending.
    sub = Substrate(attributes, "claude", swallow=1)
    assert deliver(sub, "claude") == "ok" and sub.enters == 2 and sub.typed == [MSG], (attributes, sub.enters)

    # Never submitted: fails after exactly one retry, never claiming success.
    sub = Substrate(attributes, "claude", never=True)
    result = deliver(sub, "claude")
    assert result != "ok" and sub.enters == 2 and sub.typed == [MSG], (attributes, result, sub.enters)

    # Foreign text of the same height is refused before any Enter.
    foreign = [f"Operator draft row {i:02d}: unrelated words that are not the kickoff" for i in range(VISIBLE)]
    sub = Substrate(attributes, "claude", visible_rows=foreign)
    result = deliver(sub, "claude")
    assert "did not hold exactly the message" in result and sub.enters == 0, (attributes, result)

    # A box shorter than the clip height is not a clipped view: a mere suffix is refused.
    sub = Substrate(attributes, "claude", visible_rows=ROWS[-(VISIBLE - 1):])
    result = deliver(sub, "claude")
    assert "did not hold exactly the message" in result and sub.enters == 0, (attributes, result)

    # A tall box whose rows start with foreign text is not a suffix either.
    sub = Substrate(attributes, "claude", visible_rows=["Operator note first"] + ROWS[-(VISIBLE - 1):])
    result = deliver(sub, "claude")
    assert "did not hold exactly the message" in result and sub.enters == 0, (attributes, result)

# Antigravity's framed composer clips the same way; check the plain (herdr) classification.
sub = Substrate(False, "antigravity")
assert deliver(sub, "antigravity") == "ok" and sub.enters == 1 and sub.typed == [MSG]
sub = Substrate(False, "antigravity", never=True)
assert deliver(sub, "antigravity") != "ok" and sub.enters == 2
sub = Substrate(False, "antigravity", visible_rows=[f"Foreign row {i:02d} not from the kickoff text at all" for i in range(VISIBLE)])
assert "did not hold exactly the message" in deliver(sub, "antigravity") and sub.enters == 0

# Unit boundaries of the matcher.
assert m._composer_text_matches(MSG, MSG)
assert not m._composer_text_matches("short tail", "a long message with a short tail")
print("session composer clip: ok")
PY
