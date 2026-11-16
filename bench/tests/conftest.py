"""Shared helpers: fixture paths and loaders for the record fixtures."""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest
import yaml

BENCH = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def load_yaml_fixture(rel: str) -> dict:
    return yaml.safe_load((FIXTURES / rel).read_text(encoding="utf-8"))


def first_jsonl(rel: str) -> dict:
    return json.loads((FIXTURES / rel).read_text(encoding="utf-8").splitlines()[0])


@pytest.fixture
def task() -> dict:
    return load_yaml_fixture("valid/tasks/fixture-task/task.yaml")


@pytest.fixture
def arm() -> dict:
    return load_yaml_fixture("valid/arms/C.yaml")


@pytest.fixture
def result() -> dict:
    return first_jsonl("valid/results/fixture-batch.jsonl")


@pytest.fixture
def review() -> dict:
    return first_jsonl("valid/results/review/fixture-pack.jsonl")


@pytest.fixture
def thresholds() -> dict:
    from nogg_bench.records import thresholds_block

    data, errors = thresholds_block((FIXTURES / "valid/PREREGISTRATION.md").read_text(encoding="utf-8"))
    assert not errors
    return copy.deepcopy(data)


def fields(problems) -> list[str]:
    return [p.field for p in problems]
