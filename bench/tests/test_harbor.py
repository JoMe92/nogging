"""The Harbor adapter (design Decision 12).

The environment is a fake object recording every exec and upload call and
answering with scripted results; the agent CLI is a stub that exists only as
recorded exec answers; the transcripts are the recorded fixtures under
``bench/tests/fixtures/transcripts/``. The clock is injected. Nothing here
needs Docker, a real Harbor install, an agent CLI or the network. The one
large test, gated behind ``NOGG_BENCH_HARBOR=1``, runs a real Harbor trial.
"""

from __future__ import annotations

import asyncio
import json
import os
import tarfile
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from conftest import BENCH, FIXTURES

from nogg_bench import harbor, schema
from nogg_bench.records import RecordError

REPO_ROOT = BENCH.parent
CLAUDE = FIXTURES / "transcripts" / "claude"
CODEX = FIXTURES / "transcripts" / "codex"


@dataclass
class ExecResult:
    stdout: str | None = None
    stderr: str | None = None
    return_code: int = 0


@dataclass
class FakeEnvironment:
    """Records every call; answers exec with scripted results by substring."""

    answers: dict[str, ExecResult] = field(default_factory=dict)
    default_answer: ExecResult = field(default_factory=ExecResult)
    transcript_fixture: dict[str, Path] = field(default_factory=dict)
    uploads: list[tuple[str, str]] = field(default_factory=list)
    downloads: list[str] = field(default_factory=list)
    exec_calls: list[str] = field(default_factory=list)
    files: dict[str, bytes] = field(default_factory=dict)  # files "created" in the environment

    async def exec(self, command, cwd=None, env=None, timeout_sec=None, user=None):
        self.exec_calls.append(command)
        for needle, answer in self.answers.items():
            if needle in command:
                if answer.return_code == 124:  # a timeout leaves the state behind
                    pass
                return answer
        return self.default_answer

    async def upload_file(self, source_path, target_path):
        source = Path(source_path)
        self.uploads.append((str(source), target_path))
        self.files[target_path] = source.read_bytes() if source.is_file() else b""

    async def download_file(self, source_path, target_path):
        self.downloads.append(source_path)
        blob = self.files.get(source_path)
        if blob is None:
            raise FileNotFoundError(source_path)
        Path(target_path).write_bytes(blob)

    async def download_dir(self, source_dir, target_dir):
        self.downloads.append(source_dir)
        fixture = self.transcript_fixture.get(source_dir)
        if fixture is None:
            return
        target = Path(target_dir)
        target.mkdir(parents=True, exist_ok=True)
        for path in fixture.rglob("*"):
            if path.is_file():
                dest = target / path.relative_to(fixture)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(path.read_bytes())

    def installed_anything(self) -> bool:
        return bool(self.exec_calls)


# --------------------------------------------------------------------- setup


def make_config(tmp_path: Path, arm_file: Path, **overrides: str) -> dict[str, str]:
    env = {
        "NOGG_BENCH_ARM": str(arm_file),
        "NOGG_BENCH_BATCH": "harborbatch",
        "NOGG_BENCH_TASK": "featurebench-42",
        "NOGG_BENCH_SEED": "1",
        "NOGG_BENCH_SIZE_CLASS": "medium",
        "NOGG_BENCH_RESULTS_DIR": str(tmp_path / "results"),
        "NOGG_BENCH_NOGGING_CHECKOUT": str(REPO_ROOT),
        "NOGG_BENCH_VERIFIER_CMD": "python3 verify.py",
        "NOGG_BENCH_PREREGISTRATION_HASH": "0" * 40,
    }
    env.update(overrides)
    return env


def fake_env() -> FakeEnvironment:
    """A completed run: the agent exits 0, the verifier passes one test."""
    return FakeEnvironment(
        answers={
            "--version": ExecResult(stdout="claude 2.0.0 (stub)\n"),
            "verify.py": ExecResult(stdout=json.dumps({"tests/feature/test_x.py::test_one": 1})),
        },
        transcript_fixture={
            f"$HOME/{harbor.agents.TRANSCRIPT_DIRS['claude']}": CLAUDE,
            f"$HOME/{harbor.agents.TRANSCRIPT_DIRS['codex']}": CODEX,
        },
    )


def run_adapter(env: dict[str, str], environment: FakeEnvironment, instruction: str = "Fix the bug.") -> dict:
    import datetime as dt

    moment = dt.datetime(2026, 11, 17, 12, 0, 0, tzinfo=dt.timezone.utc)
    old = harbor.clock
    harbor.clock = lambda: moment
    try:
        adapter = harbor.HarborAdapter.from_env(env)
        return asyncio.run(adapter.run(instruction, environment))
    finally:
        harbor.clock = old


@pytest.fixture
def arm_a() -> Path:
    return FIXTURES / "valid" / "arms" / "A.yaml"


# ------------------------------------------------------------------- tests


def test_a_featurebench_task_runs_with_arm_a(tmp_path, arm_a):
    environment = fake_env()
    line = run_adapter(make_config(tmp_path, arm_a), environment)

    problems = schema.check_result(line)
    assert not problems, [str(p) for p in problems]
    assert line["source"] == "harbor:featurebench"
    assert line["status"] == "completed"
    assert line["passed"] is True
    assert line["tests"]["fail_to_pass"] == {"tests/feature/test_x.py::test_one": True}
    assert line["usage"]  # token usage counted through the usage helper
    assert line["usage_collector"]["helper_version"] == "1"
    assert line["diff_stats"] is not None
    batch_file = tmp_path / "results" / "harborbatch.jsonl"
    assert batch_file.is_file()
    recorded = json.loads(batch_file.read_text().splitlines()[0])
    assert recorded["run_id"] == "harborbatch-a-featurebench-42-1"


def test_the_arm_file_is_invalid_fails_before_any_install(tmp_path):
    environment = FakeEnvironment()
    invalid = FIXTURES / "invalid" / "arms" / "A.yaml"
    env = make_config(tmp_path, invalid)
    with pytest.raises(RecordError) as exc:
        harbor.HarborAdapter.from_env(env)
    assert "nogging_ref" in str(exc.value) or "timebox" in str(exc.value)  # names file and field
    assert not environment.installed_anything()


def test_a_nogging_arm_installs_nogging_at_its_ref(tmp_path):
    arm = tmp_path / "D.yaml"
    prompt = tmp_path / "prompts"
    prompt.mkdir()
    (prompt / "d.md").write_text("Implement {issue} on your own process.", encoding="utf-8")
    arm.write_text(
        "schema: 1\nid: D\nlabel: Nogging full-access\nkind: nogging\n"
        "agent:\n  cli: claude\n  version: 2.0.0\n"
        f"nogging_ref: develop\nmodel: claude-opus-5-5\neffort: high\ntimebox_minutes: 60\n"
        "prompt: prompts/d.md\ndisabled_tools: []\n"
        "credentials:\n  env: ANTHROPIC_API_KEY\n",
        encoding="utf-8",
    )
    shipped = []
    adapter = harbor.HarborAdapter.from_env(make_config(tmp_path, arm))
    adapter.archive_builder = lambda ref, dest: (
        shipped.append(ref),
        tarfile.open(dest, "w").addfile(tarfile.TarInfo("marker.txt")),
    )
    environment = FakeEnvironment(
        answers={
            "--version": ExecResult(stdout="claude 2.0.0 (stub)\n"),
            "verify.py": ExecResult(stdout=json.dumps({"t": 1})),
        },
        transcript_fixture={
            f"$HOME/{harbor.agents.TRANSCRIPT_DIRS['claude']}": CLAUDE,
            f"$HOME/{harbor.agents.TRANSCRIPT_DIRS['codex']}": CODEX,
        },
    )
    # the driver's own state, as the run container's driver would have left it
    environment.files[f"{harbor.PREFIX}/state.json"] = json.dumps(
        {"outcome": "done", "diff_base": "a" * 40, "pr_count": 1}
    ).encode()
    asyncio.run(adapter.install(environment))  # Harbor calls setup() before run()
    line = asyncio.run(adapter.run("Fix it.", environment))
    assert line["status"] == "completed"
    assert shipped == ["develop"]  # the archive was built at the arm's ref
    assert any(target == f"{harbor.PREFIX}/nogging.tar" for _source, target in environment.uploads)
    assert any(f"-C {harbor.NOGGING_SRC}" in call for call in environment.exec_calls)
    assert any("bd" in target for _source, target in environment.uploads)  # bd copied in
    assert line["provenance"]["nogging_ref"] == "develop"


def test_a_timeout_maps_to_status_timeout(tmp_path, arm_a):
    environment = fake_env()
    environment.answers["agent.sh"] = ExecResult(return_code=124)  # the timebox ran out
    line = run_adapter(make_config(tmp_path, arm_a), environment)
    assert line["status"] == "timeout"
    assert line["usage"]  # transcripts still copied out and counted
    problems = schema.check_result(line)
    assert not problems, [str(p) for p in problems]


def test_a_failed_verifier_is_an_infra_error(tmp_path, arm_a):
    environment = fake_env()
    environment.answers["verify.py"] = ExecResult(return_code=1, stderr="no rewards\n")
    line = run_adapter(make_config(tmp_path, arm_a), environment)
    assert line["status"] == "infra_error"
    assert "verifier" in line["reason"]
    problems = schema.check_result(line)
    assert not problems, [str(p) for p in problems]


def test_the_usage_helper_still_runs_when_the_helper_breaks(tmp_path, arm_a):
    env = make_config(tmp_path, arm_a, NOGG_BENCH_NOGGING_CHECKOUT=str(tmp_path / "nowhere"))
    line = run_adapter(env, fake_env())
    assert line["status"] == "infra_error"
    assert "usage helper" in line["reason"]


def test_a_non_reward_verdict_is_refused(tmp_path, arm_a):
    environment = fake_env()
    environment.answers["verify.py"] = ExecResult(stdout=json.dumps({"t": "half"}))
    line = run_adapter(make_config(tmp_path, arm_a), environment)
    assert line["status"] == "infra_error"
    assert "rewards" in line["reason"]


def test_verdict_mapping_ties_reward_one_to_pass():
    passed, tests = harbor.verdict_from_rewards({"a": 1, "b": 1})
    assert passed is True
    assert tests == {"fail_to_pass": {"a": True, "b": True}, "pass_to_pass": {}}
    passed, tests = harbor.verdict_from_rewards({"a": 1, "b": 0.5})
    assert passed is False
    assert tests["fail_to_pass"]["b"] is False
    passed, _ = harbor.verdict_from_rewards({})
    assert passed is False  # no rewards at all is not a pass


def test_bench_agent_delegates_to_the_adapter(tmp_path, arm_a):
    """When Harbor is installed, BenchAgent is a BaseAgent that validates the arm first."""
    harbor_cls = harbor.BenchAgent
    if harbor_cls is None:
        pytest.skip("harbor is not installed; the wrapper is only loadable with the harbor extra")
    from harbor.agents.base import BaseAgent

    assert issubclass(harbor_cls, BaseAgent)
    assert harbor_cls.name() == "nogg-bench"
    env = make_config(tmp_path, arm_a)
    old = dict(os.environ)
    os.environ.update(env)
    try:
        environment = fake_env()
        agent = harbor_cls(logs_dir=tmp_path / "logs")
        assert agent.adapter.config.arm.id == "A"
        asyncio.run(agent.setup(environment))
        assert any("install.sh" in call for call in environment.exec_calls)
    finally:
        os.environ.clear()
        os.environ.update(old)


@pytest.mark.skipif(os.environ.get("NOGG_BENCH_HARBOR") != "1", reason="large: needs NOGG_BENCH_HARBOR=1 and Harbor installed")
def test_a_real_harbor_run_of_one_task_with_arm_a(tmp_path, arm_a):
    """Large, only with NOGG_BENCH_HARBOR=1: one real Harbor trial of a single task."""
    pytest.importorskip("harbor")
    results_dir = tmp_path / "results"
    env = make_config(tmp_path, arm_a, NOGG_BENCH_RESULTS_DIR=str(results_dir))
    for name, value in env.items():
        os.environ[name] = value
    agent = harbor.BenchAgent(logs_dir=tmp_path / "logs")
    asyncio.run(agent.setup(_RealEnvironment()))
    line = asyncio.run(agent.run("Say hello and change nothing.", _RealEnvironment()))
    assert line["source"].startswith("harbor:")
    problems = schema.check_result(line)
    assert not problems, [str(p) for p in problems]


class _RealEnvironment:
    """Placeholder environment for the large test; the real Harbor trial in BEN-007
    supplies Harbor's own Docker environment, which has the same interface."""

    default_user = "root"

    async def exec(self, command, cwd=None, env=None, timeout_sec=None, user=None):
        import subprocess

        done = subprocess.run(command, shell=True, capture_output=True, text=True)
        return ExecResult(stdout=done.stdout, stderr=done.stderr, return_code=done.returncode)

    async def upload_file(self, source_path, target_path):
        import shutil

        shutil.copy(source_path, target_path)

    async def download_file(self, source_path, target_path):
        raise FileNotFoundError(source_path)

    async def download_dir(self, source_dir, target_dir):
        Path(target_dir).mkdir(parents=True, exist_ok=True)
