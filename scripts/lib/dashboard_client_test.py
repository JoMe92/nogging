#!/usr/bin/env python3
"""Tests of the dashboard client shell (TASK-DSH-002).

Small: no script writes markup through an HTML sink, and every status has its own shape (a
reader without colour tells them apart). JavaScript has no unit tests (design Decision 1); these two source-text checks are the deliberate
exceptions, and interaction is covered by the acceptance of TASK-DSH-011.
"""
from __future__ import annotations

import re, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

STATIC = Path(__file__).resolve().parent.parent / "dashboard"
STATUSES = ["open", "ready", "in_progress", "blocked", "deferred", "closed"]

# Anything that parses a string into live markup or code. Text nodes and setAttribute of plain
# data are the only way text enters the page (design Decision 1 and the CSP).
SINKS = re.compile(
    r"innerHTML|outerHTML|insertAdjacentHTML|insertAdjacentElement\(\s*[\"']beforebegin|document\s*\.\s*write|"
    r"DOMParser|createContextualFragment|\.srcdoc|setHTML|\beval\s*\(|new\s+Function|"
    r"set(?:Timeout|Interval)\s*\(\s*[\"'`]|setAttribute\(\s*[\"'](?:on|style|srcdoc)", re.I)


def code_of(path):
    text = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
    return re.sub(r"(?m)^\s*//.*$", "", text)


class Sinks(unittest.TestCase):
    def test_no_script_uses_an_html_sink(self):
        scripts = sorted(STATIC.rglob("*.js"))
        self.assertGreater(len(scripts), 5)
        for path in scripts:
            found = SINKS.search(code_of(path))
            self.assertIsNone(found, f"{path.relative_to(STATIC)} uses {found and found.group(0)}")

    def test_the_scan_finds_a_sink(self):
        for line in ("node.innerHTML = text;", "document.write(x)", "el.setAttribute('onclick', x)",
                     "new DOMParser()", "setTimeout('go()', 1)"):
            self.assertIsNotNone(SINKS.search(line), line)


class Shapes(unittest.TestCase):
    """Colour-blind reading: each status has its own shape class and its own colour token."""

    @classmethod
    def setUpClass(cls):
        dom = code_of(STATIC / "dom.js")
        cls.shapes = dict(re.findall(r'^\s{4}(\w+): \{ shape: "([a-z-]+)"', dom, re.M))
        cls.tokens = set(re.findall(r"--status-(\w+):", (STATIC / "tokens.css").read_text()))
        cls.base = (STATIC / "base.css").read_text()

    def test_every_status_has_a_shape(self):
        self.assertEqual(sorted(self.shapes), sorted(STATUSES))

    def test_no_two_statuses_share_a_shape(self):
        self.assertEqual(len(set(self.shapes.values())), len(STATUSES), self.shapes)

    def test_every_status_has_a_colour_token_and_a_class(self):
        self.assertEqual(self.tokens, set(STATUSES))
        for status in STATUSES:
            self.assertRegex(self.base, rf"\.status-{status}\s*\{{\s*color:\s*var\(--status-{status}\)")


if __name__ == "__main__":
    unittest.main()
