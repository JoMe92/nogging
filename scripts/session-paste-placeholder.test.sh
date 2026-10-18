#!/usr/bin/env bash
# Claude Code (v2.1.302) collapses a large paste into "[Pasted text #1]" (with a
# "paste again to expand" hint), so the framed box never shows the message. When
# this operation verified the composer empty before pasting, exactly that
# placeholder is its own pending paste; anything else stays refused. The real
# classification and submit verification run against a stateful 80x24 substrate.
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

m = SourceFileLoader("paste_placeholder", f"{sys.argv[1]}/scripts/nogg").load_module()
assert not m._is_legacy_mock(), "the real verification path must run"
R = "─" * 80
TRANSCRIPT = [f"● earlier output line {i}" for i in range(24)]

def pane(box_rows, footer="  ? for shortcuts"):
    """An 80x24 Claude pane: transcript, framed box, footer."""
    rows = TRANSCRIPT[:24 - 3 - len(box_rows)] + [R, *box_rows, R, footer]
    assert len(rows) == 24, len(rows)
    return "\n".join(rows) + "\n"

EMPTY = pane(["❯ "])
MSG = ("Kickoff: " + "carry out the mapped task and record evidence; " * 22).strip()
assert 900 < len(MSG) < 1100 and "\n" not in MSG

LAYOUTS = {
    "bare": ["❯ [Pasted text #1]"],
    "hint-in-box": ["❯ [Pasted text #1]", "  paste again to expand"],
    "hint-inline": ["❯ [Pasted text #1] (paste again to expand)"],
}

class Clock:
    now = 0.0
    def monotonic(self): return self.now
    def sleep(self, seconds): self.now += seconds

class Substrate:
    def __init__(self, attributes, shown, start=EMPTY, swallow=0, never=False):
        self.capabilities = SimpleNamespace(capture_attributes=attributes, agent_status=True)
        self.shown, self.pane, self.swallow, self.never = shown, start, swallow, never
        self.typed, self.enters = [], 0
    def capture(self, ref, attributes=False): return self.pane
    def send_text(self, ref, text):
        self.typed.append(text); self.pane = self.shown
    def send_keys(self, ref, key, check=True):
        if key == "enter":
            self.enters += 1
            if not self.never and self.enters > self.swallow:
                self.pane = EMPTY
    def agent_status(self, ref): return "idle"

def run(sub, message=MSG, mode="send"):
    clock = Clock()
    try:
        with patch.object(m, "time", SimpleNamespace(monotonic=clock.monotonic, sleep=clock.sleep, time=clock.monotonic)), \
             patch.object(m, "backend_for_name", return_value=(sub, {})):
            m._deliver_pane_locked("w", "claude", message, mode=mode, baseline_status="idle")
        return "ok"
    except RuntimeError as exc:
        return str(exc)

for layout, rows in LAYOUTS.items():
    shown = pane(rows)
    for attributes in (True, False):
        tag = (layout, attributes)
        # Sent onto a verified-empty composer: the placeholder is ours; one Enter, no retype.
        sub = Substrate(attributes, shown)
        assert run(sub) == "ok" and sub.enters == 1 and sub.typed == [MSG], tag
        # Nudge clears first (empty already), then the same rule applies.
        sub = Substrate(attributes, shown)
        assert run(sub, mode="nudge") == "ok" and sub.enters == 1 and sub.typed == [MSG], tag
        # A swallowed first Enter is retried exactly once while the placeholder remains.
        sub = Substrate(attributes, shown, swallow=1)
        assert run(sub) == "ok" and sub.enters == 2 and sub.typed == [MSG], tag
        # Never submitted: fails after the single retry and never claims success.
        sub = Substrate(attributes, shown, never=True)
        result = run(sub)
        assert result != "ok" and sub.enters == 2 and sub.typed == [MSG], (tag, result)
        # A placeholder already in the composer BEFORE the send is not ours: nothing is typed.
        sub = Substrate(attributes, shown, start=shown)
        result = run(sub)
        assert "nothing was typed or submitted" in result and sub.typed == [] and sub.enters == 0, (tag, result)

# Without a verified-empty baseline the placeholder is never claimed.
for attributes in (True, False):
    sub = Substrate(attributes, pane(LAYOUTS["bare"]), start=pane(LAYOUTS["bare"]))
    with patch.object(m, "backend_for_name", return_value=(sub, {})):
        assert m._delivery_composer_state("w", "claude", MSG, clean_baseline=True) == "pending"
        assert m._delivery_composer_state("w", "claude", MSG) != "pending"

# A short message cannot have been collapsed, so a placeholder is foreign.
sub = Substrate(True, pane(LAYOUTS["bare"]))
result = run(sub, message="short message")
assert "did not hold exactly the message" in result and sub.enters == 0, result

# Only the exact placeholder counts: extra text in the box is refused.
for rows in (["❯ [Pasted text #1] and my own words"], ["❯ [Pasted text #1]", "  operator typed this"],
             ["❯ draft [Pasted text #1]"], ["❯ [Image #1]"]):
    for attributes in (True, False):
        sub = Substrate(attributes, pane(rows))
        result = run(sub)
        assert "did not hold exactly the message" in result and sub.enters == 0, (rows, attributes, result)
print("session paste placeholder: ok")
PY
