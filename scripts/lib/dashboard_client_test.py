#!/usr/bin/env python3
"""Tests of the dashboard client shell (TASK-DSH-002).

Small: no script writes markup through an HTML sink, and every status has its own shape (a
reader without colour tells them apart). Medium: a real server on 127.0.0.1 serves the shipped
shell, stylesheets, scripts, images and fonts with the right types and the exact bytes.
JavaScript has no unit tests (design Decision 1); these two source-text checks are the deliberate
exceptions, and interaction is covered by the acceptance of TASK-DSH-011.
"""
from __future__ import annotations

import re, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_server as ds
from dashboard_server_test import Harness

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


class ShippedShell(Harness):
    """The shipped files, served by a real server (`Harness` starts one per test)."""

    def served(self):
        self.assets = ds.load_assets(STATIC)
        self.start()

    def test_the_shell_and_its_assets_are_served_with_the_right_types(self):
        self.served()
        expected = {"/": "text/html; charset=utf-8", "/assets/tokens.css": "text/css; charset=utf-8",
                    "/assets/base.css": "text/css; charset=utf-8", "/assets/app.js": "text/javascript; charset=utf-8",
                    "/assets/theme.js": "text/javascript; charset=utf-8", "/assets/dom.js": "text/javascript; charset=utf-8",
                    "/assets/format.js": "text/javascript; charset=utf-8",
                    "/assets/images/nogging-mark.svg": "image/svg+xml",
                    "/assets/images/nogging-mark-dark.svg": "image/svg+xml",
                    "/assets/fonts/poppins-latin-600-normal.woff2": "font/woff2"}
        for path, kind in expected.items():
            status, headers, body = self.call(path)
            self.assertEqual((path, status, headers["content-type"]), (path, 200, kind))
            self.assertGreater(len(body), 0, path)

    def test_a_font_is_served_byte_for_byte(self):
        self.served()
        for name in ("500", "600", "700"):
            font = STATIC / "fonts" / f"poppins-latin-{name}-normal.woff2"
            status, headers, body = self.call(f"/assets/fonts/{font.name}")
            self.assertEqual((status, body), (200, font.read_bytes()))
            self.assertNotIn("content-encoding", headers)

    def test_every_asset_the_styles_and_the_app_name_is_served(self):
        self.served()
        named = set()
        for path in (STATIC / "base.css", STATIC / "tokens.css", STATIC / "app.js"):
            named |= set(re.findall(r"(/assets/[A-Za-z0-9_./-]+)", path.read_text()))
        self.assertGreaterEqual(len(named), 5)
        for name in sorted(named):
            self.assertEqual(self.call(name)[0], 200, name)


if __name__ == "__main__":
    unittest.main()
