"""The Harbor adapter (design Decision 12).

Harbor runs a task in its own container and loads a custom agent by import
path. This module holds two classes:

:class:`HarborAdapter` is the whole adapter logic against a duck-typed
environment — anything with ``async exec``/``upload_file``/``download_file``/
``download_dir`` and a ``default_user`` — so the tests can hand it a fake
environment that records every call. :class:`BenchAgent` is the thin Harbor
wrapper (a :class:`harbor.agents.base.BaseAgent` subclass) that Harbor loads
by import path ``nogg_bench.harbor:BenchAgent`` and that delegates to the
adapter. Harbor is an optional extra: importing this module never imports
Harbor, and :class:`BenchAgent` only exists when Harbor is installed.

Configuration comes from the environment (Harbor's agent options are for the
model, not for us):

- ``NOGG_BENCH_ARM`` — path of the arm file. It is loaded and validated when
  the adapter is constructed, so an invalid arm fails before any install call.
- ``NOGG_BENCH_BATCH``, ``NOGG_BENCH_TASK``, ``NOGG_BENCH_SEED``,
  ``NOGG_BENCH_SIZE_CLASS`` — the result line's identity.
- ``NOGG_BENCH_RESULTS_DIR`` — where ``<batch>.jsonl`` and ``runs/<run_id>/``
  go.
- ``NOGG_BENCH_SOURCE`` — the result line's source, ``harbor:<dataset>``
  (default ``harbor:featurebench``).
- ``NOGG_BENCH_NOGGING_CHECKOUT`` — for a ``nogging`` arm: the host checkout
  the Nogging archive is built from, and where the usage helper reads the
  token-usage adapters.
- ``NOGG_BENCH_VERIFIER_CMD`` — the dataset's verifier command. When the
  agent finishes (any status, as Harbor's verifier runs regardless), the
  adapter runs it in the environment and reads its stdout as a JSON mapping
  of test name to reward; every reward must be ``1`` for the run to count as
  passed. Without a verdict there is no result line, only ``infra_error``.
- ``NOGG_BENCH_DIFF_BASE`` — the diff base inside the task repository
  (default ``HEAD``).
- ``NOGG_BENCH_PREREGISTRATION_HASH`` — the blob hash of the committed
  ``bench/PREREGISTRATION.md`` a measured Harbor run counts under. Without
  it the run must be a smoke run (``NOGG_BENCH_SMOKE=1``) and is kept out of
  every report table, exactly as ``run --smoke`` is.
- ``NOGG_BENCH_SMOKE`` — ``1`` marks the run as a smoke run.
- ``NOGG_BENCH_BENCH_DIR`` — the bench directory, for the bench commit and
  the preregistration gate (optional; defaults to unknown provenance).

The exact invocation is documented in ``bench/README.md``.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping

from nogg_bench import agents, results, usage, workspace
from nogg_bench.arms import Arm, load_arm
from nogg_bench.run import NOGGING_OUTCOMES  # the driver's outcomes, mapped the same way
from nogg_bench.records import RecordError

HARBOR_VERSION = "0.26.0"  # the version checked against Decision 12 and pinned in pyproject

# Inside the environment everything lives under one directory.
PREFIX = "/tmp/nogg-bench"
BRIEF = f"{PREFIX}/brief.md"
STATE = f"{PREFIX}/state.json"
NOGGING_SRC = f"{PREFIX}/nogging"

clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)


class AdapterError(Exception):
    """The environment or the configuration broke; the message becomes the run's reason."""


def build_nogging_archive(ref: str, checkout: Path, dest: Path) -> None:
    """A git archive of Nogging at ``ref``, without ``bench/`` (it holds the hidden tests)."""
    done = subprocess.run(
        ["git", "-C", str(checkout), "archive", "--format=tar", "-o", str(dest), ref,
         "--", ".", ":(exclude)bench"],
        capture_output=True, text=True, check=False,
    )
    if done.returncode != 0:
        raise AdapterError(f"Nogging {ref} is not in {checkout}")


@dataclass(frozen=True)
class HarborConfig:
    arm: Arm
    batch: str
    task: str
    seed: int
    size_class: str
    source: str
    results_dir: Path
    nogging_checkout: Path
    verifier_command: str
    diff_base: str
    preregistration_hash: str | None
    smoke: bool
    bench_dir: Path | None

    @property
    def bench_commit(self) -> str:
        from nogg_bench import prereg

        return prereg.bench_commit(self.bench_dir) if self.bench_dir else "unknown"

    @property
    def run_id(self) -> str:
        return results.run_id_for(self.batch, self.arm.id, self.task, self.seed)

    @classmethod
    def from_env(cls, environ: Mapping[str, str]) -> "HarborConfig":
        def need(name: str) -> str:
            value = environ.get(name)
            if not value:
                raise AdapterError(f"{name} is not set; the Harbor adapter needs it")
            return value

        arm = load_arm(Path(need("NOGG_BENCH_ARM")))  # RecordError names file and field
        seed_text = need("NOGG_BENCH_SEED")
        if not seed_text.isdigit():
            raise AdapterError(f"NOGG_BENCH_SEED must be a non-negative integer (got {seed_text!r})")
        smoke = environ.get("NOGG_BENCH_SMOKE") == "1"
        prereg_hash = environ.get("NOGG_BENCH_PREREGISTRATION_HASH") or None
        if not smoke and prereg_hash is None:
            raise AdapterError(
                "a measured Harbor run needs NOGG_BENCH_PREREGISTRATION_HASH "
                "(the blob hash of the committed bench/PREREGISTRATION.md) or NOGG_BENCH_SMOKE=1"
            )
        return cls(
            arm=arm, batch=need("NOGG_BENCH_BATCH"), task=need("NOGG_BENCH_TASK"),
            seed=int(seed_text), size_class=need("NOGG_BENCH_SIZE_CLASS"),
            source=environ.get("NOGG_BENCH_SOURCE", "harbor:featurebench"),
            results_dir=Path(need("NOGG_BENCH_RESULTS_DIR")),
            nogging_checkout=Path(need("NOGG_BENCH_NOGGING_CHECKOUT")),
            verifier_command=need("NOGG_BENCH_VERIFIER_CMD"),
            diff_base=environ.get("NOGG_BENCH_DIFF_BASE", "HEAD"),
            preregistration_hash=prereg_hash,
            smoke=smoke,
            bench_dir=Path(environ["NOGG_BENCH_BENCH_DIR"]) if environ.get("NOGG_BENCH_BENCH_DIR") else None,
        )


def verdict_from_rewards(rewards: Mapping[str, Any]) -> tuple[bool, dict]:
    """Harbor's verifier verdict as the result line's ``passed`` and ``tests``.

    Every reward must be ``1`` for a pass; the reward names are the per-test
    fields the dataset provides.
    """
    checks = {name: value == 1 for name, value in rewards.items()}
    passed = bool(checks) and all(checks.values())
    return passed, {"fail_to_pass": checks, "pass_to_pass": {}}


def agent_script(arm: Arm) -> str:
    """The body of ``agent.sh`` for the environment: absolute paths, brief on stdin."""
    return agents.agent_script(arm).replace("../brief.md", BRIEF).replace("../bench/", f"{PREFIX}/")


@dataclass
class HarborAdapter:
    """Runs one arm on the Harbor task in its environment and appends one result line."""

    config: HarborConfig
    archive_builder: Callable[[str, Path], None] | None = None
    agent_cli_version: str | None = None

    def __post_init__(self) -> None:
        if self.archive_builder is None:
            checkout = self.config.nogging_checkout
            self.archive_builder = lambda ref, dest: build_nogging_archive(ref, checkout, dest)

    @classmethod
    def from_env(cls, environ: Mapping[str, str]) -> "HarborAdapter":
        return cls(config=HarborConfig.from_env(environ))

    # ------------------------------------------------------------ environment

    async def _exec(self, environment, command: str, *, user: str | None = None,
                   timeout_sec: int | None = None) -> tuple[Any, str]:
        """One exec call; a failure raises with the command's own last line."""
        done = await environment.exec(command, cwd=None, env=None, timeout_sec=timeout_sec, user=user)
        what = (done.stdout or done.stderr or "").strip().splitlines()
        if done.return_code != 0:
            raise AdapterError(
                f"{command.split()[0]} failed (exit {done.return_code}): "
                + (what[-1] if what else "no output")
            )
        return done, (what[-1] if what else "")

    async def install(self, environment) -> str:
        """Install the arm's agent (and Nogging for a ``nogging`` arm) into the environment.

        Returns the agent CLI version, which the result line records. The arm
        file was validated when the adapter was built, so nothing is installed
        for an invalid arm.
        """
        arm = self.config.arm
        scripts = {"tools.sh": agents.TOOLS, "install.sh": agents.INSTALL,
                   "agent.sh": agent_script(arm)}
        await self._exec(environment, agents.USER_SETUP, user=None)
        with tempfile.TemporaryDirectory(prefix="nogg-harbor-") as tmp:
            for name, body in scripts.items():
                path = Path(tmp) / name
                path.write_text(body, encoding="utf-8")
                await environment.upload_file(path, f"{PREFIX}/{name}")
        await self._exec(environment, f"sh {PREFIX}/tools.sh", timeout_sec=1800)
        await self._exec(
            environment,
            f"sh {PREFIX}/install.sh {arm.kind} {arm.cli} {arm.data['agent']['version']}",
            timeout_sec=1800,
        )
        if arm.kind == "nogging":
            for tool in ("bd", "dolt"):
                found = shutil.which(tool)
                if not found:
                    raise AdapterError(f"{tool} is not on the host's PATH; a nogging arm copies it in")
                await environment.upload_file(found, f"/usr/local/bin/{tool}")
            with tempfile.TemporaryDirectory(prefix="nogg-harbor-") as tmp:
                archive = Path(tmp) / "nogging.tar"
                self.archive_builder(arm.data["nogging_ref"], archive)
                await environment.upload_file(archive, f"{PREFIX}/nogging.tar")
            await self._exec(
                environment,
                f"mkdir -p {NOGGING_SRC} && tar -xf {PREFIX}/nogging.tar -C {NOGGING_SRC}",
                timeout_sec=600,
            )
        _done, version = await self._exec(environment, f"{arm.cli} --version", timeout_sec=120)
        self.agent_cli_version = version
        return version

    # ----------------------------------------------------------------- the run

    async def run(self, instruction: str, environment) -> dict:
        """Run the arm's agent with the task instruction as its brief, then the verifier.

        Appends one result line with ``source: harbor:<dataset>`` and returns it.
        Every infrastructure failure still leaves a line, as ``infra_error``.
        """
        cfg = self.config
        rec = results.RunRecord(
            run_id=cfg.run_id, batch=cfg.batch, arm=cfg.arm.id, task=cfg.task, seed=cfg.seed,
            size_class=cfg.size_class, started_at=clock(), source=cfg.source,
            provenance={
                "arm_file_hash": cfg.arm.arm_file_hash, "prompt_hash": cfg.arm.prompt_hash,
                "nogging_ref": cfg.arm.data.get("nogging_ref"), "bench_commit": cfg.bench_commit,
                "preregistration_hash": cfg.preregistration_hash, "smoke": cfg.smoke,
            },
        )
        run_dir = cfg.results_dir / "runs" / cfg.run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        try:
            await self._measure(instruction, environment, rec, run_dir)
        except (AdapterError, usage.UsageHelperError, RecordError, OSError) as exc:
            rec.fail(str(exc))
        except Exception as exc:  # every run leaves a line, whatever broke
            rec.fail(f"unexpected {type(exc).__name__}: {exc}")
        rec.ended_at = clock()
        line = rec.line()
        results.append(cfg.results_dir / f"{cfg.batch}.jsonl", line)  # a bug says so loudly
        return line

    async def _measure(self, instruction: str, environment, rec, run_dir: Path) -> None:
        cfg = self.config
        arm = cfg.arm
        with tempfile.TemporaryDirectory(prefix="nogg-harbor-") as tmp:
            brief = Path(tmp) / "brief.md"
            brief.write_text(arm.render_prompt(instruction), encoding="utf-8")
            await environment.upload_file(brief, BRIEF)

        # The agent under its timebox, as the unprivileged user, exactly as ``run`` launches it.
        limit = agents.outer_timeout(arm)
        command = (
            f"exec timeout --kill-after={agents.KILL_AFTER_SECONDS} {limit} "
            f"sh {PREFIX}/agent.sh > {PREFIX}/agent.log 2>&1"
        )
        before = clock()
        done = await environment.exec(command, cwd=None, env=None,
                                      timeout_sec=limit + agents.KILL_AFTER_SECONDS + 60,
                                      user=agents.AGENT_USER)
        elapsed = (clock() - before).total_seconds()
        if agents.timed_out(done.return_code, elapsed, limit):
            rec.status = "timeout"
        elif done.return_code != 0:
            rec.status, rec.reason = "agent_error", f"agent exited with status {done.return_code}"
        else:
            rec.status = "completed"

        landing = Path(tempfile.mkdtemp(prefix="nogg-harbor-out-"))
        try:
            await self._take_file(environment, f"{PREFIX}/agent.log", landing / "agent.log", run_dir / "agent.log")
            if arm.kind == "nogging":
                await self._driver_state(rec, environment, landing)

            # The diff of the agent's work (the hidden tests never entered the environment).
            diff, _ = await self._exec(
                environment, workspace.diff_script(self.config.diff_base), timeout_sec=600,
                user=agents.AGENT_USER,
            )
            (run_dir / "diff.patch").write_text(diff.stdout or "", encoding="utf-8")
            stats = workspace.parse_patch(diff.stdout or "")
            rec.diff_stats, rec.markdown_lines = stats.diff_stats(), stats.markdown_lines
            rec.diff_path = f"runs/{rec.run_id}/diff.patch"

            # The transcripts, copied out and counted through the usage helper (Decision 10).
            transcripts = run_dir / "transcripts"
            claude_dir = transcripts / "claude"
            codex_dir = transcripts / "codex"
            await environment.download_dir(f"$HOME/{agents.TRANSCRIPT_DIRS['claude']}", str(claude_dir))
            await environment.download_dir(f"$HOME/{agents.TRANSCRIPT_DIRS['codex']}", str(codex_dir))
            counted = usage.collect(cfg.nogging_checkout, [claude_dir], [codex_dir])
            rec.usage_collector = counted.collector()
            if not counted.usage:
                raise AdapterError("usage helper found no token usage in the transcripts")
            rec.usage = counted.usage
        finally:
            shutil.rmtree(landing, ignore_errors=True)

        # Harbor's verifier decides; it runs whatever the agent's outcome was.
        verdict = await environment.exec(cfg.verifier_command, cwd=None, env=None,
                                         timeout_sec=1800, user=None)
        if verdict.return_code != 0:
            raise AdapterError(f"the verifier failed (exit {verdict.return_code})")
        try:
            rewards = json.loads(verdict.stdout or "")
        except ValueError:
            raise AdapterError("the verifier printed no rewards JSON") from None
        if not isinstance(rewards, dict) or not all(
            isinstance(v, (int, float)) and not isinstance(v, bool) for v in rewards.values()
        ):
            raise AdapterError("the verifier's rewards are not a mapping of numbers")
        rec.tests = verdict_from_rewards(rewards)[1]

    async def _driver_state(self, rec, environment, landing: Path) -> None:
        """A ``nogging`` arm's driver leaves ``state.json``; its outcome maps like ``run``'s."""
        if not await self._take_file(environment, STATE, landing / "state.json", landing / "state.json"):
            if rec.status != "timeout":
                rec.status = "agent_error"
                rec.reason = "the nogging driver left no usable state.json"
            return
        try:
            state = json.loads((landing / "state.json").read_text(encoding="utf-8", errors="replace"))
        except ValueError:
            state = None
        if not isinstance(state, dict):
            if rec.status != "timeout":
                rec.status, rec.reason = "agent_error", "the nogging driver left no usable state.json"
            return
        outcome = state.get("outcome")
        if rec.status != "timeout":
            rec.status = NOGGING_OUTCOMES.get(outcome, "agent_error")
            rec.reason = None
            if rec.status == "agent_error":
                rec.reason = f"nogging driver: {outcome}: {state.get('reason') or 'no reason given'}"

    @staticmethod
    async def _take_file(environment, source: str, landing: Path, dest: Path) -> bool:
        """Download one file out of the environment; False when it is not there."""
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            await environment.download_file(source, str(landing))
        except Exception:  # the file is simply not there
            return False
        if landing.is_file() and not landing.is_symlink():
            if dest != landing:
                shutil.copy(landing, dest)
            return True
        return False


# ------------------------------------------------------------------- Harbor


def _define_bench_agent():
    """The Harbor wrapper, defined only when Harbor is installed."""
    try:
        from harbor.agents.base import BaseAgent
    except ModuleNotFoundError:
        return None

    class BenchAgent(BaseAgent):
        """The arm's agent inside Harbor, loaded by import path ``nogg_bench.harbor:BenchAgent``."""

        @classmethod
        def name(cls) -> str:
            return "nogg-bench"

        @classmethod
        def version(cls) -> str:
            return HARBOR_VERSION

        def __init__(self, logs_dir, **kwargs):
            super().__init__(logs_dir=logs_dir, **kwargs)
            # An invalid arm fails here, before Harbor's first install call.
            self.adapter = HarborAdapter.from_env(os.environ)

        async def setup(self, environment) -> None:
            await self.adapter.install(environment)

        async def run(self, instruction: str, environment, context=None) -> None:
            line = await self.adapter.run(instruction, environment)
            if context is not None and line.get("usage"):
                context.n_input_tokens = sum(
                    counts.get("input", 0) + counts.get("cache_read", 0) + counts.get("cache_write", 0)
                    for counts in line["usage"].values()
                )
                context.n_output_tokens = sum(counts.get("output", 0) for counts in line["usage"].values())

    return BenchAgent


BenchAgent = _define_bench_agent()
