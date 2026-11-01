#!/usr/bin/env python3
"""Small tests of the dashboard's visual tokens: contrast in both themes and the colour-blind shapes.

The contrast is recomputed from scripts/dashboard/tokens.css, as scripts/docs-site.test.sh does
for the docs: 4.5:1 for text and 3:1 for controls and marks (WCAG 2.1 AA). Dark is declared twice
(system preference and explicit choice), so each block is checked, and the two must agree.
"""
from __future__ import annotations

import re, unittest
from pathlib import Path

DASHBOARD = Path(__file__).resolve().parent.parent / "dashboard"
STATUSES = ["open", "ready", "in_progress", "blocked", "deferred", "closed"]
AGENTS = ["claude", "codex", "pi", "agy", "unknown"]
SURFACES = ["bg", "surface", "surface-2", "hover"]
STATUS_NAMES = [f"status-{status}" for status in STATUSES]

TEXT_PAIRS = (
    [(fg, bg) for fg in ("text", "text-2", "link") for bg in SURFACES]
    + [("text", "selection"), ("text", "note-bg"), ("text", "warn-bg"), ("text", "error-bg"),
       ("warn-text", "warn-bg"), ("on-btn", "btn")]
    + [(name, bg) for name in STATUS_NAMES for bg in ("bg", "surface")]
    + [("bg", "status-blocked")]                       # the filled P0 chip
)
MARK_PAIRS = (
    [(name, bg) for name in ("accent", "focus", "control-border") for bg in ("bg", "surface")]
    + [(f"agent-{agent}", bg) for agent in AGENTS for bg in ("bg", "surface")]
    + [(name, "surface-2") for name in STATUS_NAMES]
)


def blocks(css):
    """Selector -> {token: #RRGGBB}, for every rule that declares colour tokens."""
    found = {}
    for selector, body in re.findall(r"([^{}@]+)\{([^{}]*)\}", re.sub(r"/\*.*?\*/", "", css, flags=re.S)):
        tokens = dict(re.findall(r"--([a-z0-9_-]+):\s*(#[0-9A-Fa-f]{6})\s*;", body))
        if tokens:
            found[" ".join(selector.split())] = tokens
    return found


def luminance(colour):
    channels = [int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(first, second):
    high, low = sorted((luminance(first), luminance(second)), reverse=True)
    return (high + 0.05) / (low + 0.05)


class Tokens(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.found = blocks((DASHBOARD / "tokens.css").read_text())
        cls.themes = {
            "light": cls.found[":root"],
            "dark (system)": cls.found[':root:not([data-theme="light"])'],
            "dark (explicit)": cls.found[':root[data-theme="dark"]'],
        }

    def test_the_two_dark_blocks_agree(self):
        self.assertEqual(self.themes["dark (system)"], self.themes["dark (explicit)"])

    def test_both_themes_define_the_same_tokens(self):
        self.assertEqual(set(self.themes["light"]), set(self.themes["dark (explicit)"]))

    def check(self, pairs, minimum):
        for theme, tokens in self.themes.items():
            for fg, bg in pairs:
                self.assertIn(fg, tokens, f"{theme}: --{fg} is not a literal #RRGGBB token")
                self.assertIn(bg, tokens, f"{theme}: --{bg} is not a literal #RRGGBB token")
                ratio = contrast(tokens[fg], tokens[bg])
                self.assertGreaterEqual(
                    ratio, minimum, f"{theme}: --{fg} {tokens[fg]} on --{bg} {tokens[bg]} is {ratio:.2f}:1, below {minimum}:1")

    def test_text_pairs_keep_4_5_to_1_in_both_themes(self):
        self.check(TEXT_PAIRS, 4.5)

    def test_marks_and_controls_keep_3_to_1_in_both_themes(self):
        self.check(MARK_PAIRS, 3.0)

    def test_every_status_has_a_colour_in_both_themes(self):
        for theme, tokens in self.themes.items():
            for name in STATUS_NAMES:
                self.assertIn(name, tokens, theme)


if __name__ == "__main__":
    unittest.main()
