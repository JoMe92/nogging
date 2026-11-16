"""Rules of every record kind, and `nogg-bench validate` over files and a tree."""

from __future__ import annotations

import json

from conftest import FIXTURES, fields

from nogg_bench import schema

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
