#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$ROOT" PYTHONPATH="$ROOT/scripts/lib${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import json
import re
import unittest
from pathlib import Path

import loop_config

ROOT = Path(__import__("os").environ["REPO_ROOT"])
GUIDE_PATH = next(path for path in (ROOT / "docs/scheduled-loops.md",
                                    ROOT / "docs/nogging/scheduled-loops.md") if path.exists())
GUIDE = GUIDE_PATH.read_text()
COMMANDS_PATH = next((path for path in (ROOT / "docs/commands.md",
                                        ROOT / "docs/nogging/commands.md") if path.exists()), None)
COMMANDS = COMMANDS_PATH.read_text() if COMMANDS_PATH else ""


class LoopDocsTests(unittest.TestCase):
    def test_guide_covers_tick_policy_admission_and_event_contract(self):
        for text in ("### Tick and run-now", "### Usage admission", "### Run log",
                     "last_tick", "max_used_percent", "retry-scheduled",
                     "runs.jsonl", "1 MiB", "prompt text"):
            self.assertIn(text, GUIDE)

    def test_documented_schedules_are_checked_with_the_real_config_parser(self):
        examples = re.findall(r"```json\s*(.*?)```", GUIDE, re.S)
        self.assertEqual(len(examples), 3)
        schedules = []
        for example in examples:
            config = json.loads(example)
            for name, loop in config["loops"].items():
                normalized = loop_config._load_loop(name, loop, config["timezone"])
                schedules.append(normalized["schedule"])
        self.assertIn("30m", [schedule["every"] for schedule in schedules])
        self.assertIn("5d", [schedule["every"] for schedule in schedules])
        five_hour = next(schedule for schedule in schedules if schedule.get("every") == "5h")
        self.assertEqual(five_hour["start"], "02:07")

    def test_send_policy_and_event_log_are_explicit(self):
        for text in ("canonical Orchestration Agent session", "verified delivery",
                     "two consecutive idle observations", "max_used_percent",
                     "outstanding reservations", "schema_version", "retry-scheduled",
                     "unconfirmed", "rotates", "never stores prompt text",
                     "retry after two and four minutes", "at most three attempts",
                     "failed slots suspend"):
            self.assertIn(text, GUIDE)

    def test_documented_run_log_names_all_scheduler_events_and_fields(self):
        for event in ("missed", "deferred", "skipped", "starting", "delivered",
                      "started", "retry-scheduled", "completed", "failed", "stale",
                      "stopped-stale", "unconfirmed", "suspended"):
            self.assertIn(f"`{event}`", GUIDE)
        for field in ("schema_version", "`at`", "`loop`", "`run_id`", "`slot`",
                      "`trigger`", "`event`", "`reason`", "`usage`", "`log_path`"):
            self.assertIn(field, GUIDE)

    def test_guide_covers_launch_mode_timer_and_external_schedulers(self):
        for text in ("## Launch mode and authority", "## The scheduler timer",
                     "inspect-and-report", "first Bash prompt", "--no-systemd",
                     "external scheduler", "nogg-loops-<slug>.timer", "multi_machine",
                     "`stopped-stale`", "active-run-limit", "max_active_launch_runs"):
            self.assertIn(text, GUIDE)
        self.assertNotIn("when that capability is installed", GUIDE)

    def test_guide_troubleshooting_covers_what_doctor_reports(self):
        for text in ("will not run", "last tick", "suspended", "needs_input"):
            self.assertIn(text, GUIDE)

    def test_scheduler_sections_are_in_reading_order(self):
        positions = [GUIDE.index(section) for section in
                     ("### Tick and run-now", "### Usage admission", "### Run log")]
        self.assertEqual(positions, sorted(positions))

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
        documented = COMMANDS if COMMANDS else GUIDE
        for command in ("loop run-now", "loop tick"):
            self.assertIn(command, documented)

    def test_guide_contains_no_email_address(self):
        self.assertIsNone(re.search(r"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b", GUIDE))


unittest.main()
PY
