"""The tables of `nogg test`: the testing block, stage resolution, change sets,
placeholders, budget arithmetic and the full-suite lock. Pure, no subprocess."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import testing_stages as s

DEFAULT, _ = s.parse_testing(None)


def configured(**raw):
    settings, problems = s.parse_testing(raw)
    assert not problems, problems
    return settings


def paths(index):
    return f"/r/junit.{index}.xml", f"/r/timings.{index}.tsv"


class ParseTesting(unittest.TestCase):
    def test_every_default_of_the_block(self):
        self.assertEqual(s.parse_testing(None), (s.DEFAULTS, []))
        self.assertEqual(s.parse_testing({}), (s.DEFAULTS, []))
        self.assertEqual(DEFAULT["budgets"], {"changed": 300, "commit": 600, "bead": 1800, "full": 7200})
        self.assertEqual(DEFAULT["max_parallel_heavy"], 2)
        self.assertEqual(DEFAULT["heavy_stages"], ["bead", "full"])
        self.assertEqual(DEFAULT["slot_wait_seconds"], 3600)
        self.assertEqual(DEFAULT["full_lock"], "auto")
        self.assertEqual(DEFAULT["integrity"], "report")
        self.assertEqual(DEFAULT["trend_threshold_percent"], 30)
        self.assertEqual(DEFAULT["ci"], {"branch": "develop", "job_pattern": "test", "max_age_days": 7,
                                         "cache_seconds": 21600})
        self.assertEqual(DEFAULT["nightly"], {"enabled": True, "setup": []})

    def test_the_defaults_are_not_shared_between_calls(self):
        s.parse_testing(None)[0]["heavy_stages"].append("changed")
        self.assertEqual(s.parse_testing(None)[0]["heavy_stages"], ["bead", "full"])

    def test_valid_values_are_kept(self):
        settings = configured(stages={"changed": "pytest {test_files}", "commit": ["pytest", "ruff check {files}"]},
                              budgets={"bead": 90}, max_parallel_heavy=1, heavy_stages=["full"],
                              slot_wait_seconds=0, full_lock="never", integrity="enforce",
                              trend_threshold_percent=12.5,
                              ci={"branch": "main", "job_pattern": "unit|e2e", "max_age_days": 3, "cache_seconds": 0},
                              nightly={"enabled": False, "setup": "npm ci"})
        self.assertEqual(settings["stages"]["commit"], ["pytest", "ruff check {files}"])
        self.assertEqual(settings["budgets"], {**s.DEFAULTS["budgets"], "bead": 90})
        self.assertEqual(settings["ci"]["branch"], "main")
        self.assertEqual(settings["nightly"], {"enabled": False, "setup": ["npm ci"]})

    def test_a_bad_budget_warns_and_keeps_the_default(self):
        settings, problems = s.parse_testing({"budgets": {"bead": "soon"}})
        self.assertEqual(settings["budgets"]["bead"], 1800)
        self.assertIn("testing.budgets.bead", problems[0])

    def test_each_malformed_key_names_itself_and_keeps_its_default(self):
        cases = {
            "stages": ({"stages": []}, "testing.stages"),
            "budgets": ({"budgets": 5}, "testing.budgets"),
            "max_parallel_heavy": ({"max_parallel_heavy": 0}, "testing.max_parallel_heavy"),
            "heavy_stages": ({"heavy_stages": ["soon"]}, "testing.heavy_stages"),
            "slot_wait_seconds": ({"slot_wait_seconds": -1}, "testing.slot_wait_seconds"),
            "full_lock": ({"full_lock": "maybe"}, "testing.full_lock"),
            "integrity": ({"integrity": True}, "testing.integrity"),
            "trend_threshold_percent": ({"trend_threshold_percent": "x"}, "testing.trend_threshold_percent"),
            "ci": ({"ci": "x"}, "testing.ci"),
            "nightly": ({"nightly": "x"}, "testing.nightly"),
        }
        for key, (raw, named) in cases.items():
            with self.subTest(key=key):
                settings, problems = s.parse_testing(raw)
                self.assertEqual(settings[key], s.DEFAULTS[key])
                self.assertEqual(len(problems), 1)
                self.assertIn(named, problems[0])

    def test_a_list_value_never_crashes_a_scalar_check(self):
        settings, problems = s.parse_testing({"full_lock": ["auto"], "max_parallel_heavy": True})
        self.assertEqual((settings["full_lock"], settings["max_parallel_heavy"]), ("auto", 2))
        self.assertEqual(len(problems), 2)

    def test_nested_keys_are_checked_one_by_one(self):
        settings, problems = s.parse_testing({"ci": {"branch": "-x", "job_pattern": "(", "max_age_days": 0,
                                                     "cache_seconds": "x", "other": 1},
                                              "nightly": {"enabled": "yes", "setup": [1], "other": 1}})
        self.assertEqual(settings["ci"], s.DEFAULTS["ci"])
        self.assertEqual(settings["nightly"], s.DEFAULTS["nightly"])
        self.assertEqual(len(problems), 8)

    def test_an_unknown_key_warns_at_every_level(self):
        _, problems = s.parse_testing({"stagez": {}, "stages": {"nightly": "x"}, "budgets": {"nightly": 1}})
        self.assertEqual(len(problems), 3)
        self.assertTrue(all("testing." in problem for problem in problems))

    def test_a_block_that_is_no_object(self):
        settings, problems = s.parse_testing("x")
        self.assertEqual(settings, s.DEFAULTS)
        self.assertIn("must be an object", problems[0])

    def test_unusable_stage_values(self):
        for value in ("", "   ", [], [""], ["ok", 3], 3, 'pytest "unterminated', "lint --x={files}"):
            with self.subTest(value=value):
                settings, problems = s.parse_testing({"stages": {"changed": value}})
                self.assertEqual(settings["stages"], {})
                self.assertIn("testing.stages.changed", problems[0])


class StageCommands(unittest.TestCase):
    """Every row of the stage table."""

    def test_changed_and_commit_fall_back_to_the_changed_tests(self):
        for stage in ("changed", "commit"):
            self.assertEqual(s.stage_commands(stage, DEFAULT), ["scripts/test --only {test_files}"])

    def test_changed_and_commit_prefer_test_changed(self):
        for stage in ("changed", "commit"):
            self.assertEqual(s.stage_commands(stage, DEFAULT, test_changed=True), ["scripts/test-changed {files}"])

    def test_bead_with_ci_is_the_same_as_changed(self):
        self.assertEqual(s.stage_commands("bead", DEFAULT, ci_configured=True), ["scripts/test --only {test_files}"])
        self.assertEqual(s.stage_commands("bead", DEFAULT, test_changed=True, ci_configured=True),
                         ["scripts/test-changed {files}"])

    def test_bead_with_no_ci_runs_the_whole_suite(self):
        self.assertEqual(s.stage_commands("bead", DEFAULT), ["scripts/test"])
        self.assertEqual(s.stage_commands("bead", DEFAULT, test_changed=True), ["scripts/test"])

    def test_full(self):
        self.assertEqual(s.stage_commands("full", DEFAULT, ci_configured=True), ["scripts/test --timings {timings}"])

    def test_a_configured_stage_wins(self):
        settings = configured(stages={"bead": "pytest", "full": ["a", "b"]})
        self.assertEqual(s.stage_commands("bead", settings), ["pytest"])
        self.assertEqual(s.stage_commands("full", settings), ["a", "b"])


class ChangeSet(unittest.TestCase):
    def test_sorted_unique_and_split_by_the_test_rule(self):
        files, tests = s.change_set(["b.py", "a.test.sh", "b.py", "c_test.py", "d.spec.ts"], exists=lambda _: True)
        self.assertEqual(files, ["a.test.sh", "b.py", "c_test.py", "d.spec.ts"])
        self.assertEqual(tests, ["a.test.sh", "c_test.py", "d.spec.ts"])

    def test_a_deleted_path_is_left_out(self):
        files, tests = s.change_set(["gone.test.sh", "here.py"], exists=lambda path: path == "here.py")
        self.assertEqual((files, tests), (["here.py"], []))

    def test_a_testing_module_is_not_a_test(self):
        self.assertEqual(s.change_set(["scripts/lib/testing_stages.py"], exists=lambda _: True)[1], [])


class Placeholders(unittest.TestCase):
    def expand(self, command, files=(), tests=()):
        return s.expand_command(command, list(files), list(tests), "/r/j.xml", "/r/t.tsv")

    def test_one_argument_per_path(self):
        self.assertEqual(self.expand("pytest -q {test_files}", tests=["a_test.py", "b c_test.py"]),
                         (["pytest", "-q", "./a_test.py", "./b c_test.py"], None))
        self.assertEqual(self.expand("lint {files} --fix", files=["x"]), (["lint", "./x", "--fix"], None))

    def test_a_file_name_cannot_become_an_option(self):
        self.assertEqual(self.expand("run {test_files}", tests=["-rf.test.sh"])[0], ["run", "./-rf.test.sh"])

    def test_result_paths_expand_inside_a_word(self):
        self.assertEqual(self.expand("pytest --junitxml={junit} {timings}")[0],
                         ["pytest", "--junitxml=/r/j.xml", "/r/t.tsv"])

    def test_an_unknown_brace_word_is_left_alone(self):
        self.assertEqual(self.expand("find . -exec x {} ;")[0], ["find", ".", "-exec", "x", "{}", ";"])

    def test_a_list_placeholder_with_nothing_skips(self):
        self.assertEqual(self.expand("pytest {test_files}", files=["a.py"]), (None, "no changed test files"))
        self.assertEqual(self.expand("lint {files}"), (None, "no changed files"))

    def test_quoting_is_argv_never_a_shell(self):
        self.assertEqual(self.expand("sh -c 'a; b' {files}", files=["x"])[0], ["sh", "-c", "a; b", "./x"])

    def test_scripts_test_only_gets_what_it_can_run(self):
        tests = ["scripts/fixtures/data.txt", "web/x.spec.ts", "scripts/a.test.sh", "lib/b_test.py"]
        self.assertEqual(self.expand("scripts/test --only {test_files}", tests=tests)[0],
                         ["scripts/test", "--only", "./scripts/a.test.sh", "./lib/b_test.py"])

    def test_scripts_test_only_with_nothing_runnable_skips(self):
        self.assertEqual(self.expand("./scripts/test --only {test_files}", tests=["scripts/fixtures/data.txt"]),
                         (None, "no runnable test file changed"))

    def test_another_runner_gets_every_test_path(self):
        self.assertEqual(self.expand("vitest {test_files}", tests=["web/x.spec.ts"])[0], ["vitest", "./web/x.spec.ts"])


class PlanStage(unittest.TestCase):
    def test_a_stage_that_runs_nothing_names_why(self):
        self.assertEqual(s.plan_stage(["pytest {test_files}"], ["a.py"], [], paths), ([], "no changed test files"))

    def test_a_skipped_command_leaves_the_others(self):
        steps, reason = s.plan_stage(["pytest {test_files}", "ruff check {files}"], ["a.py"], [], paths)
        self.assertEqual(reason, None)
        self.assertEqual([step["argv"] for step in steps], [["ruff", "check", "./a.py"]])
        self.assertEqual((steps[0]["junit"], steps[0]["timings"]), paths(1))

    def test_each_command_gets_fresh_result_paths(self):
        steps, _ = s.plan_stage(["a {junit}", "b {junit}"], [], [], paths)
        self.assertEqual([step["argv"][1] for step in steps], ["/r/junit.0.xml", "/r/junit.1.xml"])

    def test_the_skip_line(self):
        self.assertEqual(s.skip_line("bead", "no changed files"), "skipped: bead ran no tests (no changed files)")


class Budgets(unittest.TestCase):
    def test_the_line_of_a_run_over_budget(self):
        self.assertEqual(s.budget_line("changed", 400, 300),
                         "over budget: changed took 400 s, budget 300 s (testing.budgets.changed)")

    def test_a_large_or_fractional_budget_prints_as_configured(self):
        self.assertIn("budget 1234567 s", s.budget_line("full", 2000000, 1234567))
        self.assertIn("budget 0.5 s", s.budget_line("full", 1, 0.5))

    def test_a_run_just_over_never_reads_as_equal(self):
        self.assertIn("took 301 s, budget 300 s", s.budget_line("changed", 300.2, 300))

    def test_the_boundary(self):
        self.assertFalse(s.over_budget(300, 300))
        self.assertTrue(s.over_budget(300.01, 300))


class CiFiles(unittest.TestCase):
    def test_each_ci_file_counts(self):
        for name in (".github/workflows/a.yml", ".github/workflows/a.yaml", ".gitlab-ci.yml",
                     ".circleci/config.yml", "Jenkinsfile"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as root:
                self.assertEqual(s.ci_files(root), [])
                path = Path(root) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("x")
                self.assertEqual(s.ci_files(root), [name])

    def test_another_file_in_the_workflows_directory_does_not(self):
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / ".github/workflows").mkdir(parents=True)
            (Path(root) / ".github/workflows/README.md").write_text("x")
            self.assertEqual(s.ci_files(root), [])


class FullLock(unittest.TestCase):
    """Every row of the lock table and of `testing.full_lock`."""

    def decide(self, ci=False, nightly_recent=False, lock="auto", **flags):
        return s.full_decision(configured(full_lock=lock), ci, nightly_recent, **flags)

    def test_auto_locks_with_ci_or_a_recent_nightly_run(self):
        self.assertFalse(s.full_lock_active("auto", False, False))
        self.assertTrue(s.full_lock_active("auto", True, False))
        self.assertTrue(s.full_lock_active("auto", False, True))

    def test_always_and_never(self):
        self.assertTrue(s.full_lock_active("always", False, False))
        self.assertFalse(s.full_lock_active("never", True, True))

    def test_a_nightly_record_counts_for_three_days(self):
        self.assertTrue(s.nightly_in_use(1000, 1000 + 3 * 86400))
        self.assertFalse(s.nightly_in_use(1000, 1001 + 3 * 86400))
        self.assertFalse(s.nightly_in_use(None, 1000))
        self.assertFalse(s.nightly_in_use(2000, 1000))

    def test_a_lead_where_ci_is_configured_is_refused_with_the_alternatives(self):
        decision = self.decide(ci=True, role="lead", supervised=True)
        self.assertFalse(decision["allowed"])
        for named in ("nogg test bead", "--allow-full", "--release"):
            self.assertIn(named, decision["message"])

    def test_with_no_ci_and_no_nightly_it_runs(self):
        self.assertEqual(self.decide()["trigger"], "unlocked")
        self.assertEqual(self.decide(role="lead", supervised=True)["trigger"], "unlocked")

    def test_a_recent_nightly_run_locks(self):
        self.assertIn("nightly", self.decide(nightly_recent=True)["message"])

    def test_always_locks_with_no_ci(self):
        self.assertIn("always", self.decide(lock="always")["message"])

    def test_never_unlocks_with_ci(self):
        self.assertTrue(self.decide(ci=True, lock="never")["allowed"])

    def test_release_from_an_operator_shell(self):
        self.assertEqual(self.decide(ci=True, release=True)["trigger"], "release")

    def test_release_from_the_orchestrator(self):
        self.assertEqual(self.decide(ci=True, release=True, role="orchestrator", supervised=True)["trigger"], "release")

    def test_release_is_refused_to_a_lead_and_a_specialist(self):
        for role in ("lead", "specialist:test-runner", None):
            with self.subTest(role=role):
                decision = self.decide(ci=True, release=True, role=role, supervised=True)
                self.assertFalse(decision["allowed"])
                self.assertIn("--release", decision["message"])

    def test_a_false_release_claim_is_refused_even_when_unlocked(self):
        self.assertFalse(self.decide(release=True, role="lead", supervised=True)["allowed"])

    def test_a_false_claim_is_not_hidden_by_allow_full(self):
        self.assertFalse(self.decide(release=True, allow_full="x", role="lead", supervised=True)["allowed"])

    def test_nightly_outside_a_session(self):
        self.assertEqual(self.decide(ci=True, nightly=True)["trigger"], "nightly")

    def test_nightly_is_refused_in_any_session(self):
        for role in ("lead", "orchestrator", "planning"):
            self.assertFalse(self.decide(ci=True, nightly=True, role=role, supervised=True)["allowed"])

    def test_allow_full_runs_anywhere_with_its_reason(self):
        decision = self.decide(ci=True, allow_full="  migration touches every test ", role="lead", supervised=True)
        self.assertEqual((decision["allowed"], decision["trigger"], decision["reason"]),
                         (True, "allow-full", "migration touches every test"))

    def test_allow_full_needs_a_reason(self):
        for reason in ("", "   "):
            self.assertFalse(self.decide(allow_full=reason)["allowed"])


if __name__ == "__main__":
    unittest.main()
