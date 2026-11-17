"""Arm files: loading, the shipped arms A, B and C, and comparability (Decision 6)."""

from __future__ import annotations

import copy
from pathlib import Path

import pytest
import yaml
from conftest import BENCH, FIXTURES

from nogg_bench.arms import comparability_problems, find_arm, load_arm
from nogg_bench.records import RecordError
from nogg_bench.validate import validate


def write_arm(tmp_path: Path, data: dict, prompt: str = "Fix this:\n{issue}\n") -> Path:
    arms = tmp_path / "arms"
    (arms / "prompts").mkdir(parents=True, exist_ok=True)
    (arms / data["prompt"]).write_text(prompt, encoding="utf-8")
    path = arms / f"{data['id']}.yaml"
    path.write_text(yaml.safe_dump(data), encoding="utf-8")
    return path


@pytest.fixture
def arm_a() -> dict:
    return yaml.safe_load((FIXTURES / "valid/arms/A.yaml").read_text(encoding="utf-8"))


def test_the_shipped_arms_are_valid_and_comparable():
    assert validate([BENCH / "arms"], BENCH) == []
    arms = [find_arm(BENCH, i) for i in "ABC"]
    assert [a.kind for a in arms] == ["claude-code", "codex", "nogging"]
    assert comparability_problems(arms) == []
    a, b, c = arms
    assert (a.model, a.effort) == (c.model, c.effort)
    assert b.vendor == "openai" and a.vendor == c.vendor == "anthropic"
    assert c.data["nogging_ref"] == "v3.6.0"


def test_load_arm_hashes_file_and_prompt(tmp_path, arm_a):
    arm = load_arm(write_arm(tmp_path, arm_a))
    assert arm.arm_file_hash.startswith("sha256:") and len(arm.arm_file_hash) == 71
    assert arm.prompt_hash != arm.arm_file_hash
    assert arm.timebox_seconds == 3600
    assert arm.render_prompt("  The bug.\n") == "Fix this:\nThe bug.\n"


def test_an_invalid_arm_names_file_and_field(tmp_path, arm_a):
    arm_a["credentials"] = {"env": "sk-ant-pasted-value"}
    path = write_arm(tmp_path, arm_a)
    with pytest.raises(RecordError) as err:
        load_arm(path)
    assert err.value.problem.file == str(path)
    assert err.value.problem.field == "credentials.env"


def test_a_prompt_without_the_issue_placeholder_is_refused(tmp_path, arm_a):
    with pytest.raises(RecordError, match="placeholder"):
        load_arm(write_arm(tmp_path, arm_a, prompt="No issue here."))


def test_mismatched_timeboxes_are_refused(tmp_path, arm_a):
    other = copy.deepcopy(arm_a)
    other.update(id="B", kind="codex", agent={"cli": "codex", "version": "1"}, model="gpt-x", timebox_minutes=90)
    a = load_arm(write_arm(tmp_path, arm_a))
    b = load_arm(write_arm(tmp_path, other))
    problems = comparability_problems([a, b])
    assert problems == ["arms A and B: timebox_minutes differs (60 != 90)"]


@pytest.mark.parametrize("field,value", [("model", "claude-sonnet-5-5"), ("effort", "low")])
def test_same_vendor_arms_must_match(tmp_path, arm_a, field, value):
    other = copy.deepcopy(arm_a)
    other.update(id="C", kind="nogging", nogging_ref="v3.6.0")
    other[field] = value
    problems = comparability_problems([load_arm(write_arm(tmp_path, arm_a)), load_arm(write_arm(tmp_path, other))])
    assert len(problems) == 1
    assert problems[0].startswith(f"arms A and C: {field} differs within vendor anthropic")


def test_different_vendors_may_name_different_models(tmp_path, arm_a):
    other = copy.deepcopy(arm_a)
    other.update(id="B", kind="codex", agent={"cli": "codex", "version": "1"}, model="gpt-x", effort="low")
    assert comparability_problems([load_arm(write_arm(tmp_path, arm_a)), load_arm(write_arm(tmp_path, other))]) == []
