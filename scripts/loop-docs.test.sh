#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$ROOT" PYTHONPATH="$ROOT/scripts/lib${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import re
import unittest
from pathlib import Path

import loop_config

ROOT = Path(__import__("os").environ["REPO_ROOT"])
GUIDE = (ROOT / "docs/scheduled-loops.md").read_text()
COMMANDS = (ROOT / "docs/commands.md").read_text()


class LoopDocsTests(unittest.TestCase):
    def test_guide_covers_tick_policy_admission_and_event_contract(self):
        for text in ("### Tick and run-now", "### Usage admission", "### Run log",
                     "last_tick", "max_used_percent", "retry-scheduled",
                     "runs.jsonl", "1 MiB", "prompt text"):
            self.assertIn(text, GUIDE)

    def test_send_example_is_validated_by_the_real_config_parser(self):
        raw = {
            "schema_version": 1, "timezone": "Europe/Berlin",
            "loops": {"night-work": {
                "schedule": {"every": "30m", "windows": ["22:00-07:00"]},
                "run": {"mode": "send", "target": "orchestrator"}}}}
        normalized = loop_config._load_loop("night-work", raw["loops"]["night-work"], raw["timezone"])
        self.assertEqual(normalized["schedule"]["every"], "30m")
        self.assertEqual(normalized["run"]["mode"], "send")

    def test_commands_document_both_scheduler_commands(self):
        for command in ("### loop run-now", "### loop tick", "./scripts/nogg loop run-now",
                        "./scripts/nogg loop tick"):
            self.assertIn(command, COMMANDS)

    def test_guide_contains_no_email_address(self):
        self.assertIsNone(re.search(r"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b", GUIDE))


unittest.main()
PY
