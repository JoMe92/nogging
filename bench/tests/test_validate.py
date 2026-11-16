"""Rules of every record kind, and `nogg-bench validate` over files and a tree."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest
import yaml
from conftest import BENCH, FIXTURES, fields

from nogg_bench import schema
from nogg_bench.cli import main
from nogg_bench.validate import validate

# ------------------------------------------------------------------ task rules


def test_a_valid_task_passes(task):
    assert schema.check_task(task, dir_name="fixture-task") == []


def test_a_missing_field_is_named(task):
    del task["base_commit"]
    assert fields(schema.check_task(task)) == ["base_commit"]


def test_the_task_id_must_match_its_directory(task):
    assert fields(schema.check_task(task, dir_name="other")) == ["id"]


def test_the_base_commit_must_be_a_full_sha(task):
    task["base_commit"] = "d8c4c55"
    assert fields(schema.check_task(task)) == ["base_commit"]


def test_an_accepted_task_needs_a_recorded_check(task):
    del task["curation"]["hidden_tests_verified_by"]
    del task["curation"]["verified_on"]
    assert fields(schema.check_task(task)) == ["curation.hidden_tests_verified_by", "curation.verified_on"]


def test_a_candidate_task_needs_no_recorded_check(task):
    task["curation"] = {"status": "candidate"}
    assert schema.check_task(task) == []


def test_a_test_cannot_be_both_kinds(task):
    task["hidden_tests"]["pass_to_pass"].append(task["hidden_tests"]["fail_to_pass"][0])
    problems = schema.check_task(task)
    assert fields(problems) == ["hidden_tests.pass_to_pass"]
    assert task["hidden_tests"]["fail_to_pass"][0] in problems[0].message


def test_the_test_command_needs_a_placeholder_for_the_tests(task):
    task["environment"]["test_command"] = "pytest"
    assert fields(schema.check_task(task)) == ["environment.test_command"]


def test_the_hidden_patch_must_lie_under_hidden(task):
    task["hidden_tests"]["patch"] = "../elsewhere.patch"
    assert fields(schema.check_task(task)) == ["hidden_tests.patch"]


def test_an_unknown_task_field_is_refused(task):
    task["note"] = "x"
    assert fields(schema.check_task(task)) == ["note"]


def test_the_schema_version_is_checked(task):
    task["schema"] = 2
    assert fields(schema.check_task(task)) == ["schema"]


# ------------------------------------------------------------------- arm rules


def test_a_valid_arm_passes(arm):
    assert schema.check_arm(arm) == []


def test_an_invalid_arm_is_named_by_field(arm):
    del arm["timebox_minutes"]
    del arm["nogging_ref"]
    arm["credentials"] = {"env": "sk-ant-pasted-key"}
    assert fields(schema.check_arm(arm)) == ["timebox_minutes", "credentials.env", "nogging_ref"]


def test_credentials_name_exactly_one_reference(arm):
    arm["credentials"] = {"env": "ANTHROPIC_API_KEY", "dir": "/run/creds"}
    assert fields(schema.check_arm(arm)) == ["credentials"]


def test_only_a_nogging_arm_has_a_ref(arm):
    arm["kind"] = "claude-code"
    assert fields(schema.check_arm(arm)) == ["nogging_ref"]


def test_a_nogging_arm_can_carry_switches(arm):
    arm["switches"] = {"planning_gate": False, "budget": 3}
    assert schema.check_arm(arm) == []


# ------------------------------------------------------------ result-line rules


def test_a_valid_result_line_passes(result):
    assert schema.check_result(result) == []


def test_an_invalid_result_line_is_named_by_field(result):
    result["status"] = "finished"
    result["seed"] = -1
    del result["usage"]
    assert fields(schema.check_result(result)) == ["seed", "status", "usage"]


def test_passed_must_follow_the_tests(result):
    result["passed"] = False
    assert fields(schema.check_result(result)) == ["passed"]


def test_an_infra_error_line_needs_a_reason_and_cannot_pass(result):
    infra = json.loads((FIXTURES / "valid/results/fixture-batch.jsonl").read_text().splitlines()[3])
    assert schema.check_result(infra) == []
    del infra["reason"]
    infra["passed"] = True
    assert fields(schema.check_result(infra)) == ["reason", "passed"]


def test_a_measured_run_needs_a_preregistration_hash(result):
    result["provenance"]["preregistration_hash"] = None
    assert fields(schema.check_result(result)) == ["provenance.preregistration_hash"]
    result["provenance"]["smoke"] = True
    assert schema.check_result(result) == []


def test_a_run_cannot_end_before_it_starts(result):
    result["ended_at"] = "2026-11-19T10:00:00Z"
    assert fields(schema.check_result(result)) == ["ended_at"]


# ------------------------------------------------------------- review rules


def test_a_valid_review_record_passes(review):
    assert schema.check_review(review) == []


def test_an_invalid_review_record_is_named_by_field(review):
    review["merge_decision"] = "approve"
    review["review_minutes"] = 0
    del review["defects"]["major"]
    assert fields(schema.check_review(review)) == ["merge_decision", "defects.major", "review_minutes"]


# -------------------------------------------------------------- thresholds


def test_a_valid_thresholds_block_passes(thresholds):
    assert schema.check_thresholds(thresholds) == []


def test_an_invalid_thresholds_block_is_named_by_field(thresholds):
    thresholds["significance_level"] = 1.5
    thresholds["accepted_ticket"] = "whatever"
    del thresholds["reproducibility"]
    assert fields(schema.check_thresholds(thresholds)) == ["accepted_ticket", "significance_level", "reproducibility"]


def test_a_threshold_must_use_a_primary_comparison(thresholds):
    thresholds["thresholds"][0]["comparison"] = {"treatment": "B", "control": "A"}
    assert fields(schema.check_thresholds(thresholds)) == ["thresholds[0].comparison"]


def test_lead_by_needs_a_margin_and_not_worse_has_none(thresholds):
    del thresholds["thresholds"][1]["margin"]
    thresholds["thresholds"][0]["margin"] = 5
    assert fields(schema.check_thresholds(thresholds)) == ["thresholds[0].margin", "thresholds[1].margin"]


# --------------------------------------------------- the command over files


def _bench_copy(tmp_path: Path) -> Path:
    """A copy of bench/ holding the valid fixtures where each kind belongs."""
    bench = tmp_path / "bench"
    shutil.copytree(BENCH, bench, ignore=shutil.ignore_patterns(".venv", "__pycache__", "*.egg-info", "tests"))
    for rel in ("arms", "results", "PREREGISTRATION.md"):
        src = FIXTURES / "valid" / rel
        dst = bench / rel
        if src.is_dir():
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)
    shutil.copytree(FIXTURES / "valid/tasks/fixture-task", bench / "tasks/fixture-task")
    return bench


RECORD_FILES = {
    "task": "tasks/fixture-task/task.yaml",
    "arm": "arms/A.yaml",
    "result": "results/fixture-batch.jsonl",
    "review": "results/review/fixture-pack.jsonl",
    "thresholds": "PREREGISTRATION.md",
}


def test_every_record_kind_is_checked(tmp_path):
    bench = _bench_copy(tmp_path)
    assert validate([], bench) == []
    # Breaking any one kind is found, and by that file.
    for kind, rel in RECORD_FILES.items():
        victim = bench / rel
        original = victim.read_text(encoding="utf-8")
        victim.write_text(original.replace("schema: 1", "schema: 9").replace('"schema": 1', '"schema": 9'), encoding="utf-8")
        problems = validate([], bench)
        assert problems, kind
        assert {Path(p.file.split(":")[0]).resolve() for p in problems} == {victim.resolve()}, kind
        victim.write_text(original, encoding="utf-8")
    assert validate([], bench) == []


def test_the_command_exits_non_zero_and_names_file_and_field(tmp_path, capsys):
    bench = _bench_copy(tmp_path)
    task_file = bench / RECORD_FILES["task"]
    data = yaml.safe_load(task_file.read_text())
    del data["base_commit"]
    task_file.write_text(yaml.safe_dump(data))
    code = main(["validate", "--bench-dir", str(bench), str(task_file)])
    out = capsys.readouterr().out
    assert code == 1
    assert f"{task_file}: base_commit:" in out


def test_the_command_exits_zero_and_prints_nothing_for_valid_records(tmp_path, capsys):
    bench = _bench_copy(tmp_path)
    assert main(["validate", "--bench-dir", str(bench)]) == 0
    assert capsys.readouterr().out == ""


def test_a_path_that_is_not_a_record_is_a_problem(tmp_path):
    bench = _bench_copy(tmp_path)
    stray = bench / "notes.txt"
    stray.write_text("x")
    problems = validate([stray, bench / "missing.yaml"], bench)
    assert [p.field for p in problems] == ["(path)", "(path)"]


def test_a_task_points_at_files_that_exist(tmp_path):
    bench = _bench_copy(tmp_path)
    (bench / "tasks/fixture-task/issue.md").unlink()
    (bench / "tasks/fixture-task/hidden/tests.patch").unlink()
    assert sorted(p.field for p in validate([], bench)) == ["hidden_tests.patch", "issue"]


def test_an_arm_points_at_its_prompt_and_is_named_by_its_id(tmp_path):
    bench = _bench_copy(tmp_path)
    (bench / "arms/prompts/a.md").unlink()
    shutil.copy(bench / "arms/A.yaml", bench / "arms/Z.yaml")
    assert sorted((p.field, Path(p.file).name) for p in validate([], bench)) == [
        ("id", "Z.yaml"), ("prompt", "A.yaml"), ("prompt", "C.yaml"), ("prompt", "Z.yaml"),
    ]


def test_a_broken_file_is_reported_not_raised(tmp_path):
    bench = _bench_copy(tmp_path)
    (bench / "results/fixture-batch.jsonl").write_text("{not json\n")
    (bench / "arms/A.yaml").write_text("a: [unclosed\n")
    problems = validate([], bench)
    assert {Path(p.file.split(":")[0]).name for p in problems} == {"fixture-batch.jsonl", "A.yaml"}


def test_the_invalid_fixtures_are_all_refused():
    bench = BENCH
    for kind, rel in RECORD_FILES.items():
        path = FIXTURES / "invalid" / rel
        assert validate([path], bench), kind
