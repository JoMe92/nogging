"""Unit tests for the ceremony switch and the triage rules (TASK-CER-001).

Small and pure: the configuration and every fact are passed in. Covers the
scenarios of the switch, triage-rules and effective-lane requirements of the
change adaptive-ceremony.
"""
import unittest

from ceremony import (DEFAULTS, MODES, effective_lane, parse, rules_lane, triage,
                      triage_line, trigger_words)


class ParseTest(unittest.TestCase):
    def test_an_unset_block_is_the_default(self):
        for cfg in ({}, {"name": "x"}, {"ceremony": {}}):
            self.assertEqual(parse(cfg), (DEFAULTS, set(), []))
        self.assertEqual(DEFAULTS["mode"], "always-full")

    def test_a_configured_block_is_read(self):
        settings, configured, problems = parse({"ceremony": {
            "mode": "adaptive", "fast_lane": {"max_lines": 120}, "lite": {"min_score": 7}}})
        self.assertEqual(settings, {"mode": "adaptive", "fast_lane.max_files": 2,
                                    "fast_lane.max_lines": 120, "lite.min_score": 7})
        self.assertEqual(configured, {"mode", "fast_lane.max_lines", "lite.min_score"})
        self.assertEqual(problems, [])
        self.assertEqual(DEFAULTS["fast_lane.max_lines"], 200, "parse must not mutate DEFAULTS")

    def test_an_unknown_mode_falls_back(self):
        for bad in ("sometimes", "", None, 3, ["adaptive"]):
            settings, configured, problems = parse({"ceremony": {"mode": bad}})
            self.assertEqual(settings["mode"], "always-full")
            self.assertNotIn("mode", configured)
            self.assertEqual(len(problems), 1)
            self.assertIn("ceremony.mode", problems[0])
            self.assertIn("always-full", problems[0])

    def test_a_non_positive_limit_falls_back(self):
        for bad in (0, -1, 1.5, "2", True, None):
            settings, configured, problems = parse({"ceremony": {
                "mode": "adaptive", "fast_lane": {"max_files": bad}}})
            self.assertEqual(settings["fast_lane.max_files"], 2)
            self.assertEqual(settings["mode"], "adaptive", "a bad limit leaves the mode alone")
            self.assertEqual(configured, {"mode"})
            self.assertEqual(len(problems), 1)
            self.assertIn("ceremony.fast_lane.max_files", problems[0])
        problems = parse({"ceremony": {"fast_lane": {"max_lines": 0}, "lite": {"min_score": 0}}})[2]
        self.assertEqual([p.split()[0] for p in problems],
                         ["ceremony.fast_lane.max_lines", "ceremony.lite.min_score"])

    def test_malformed_shapes_keep_the_defaults(self):
        for cfg, key in (({"ceremony": "adaptive"}, "ceremony "),
                         ({"ceremony": {"fast_lane": 2}}, "ceremony.fast_lane "),
                         ({"ceremony": {"bogus": 1}}, "ceremony.bogus "),
                         ({"ceremony": {"lite": {"max": 1}}}, "ceremony.lite.max ")):
            settings, configured, problems = parse(cfg)
            self.assertEqual((settings, configured), (DEFAULTS, set()))
            self.assertEqual(len(problems), 1)
            self.assertTrue(problems[0].startswith(key), problems[0])


class RulesTest(unittest.TestCase):
    def lane(self, description="Tidy the help text", **facts):
        return rules_lane(description, **facts)[0]

    def test_rule_1_full_for_each_stated_fact(self):
        small = dict(kind="bug", files=1)
        self.assertEqual(self.lane(kind="feature", files=1), "full")
        self.assertEqual(self.lane(kind="pipeline", files=1), "full")
        for flag in ("public_interface", "security", "unclear"):
            self.assertEqual(self.lane(**small, **{flag: True}), "full", flag)
        lane, reasons = rules_lane("Tidy the help text", kind="feature", files=9,
                                   security=True, unclear=True)
        self.assertEqual(lane, "full")
        self.assertEqual(len(reasons), 3, "every fired condition is named")
        self.assertTrue(all(r.startswith("rule 1 (full): ") for r in reasons))

    def test_a_security_word_forces_the_full_spec(self):
        lane, reasons = rules_lane("Rotate the API token on expiry", kind="bug", files=1)
        self.assertEqual(lane, "full")
        self.assertEqual(reasons, ["rule 1 (full): the description holds the trigger word 'token'"])

    def test_trigger_words_match_whole_words_only(self):
        self.assertEqual(trigger_words("Change the Public  API and its Permissions"),
                         ["permission", "public API"])
        self.assertEqual(trigger_words("Add a new command for schemas"), ["schema", "new command"])
        self.assertEqual(trigger_words("Tokenizer cleanup in the insecurity note"), [])
        self.assertEqual(trigger_words(""), [])

    def test_rule_2_lite_for_three_or_more_files(self):
        for kind in ("bug", None):
            lane, reasons = rules_lane("Tidy the help text", kind=kind, files=3)
            self.assertEqual(lane, "lite")
            self.assertEqual(reasons, ["rule 2 (lite): 3 files, 3 or more"])

    def test_a_small_bug_is_fast(self):
        lane, reasons = rules_lane("Off-by-one in the page counter", kind="bug", files=2)
        self.assertEqual(lane, "fast")
        self.assertEqual(reasons, ["rule 3 (fast): kind is bug, 2 files"])
        for kind in ("refactor", "test", "config"):
            self.assertEqual(self.lane(kind=kind, files=1), "fast", kind)

    def test_missing_facts_never_give_the_fast_lane(self):
        lane, reasons = rules_lane("Tidy the help text")
        self.assertEqual(lane, "lite")
        self.assertEqual(reasons, ["rule 4 (lite): no kind stated; no file estimate stated"])
        self.assertEqual(rules_lane("Tidy the help text", kind="bug"),
                         ("lite", ["rule 4 (lite): no file estimate stated"]))
        self.assertEqual(rules_lane("Tidy the help text", files=1),
                         ("lite", ["rule 4 (lite): no kind stated"]))

    def test_bad_facts_are_refused(self):
        for facts in ({"kind": "chore"}, {"files": 0}, {"files": -2}, {"files": True}):
            with self.assertRaises(ValueError):
                rules_lane("Tidy the help text", **facts)

    def test_the_same_input_gives_the_same_output(self):
        facts = dict(kind="bug", files=2, security=True)
        first = triage("adaptive", "Rotate the API token on expiry", **facts)
        for _ in range(3):
            self.assertEqual(triage("adaptive", "Rotate the API token on expiry", **facts), first)


class EffectiveLaneTest(unittest.TestCase):
    def test_the_mode_decides_the_effective_lane(self):
        for lane in ("full", "lite", "fast"):
            self.assertEqual(effective_lane("always-full", lane), "full")
            self.assertEqual(effective_lane("adaptive", lane), lane)
            self.assertEqual(effective_lane("always-fast", lane), "fast")
        self.assertEqual(MODES, ("always-full", "adaptive", "always-fast"))
        with self.assertRaises(ValueError):
            effective_lane("sometimes", "fast")

    def test_the_default_keeps_the_full_spec(self):
        result = triage(DEFAULTS["mode"], "Off-by-one in the page counter", kind="bug", files=2)
        self.assertEqual((result["rules_lane"], result["effective_lane"]), ("fast", "full"))
        self.assertEqual(result["mode"], "always-full")

    def test_the_bead_line_names_lane_mode_and_reasons(self):
        result = triage("adaptive", "Rotate the API token on expiry", kind="bug", files=1,
                        security=True)
        self.assertEqual(triage_line(result),
                         "triage: full (mode adaptive; rules: full): rule 1 (full): security is "
                         "stated; rule 1 (full): the description holds the trigger word 'token'")
        self.assertEqual(triage_line(triage("always-fast", "Tidy the help text")),
                         "triage: fast (mode always-fast; rules: lite): "
                         "rule 4 (lite): no kind stated; no file estimate stated")


if __name__ == "__main__":
    unittest.main(verbosity=2)
