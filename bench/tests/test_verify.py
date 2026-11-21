"""``nogg-bench verify``: the derivation (small) and whole checks of example-repository
candidates against the stub ``docker`` (medium); one real container (large)."""

from __future__ import annotations

import json
import os
import shutil
import sys
from datetime import date, datetime, timezone
from pathlib import Path

import pytest
import yaml
from conftest import BENCH
from curation_fixtures import BUNDLE, commit, git, make_bench, read_task, stub_docker

from nogg_bench import candidates, verify
from nogg_bench.cli import main
from nogg_bench.validate import validate

EXAMPLE = "example-medium-durations"
PYTEST = f"PYTHONDONTWRITEBYTECODE=1 {sys.executable} -m pytest -q -rA -p no:cacheprovider {{tests}}"
CLOCK = lambda: datetime(2026, 11, 21, 9, 0, tzinfo=timezone.utc)  # noqa: E731


def example_candidate(tmp_path: Path, **environment) -> Path:
    """A bench checkout holding the medium example as `candidates issues` would have written it:
    status candidate, no test identifiers, and the fix's non-test changes as hidden/fix.patch."""
    bench = make_bench(tmp_path)
    (bench / "examples").mkdir()
    shutil.copy(BUNDLE, bench / "examples" / BUNDLE.name)
    task_dir = bench / "tasks" / EXAMPLE
    shutil.copytree(BENCH / "examples" / "tasks" / EXAMPLE, task_dir)
    task = read_task(bench, EXAMPLE)
    clone = tmp_path / "fixture-repo"
    git(tmp_path, "clone", "-q", str(BUNDLE), str(clone))
    base = task["base_commit"]
    fix = git(clone, "rev-list", "--reverse", "--ancestry-path", f"{base}..origin/main").split()[0]
    _, non_test, _ = candidates.split_patch(git(clone, "diff", base, fix))
    (task_dir / "hidden" / "fix.patch").write_text(non_test, encoding="utf-8")
    task["hidden_tests"].update(fail_to_pass=[], pass_to_pass=[])
    task["curation"] = {"status": "candidate"}
    task["environment"].update({"setup": ["true"], "test_command": PYTEST, **environment})
    (task_dir / "task.yaml").write_text(yaml.safe_dump(task, sort_keys=False), encoding="utf-8")
    commit(bench, "candidates")
    return bench


def run_verify(bench: Path, *tasks: str) -> int:
    args = main.__globals__["build_parser"]().parse_args(["verify", "--bench-dir", str(bench), *tasks])
    return verify.command(args, clock=CLOCK)


def records(bench: Path) -> list[dict]:
    return [json.loads(line) for line in (bench / verify.RECORDS).read_text().splitlines()]


# -------------------------------------------------------------------- small


def test_the_test_kinds_are_derived_from_both_sides():
    base = verify.outcomes("PASSED t::keeps\nFAILED t::fixed - AssertionError: no\nFAILED t::broken\nERROR t::late")
    fixed = verify.outcomes("PASSED t::keeps\nPASSED t::fixed\nFAILED t::broken\nPASSED t::new\nPASSED t::late\nERROR t::late")
    assert base == {"t::keeps": True, "t::fixed": False, "t::broken": False, "t::late": False}
    # t::new is not reported at the base (it fails there); t::late errors after passing on the fix.
    assert verify.derive(base, fixed) == (["t::fixed", "t::new"], ["t::keeps"])


def test_only_verifys_own_mark_counts_as_verified(task):
    assert not verify.verified(task)  # the fixture's check was recorded by hand
    task["curation"]["hidden_tests_verified_by"] = "nogg-bench verify 0123abc"
    assert verify.verified(task)
    task["hidden_tests"]["fail_to_pass"] = []
    assert not verify.verified(task)


# ------------------------------------------------- medium, with stub docker


def test_verification_fills_in_the_tests(tmp_path, monkeypatch, capsys):
    bench = example_candidate(tmp_path)
    stub_docker(tmp_path, monkeypatch)
    expected = yaml.safe_load((BENCH / "examples/tasks" / EXAMPLE / "task.yaml").read_text())["hidden_tests"]
    assert run_verify(bench) == 0

    task = read_task(bench, EXAMPLE)
    assert task["hidden_tests"]["fail_to_pass"] == sorted(expected["fail_to_pass"])
    assert set(expected["pass_to_pass"]) < set(task["hidden_tests"]["pass_to_pass"])  # the whole suite ran
    assert task["curation"] == {  # verified, and still not accepted
        "status": "candidate", "verified_on": date(2026, 11, 21),
        "hidden_tests_verified_by": "nogg-bench verify " + git(bench, "rev-parse", "HEAD").strip(),
    }
    assert verify.verified(task) and validate([bench / "tasks"], bench) == []
    (record,) = records(bench)
    assert (record["task"], record["outcome"], record["fail_to_pass"]) == (EXAMPLE, "verified", 4)
    calls = [json.loads(line)["argv"] for line in (tmp_path / "docker-calls.jsonl").read_text().splitlines()]
    suite = PYTEST.replace("{tests}", "").strip()
    assert [c[-1] for c in calls if c[0] == "exec"] == [  # hidden patch at the base, then the fix, twice each
        "true", "sh ../tools.sh", "git apply --whitespace=nowarn ../hidden.patch", suite, suite,
        "git apply --whitespace=nowarn ../fix.patch", suite, suite]
    assert calls[-1][0] == "rm"

    # A candidate is checked once: no second try, by name or by default.
    assert run_verify(bench, EXAMPLE) == 1
    assert "checked once" in capsys.readouterr().err
    assert run_verify(bench) == 0 and len(records(bench)) == 1


def test_a_flaky_test_drops_the_candidate(tmp_path, monkeypatch):
    flaky = tmp_path / "flaky.sh"  # the fourth suite run (the second on the fix) fails one passing test
    flaky.write_text(f"""n=$(( $(cat {tmp_path}/count 2>/dev/null || echo 0) + 1 )); echo $n > {tmp_path}/count
{PYTEST.replace("{tests}", "")} > {tmp_path}/out
if [ $n -eq 4 ]; then sed 's|^PASSED tests/test_durations.py::test_single_unit|FAILED tests/test_durations.py::test_single_unit|' {tmp_path}/out
else cat {tmp_path}/out; fi
""")
    bench = example_candidate(tmp_path, test_command=f"sh {flaky} {{tests}}")
    stub_docker(tmp_path, monkeypatch)
    assert run_verify(bench) == 0

    (record,) = records(bench)
    assert record["outcome"] == "dropped"
    assert record["reason"] == "flaky on the fix: the runs disagree on tests/test_durations.py::test_single_unit"
    task = read_task(bench, EXAMPLE)
    assert task["curation"] == {"status": "candidate"} and task["hidden_tests"]["fail_to_pass"] == []
    assert not verify.verified(task)


def test_a_setup_failure_drops_the_candidate_with_its_reason(tmp_path, monkeypatch, capsys):
    bench = example_candidate(tmp_path, setup=["true", "echo no wheel >&2; exit 3"])
    stub_docker(tmp_path, monkeypatch)
    assert run_verify(bench) == 0
    assert records(bench)[0]["reason"] == "setup failed (exit 3): echo no wheel >&2; exit 3"
    assert "dropped: setup failed (exit 3)" in capsys.readouterr().out
    assert not verify.verified(read_task(bench, EXAMPLE))


def test_a_suite_over_the_time_limit_or_without_a_failing_test_drops_the_candidate(tmp_path, monkeypatch):
    bench = example_candidate(tmp_path)
    stub_docker(tmp_path, monkeypatch)
    verifier = verify.Verifier(bench, 0.2, 2, "0123abc", clock=CLOCK)
    task_dir = bench / "tasks" / EXAMPLE
    task = read_task(bench, EXAMPLE)
    task["environment"]["test_command"] = "sleep 5 {tests}"
    (task_dir / "task.yaml").write_text(yaml.safe_dump(task, sort_keys=False))
    assert verifier.verify(task_dir)["reason"] == "the suite ran over the time limit of 0.2 seconds at the base commit"
    task["environment"]["test_command"] = "echo PASSED tests/test_x.py::same {tests}"
    (task_dir / "task.yaml").write_text(yaml.safe_dump(task, sort_keys=False))
    monkeypatch.setenv("STUB_DOCKER_ROOT", str(tmp_path / "second"))
    assert verifier.verify(task_dir)["reason"] == "no test fails at the base commit and passes on the fix"


def test_only_candidates_are_checked(tmp_path, monkeypatch, capsys):
    bench = example_candidate(tmp_path)
    stub_docker(tmp_path, monkeypatch)
    task = read_task(bench, EXAMPLE)
    task["curation"] = {"status": "example"}
    task["hidden_tests"]["fail_to_pass"] = ["tests/test_durations.py::test_day_unit"]
    (bench / "tasks" / EXAMPLE / "task.yaml").write_text(yaml.safe_dump(task, sort_keys=False))
    commit(bench, "an example")
    assert run_verify(bench, EXAMPLE) == 1
    assert "verify checks candidates only" in capsys.readouterr().err


# -------------------------------------------------------------------- large


@pytest.mark.skipif(os.environ.get("NOGG_BENCH_DOCKER") != "1", reason="large: needs NOGG_BENCH_DOCKER=1 and a Docker daemon")
def test_large_verify_checks_an_example_task_in_a_real_container(tmp_path):
    bench = example_candidate(
        tmp_path, setup=["pip install --no-cache-dir pytest"], test_command="python -m pytest -q -rA {tests}")
    assert run_verify(bench) == 0
    assert verify.verified(read_task(bench, EXAMPLE)), records(bench)
