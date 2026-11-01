#!/usr/bin/env python3
"""Small tests of the shipped shell: what a browser would load from it."""
from __future__ import annotations

import re, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_server as ds

STATIC = Path(__file__).resolve().parent.parent / "dashboard"


class Shell(unittest.TestCase):
    def test_no_external_reference_ships(self):
        for path in sorted(STATIC.rglob("*")):
            if path.suffix not in (".html", ".css", ".js", ".svg"):
                continue
            text = path.read_text()
            if path.suffix == ".svg":          # a namespace name, which nothing fetches
                text = text.replace('xmlns="http://www.w3.org/2000/svg"', "")
            self.assertIsNone(re.search(r"(?i)\b(?:https?:)?//[a-z0-9]", re.sub(r"(?m)^\s*//.*$", "", text)), path)

    def test_every_file_the_shell_names_is_served(self):
        assets = ds.load_assets(STATIC)
        names = re.findall(r'(?:href|src)="([^"]+)"', (STATIC / "index.html").read_text())
        self.assertGreater(len(names), 20)
        for name in names:
            self.assertIn(name, assets)

    def test_the_shell_holds_no_inline_code_or_style(self):
        text = (STATIC / "index.html").read_text()
        self.assertNotRegex(text, r"<script(?![^>]*\bsrc=)")
        self.assertNotRegex(text, r"\bstyle=|<style|\son[a-z]+=")

    def test_fonts_are_served_as_bytes(self):
        font = STATIC / "fonts" / "poppins-latin-400-normal.woff2"
        asset = ds.load_assets(STATIC)["/assets/fonts/poppins-latin-400-normal.woff2"]
        self.assertEqual(asset.body, font.read_bytes())
        self.assertIsNone(asset.gzipped)


if __name__ == "__main__":
    unittest.main()
