"""``nogg-bench run``: run arms on tasks in fresh containers, one result line per run.

The order of one run follows design Decision 7:

1. stage credentials, resolve the image, clone and truncate the repository;
2. start a container with nothing mounted, copy in the repository, the brief
   and the agent scripts, run the task's setup and install the agent;
3. run the agent under its timebox (a ``nogging`` arm through the driver);
4. save the diff and copy the transcripts out;
5. only then copy the hidden tests in, restore hidden paths, run the tests;
6. count tokens through the usage helper, scan for contamination, append.

Any failure of the infrastructure ends the run as ``infra_error`` with the
reason; the line is still appended and the command exits non-zero.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Mapping

from nogg_bench import agents, prereg, results, scan, usage, workspace
from nogg_bench.arms import Arm, comparability_problems, find_arm
from nogg_bench.credentials import CredentialError, Credentials, Redactor
from nogg_bench.docker import Docker, DockerError, RunLog
from nogg_bench.records import RecordError, load_yaml
from nogg_bench.schema import Problem, check_task
from nogg_bench.validate import find_bench_dir

DRIVER = Path(__file__).with_name("driver.py")
_BATCH = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
NOGGING_OUTCOMES = {"done": "completed", "timeout": "timeout"}  # anything else is agent_error


class StepError(Exception):
    """An infrastructure step failed; the message becomes the result line's reason."""


@dataclass(frozen=True)
class Task:
    data: dict
    dir: Path

    @property
    def id(self) -> str:
        return self.data["id"]

    def issue_text(self) -> str:
        return (self.dir / self.data["issue"]).read_text(encoding="utf-8")

    @property
    def hidden_patch(self) -> Path:
        return self.dir / self.data["hidden_tests"]["patch"]


def find_task(bench: Path, task_id: str) -> Task:
    for root in (bench / "tasks", bench / "examples" / "tasks"):
        path = root / task_id / "task.yaml"
        if path.is_file():
            data = load_yaml(path)
            problems = check_task(data, dir_name=task_id)
            if problems:
                raise RecordError(problems[0].at(str(path)))
            return Task(data, path.parent)
    raise RecordError(Problem(f"tasks/{task_id}", "(path)", "no task.yaml under bench/tasks or bench/examples/tasks"))


@dataclass
class Runner:
    """Runs one arm on one task; every outside dependency is injectable for tests."""

    bench: Path
    results_dir: Path
    nogging_checkout: Path
    smoke: bool
    preregistration_hash: str | None
    environ: Mapping[str, str]
    clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)
    docker_binary: str = "docker"
    agent_stub: Path | None = None
    bench_commit: str = field(default="")

    def run(self, arm: Arm, task: Task, seed: int, batch: str, run_id: str) -> dict:
        rec = results.RunRecord(
            run_id=run_id, batch=batch, arm=arm.id, task=task.id, seed=seed,
            size_class=task.data["size_class"], started_at=self.clock(),
            provenance={
                "arm_file_hash": arm.arm_file_hash, "prompt_hash": arm.prompt_hash,
                "nogging_ref": arm.data.get("nogging_ref"), "bench_commit": self.bench_commit or "unknown",
                "preregistration_hash": self.preregistration_hash, "smoke": self.smoke,
            },
        )
        run_dir = self.results_dir / "runs" / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        log = RunLog(run_dir / "run.log", Redactor())
        docker = Docker(log, self.docker_binary)
        container = f"nogg-bench-{run_id}-{uuid.uuid4().hex[:8]}"
        scratch = Path(tempfile.mkdtemp(prefix="nogg-bench-run-"))
        try:
            with Credentials(arm.credentials, self.environ, agents.CREDENTIAL_FILES.get(arm.cli, ())) as creds:
                log.redactor = creds.redactor()
                self._execute(arm, task, rec, run_dir, docker, container, scratch, creds)
        except (StepError, CredentialError, DockerError, workspace.WorkspaceError, usage.UsageHelperError) as exc:
            rec.fail(str(exc))
        except Exception as exc:  # every run leaves a line, whatever broke
            rec.fail(f"unexpected {type(exc).__name__}: {exc}")
        finally:
            if "image_digest" in rec.provenance:  # docker answered, so a container may exist
                try:
                    docker.remove(container)
                except DockerError:
                    pass
            shutil.rmtree(scratch, ignore_errors=True)
        if rec.reason is not None:  # redact first, then shorten, so no prefix of a value survives
            rec.reason = log.redactor.redact(rec.reason)[:300]
            if rec.status == "infra_error":
                log.write(f"infra_error: {rec.reason}")
        rec.ended_at = self.clock()
        return rec.line()

    def _execute(self, arm, task, rec, run_dir, docker, name, scratch, creds) -> None:
        env = task.data["environment"]
        redactor = docker.log.redactor
        rec.provenance["image_digest"] = docker.image_digest(env["image"])
        repo = scratch / "repo"
        workspace.prepare_repo(task.data, self.bench, repo)
        (scratch / "brief.md").write_text(arm.render_prompt(task.issue_text()), encoding="utf-8")
        tools = self._bench_dir(arm, scratch)

        docker.start(name, env["image"])
        docker.copy_in(name, repo, "/work/repo")
        docker.copy_in(name, scratch / "brief.md", "/work/brief.md")
        docker.copy_in(name, tools, "/work/bench")
        for command in env["setup"]:
            done = docker.exec(name, command, timeout=1800)
            if done.returncode != 0:
                raise StepError(f"setup command failed (exit {done.returncode}): {command}")
        self._install(arm, docker, name)
        version = docker.exec(name, f"{arm.cli} --version", timeout=120)
        if version.returncode != 0:
            raise StepError(f"agent CLI {arm.cli} does not run in the container")
        rec.provenance["agent_cli_version"] = (version.stdout.strip().splitlines() or ["unknown"])[0]
        if creds.staged_dir is not None:
            docker.copy_in(name, f"{creds.staged_dir}/.", f"{agents.HOME}/{agents.CONFIG_DIRS[arm.cli]}")
        self._step(docker, name, agents.HAND_OVER, "handing /work to the agent user")

        # The agent, as the unprivileged user. Hidden tests are nowhere in the container.
        before = self.clock()
        done = docker.exec(
            name, agents.launch_command(arm), env_file=creds.env_file, user=agents.AGENT_USER,
            timeout=agents.outer_timeout(arm) + agents.KILL_AFTER_SECONDS + 60,
        )
        elapsed = (self.clock() - before).total_seconds()
        # Nothing the agent started (a tmux server, a background job) survives this.
        docker.restart(name)
        if creds.staged_dir is not None:
            # A subscription token refreshed during the run is a secret too.
            for i, path in enumerate(agents.credential_paths(arm.cli, creds.files)):
                landing = scratch / f"credential-{i}"
                if docker.copy_out(name, path, landing) and landing.is_file() and not landing.is_symlink():
                    redactor.add_file(landing)
                    landing.unlink()
            self._step(docker, name, agents.remove_credentials_script(arm.cli, creds.files),
                       "removing the credential files")
        if agents.timed_out(done.returncode, elapsed, agents.outer_timeout(arm)):
            rec.status = "timeout"
        elif done.returncode != 0:
            rec.status, rec.reason = "agent_error", f"agent exited with status {done.returncode}"
        else:
            rec.status = "completed"
        diff_base, rec.pr_count = task.data["base_commit"], 1
        if arm.kind == "nogging":
            diff_base = self._driver_state(rec, docker, name, scratch, diff_base)
        self._copy_out(docker, name, "/work/bench/agent.log", scratch, run_dir / "agent.log")

        # Step 4: the diff and the transcripts.
        diff = docker.exec(name, workspace.diff_script(diff_base), timeout=600)
        if diff.returncode != 0:
            raise StepError(f"saving the diff failed: {_last_line(diff.stderr)}")
        (run_dir / "diff.patch").write_text(redactor.redact(diff.stdout), encoding="utf-8")
        stats = workspace.parse_patch(diff.stdout)
        rec.diff_stats, rec.markdown_lines = stats.diff_stats(), stats.markdown_lines
        rec.diff_path = f"runs/{rec.run_id}/diff.patch"
        transcripts = run_dir / "transcripts"
        transcripts.mkdir(exist_ok=True)
        for cli, rel in agents.TRANSCRIPT_DIRS.items():
            self._copy_out(docker, name, f"{agents.HOME}/{rel}", scratch, transcripts / cli)

        # Step 5: now, and only now, the hidden tests.
        hidden = workspace.parse_patch(task.hidden_patch.read_text(encoding="utf-8"))
        rec.hidden_paths_overwritten = workspace.overwritten_paths(stats, hidden)
        docker.copy_in(name, task.hidden_patch, "/work/hidden.patch")
        applied = docker.exec(name, workspace.restore_script(task.data["base_commit"], hidden), timeout=300)
        if applied.returncode != 0:
            raise StepError(f"applying the hidden tests failed: {_last_line(applied.stderr)}")
        tested = docker.exec(name, workspace.test_script(task.data), timeout=env["test_timeout_seconds"])
        output = tested.stdout + tested.stderr
        (run_dir / "tests.log").write_text(redactor.redact(output), encoding="utf-8")
        rec.tests = workspace.parse_test_output(output, task.data)

        # Step 6: usage and the contamination scan.
        counted = usage.collect(self.nogging_checkout, [transcripts / "claude"], [transcripts / "codex"])
        rec.usage_collector = counted.collector()
        if not counted.usage:
            raise StepError("usage helper found no token usage in the transcripts")
        rec.usage = counted.usage
        reasons = scan.scan(scan.transcript_files(transcripts), [task.data["issue_url"], task.data["fix_pr_url"]])
        rec.contamination_suspect = bool(reasons)
        for reason in reasons:
            docker.log.write(f"contamination suspect: {reason}")

    @staticmethod
    def _step(docker: Docker, name: str, script: str, what: str, user: str | None = None) -> None:
        done = docker.exec(name, script, timeout=300, user=user)
        if done.returncode != 0:
            raise StepError(f"{what} failed (exit {done.returncode})")

    @staticmethod
    def _copy_out(docker: Docker, name: str, source: str, scratch: Path, dest: Path) -> bool:
        """Copy out through the scratch directory: redacted, without symlinks, into ``dest``."""
        landing = scratch / "out" / uuid.uuid4().hex
        landing.parent.mkdir(exist_ok=True)
        if not docker.copy_out(name, source, landing):
            return False
        docker.log.redactor.import_tree(landing, dest)
        return True

    def _bench_dir(self, arm: Arm, scratch: Path) -> Path:
        """``/work/bench`` of the container: the agent and install scripts, and for a nogging arm
        the driver and Nogging's source at the arm's ref, without its ``bench/``."""
        tools = scratch / "bench"
        tools.mkdir()
        (tools / "agent.sh").write_text(agents.agent_script(arm), encoding="utf-8")
        (tools / "install.sh").write_text(agents.INSTALL, encoding="utf-8")
        (tools / "tools.sh").write_text(agents.TOOLS, encoding="utf-8")
        if arm.kind == "nogging":
            shutil.copy(DRIVER, tools / "driver.py")
            archive = scratch / "nogging.tar"
            # A later ref carries bench/ itself: hidden tests, fix URLs, earlier runs. Never ship it.
            done = subprocess.run(
                ["git", "-C", str(self.nogging_checkout), "archive", "--format=tar", "--prefix=nogging/",
                 "-o", str(archive), arm.data["nogging_ref"], "--", ".", ":(exclude)bench"],
                capture_output=True, text=True, check=False,
            )
            if done.returncode != 0:
                raise StepError(f"Nogging {arm.data['nogging_ref']} is not in {self.nogging_checkout}")
            with tarfile.open(archive) as tar:
                if any(m.name == "nogging/bench" or m.name.startswith("nogging/bench/") for m in tar.getmembers()):
                    raise StepError("the Nogging archive still holds bench/; refusing to copy it in")
                tar.extractall(tools, filter="data")
        return tools

    def _install(self, arm: Arm, docker: Docker, name: str) -> None:
        done = docker.exec(name, "sh ../bench/tools.sh", timeout=1800)
        if done.returncode != 0:
            raise StepError(f"installing git and timeout in the container failed (exit {done.returncode})")
        self._step(docker, name, agents.USER_SETUP, f"creating the agent user {agents.AGENT_USER}")
        if self.agent_stub is not None:
            docker.copy_in(name, self.agent_stub, f"/usr/local/bin/{arm.cli}")
            return
        if arm.kind == "nogging":
            for tool in ("bd", "dolt"):
                found = shutil.which(tool)
                if not found:
                    raise StepError(f"{tool} is not on the host's PATH; a nogging arm copies it in")
                docker.copy_in(name, found, f"/usr/local/bin/{tool}")
        version = arm.data["agent"]["version"]
        done = docker.exec(name, f"sh ../bench/install.sh {arm.kind} {arm.cli} {version}", timeout=1800)
        if done.returncode != 0:
            raise StepError(f"installing {arm.cli} {version} failed (exit {done.returncode})")

    def _driver_state(self, rec, docker: Docker, name: str, scratch: Path, task_base: str) -> str:
        """Read the driver's ``state.json`` (agent-writable, so every field is checked):
        outcome, diff base and integrated branches. Returns the diff base."""
        path = scratch / "state.json"
        state = None
        if docker.copy_out(name, "/work/bench/state.json", path) and path.is_file() and not path.is_symlink():
            try:
                state = json.loads(path.read_text(encoding="utf-8", errors="replace"))
            except ValueError:
                state = None
        diff_base = state.get("diff_base") if isinstance(state, dict) else None
        if not (isinstance(diff_base, str) and re.fullmatch(r"[0-9a-f]{40}", diff_base)):
            # The driver writes its state right after installing Nogging, so without one
            # nothing was installed and the task's base is the diff base.
            rec.pr_count = 0
            if rec.status != "timeout":
                rec.status = "agent_error"
            rec.reason = "the nogging driver left no usable state.json"
            return task_base
        outcome = state.get("outcome")
        if rec.status != "timeout":
            rec.status = NOGGING_OUTCOMES.get(outcome, "agent_error")
        rec.reason = None
        if rec.status == "agent_error":
            rec.reason = f"nogging driver: {outcome}: {state.get('reason') or 'no reason given'}"
        count = state.get("pr_count")
        rec.pr_count = count if isinstance(count, int) and not isinstance(count, bool) and count >= 0 else 0
        return diff_base


def _last_line(text: str) -> str:
    return (text.strip().splitlines() or ["no message"])[-1]


# ------------------------------------------------------------- command line


def add_parser(sub) -> None:
    p = sub.add_parser(
        "run",
        help="run arms on tasks in containers and append one result line per run",
        description="Run each combination of --arm, --task and --seed in a fresh container. "
        "Combinations already in the batch file are skipped unless --rerun is given.",
    )
    p.add_argument("--arm", action="append", required=True, help="arm id, e.g. A (repeatable)")
    p.add_argument("--task", action="append", required=True, help="task id (repeatable)")
    p.add_argument("--seed", action="append", type=int, required=True, help="replicate index (repeatable)")
    p.add_argument("--batch", required=True, help="batch name; results go to results/<batch>.jsonl")
    p.add_argument("--smoke", action="store_true", help="a trial run: no preregistration needed, kept out of reports")
    p.add_argument("--rerun", action="store_true", help="run combinations that already have a result line again")
    p.add_argument("--retry-infra", action="store_true",
                   help="run combinations whose only lines are infra_error again")
    p.add_argument("--bench-dir", help="the bench directory (default: found from the working directory)")
    p.add_argument("--results-dir", help="where batch files and run directories go (default: <bench>/results)")
    p.add_argument("--nogging-checkout", help="Nogging checkout for the usage helper and nogging arms (default: the bench's repository)")
    p.add_argument("--agent-stub", help="with --smoke only: copy this executable in as the agent CLI instead of installing it")
    p.set_defaults(handler=command)


def command(args: argparse.Namespace, *, environ: Mapping[str, str] | None = None,
            clock: Callable[[], datetime] | None = None) -> int:
    import os

    bench = Path(args.bench_dir).resolve() if args.bench_dir else find_bench_dir()
    results_dir = Path(args.results_dir).resolve() if args.results_dir else bench / "results"
    checkout = Path(args.nogging_checkout).resolve() if args.nogging_checkout else bench.parent
    refusals: list[str] = []
    if not _BATCH.match(args.batch):
        refusals.append(f"batch name {args.batch!r} must be lower-case letters, digits, '.', '_' or '-'")
    if args.agent_stub and not args.smoke:
        refusals.append("--agent-stub is only allowed with --smoke")
    try:
        arms = [find_arm(bench, a) for a in dict.fromkeys(args.arm)]
        tasks = [find_task(bench, t) for t in dict.fromkeys(args.task)]
    except RecordError as exc:
        print(f"run: refused: {exc}", file=sys.stderr)
        return 2
    refusals += comparability_problems(arms)
    prereg_hash = None
    if not args.smoke:
        prereg_hash, gate = prereg.preregistration_hash(bench)
        refusals += gate
        for task in tasks:
            refusals += prereg.task_refusals(task.data)
    if refusals:
        for refusal in refusals:
            print(f"run: refused: {refusal}", file=sys.stderr)
        return 2

    runner = Runner(
        bench=bench, results_dir=results_dir, nogging_checkout=checkout, smoke=args.smoke,
        preregistration_hash=prereg_hash, environ=os.environ if environ is None else environ,
        agent_stub=Path(args.agent_stub).resolve() if args.agent_stub else None,
        bench_commit=prereg.bench_commit(bench),
    )
    if clock is not None:
        runner.clock = clock
    batch_file = results_dir / f"{args.batch}.jsonl"
    try:
        done, taken, smoke_flags = results.recorded(batch_file, retry_infra=args.retry_infra)
    except RecordError as exc:
        print(f"run: refused: {exc}", file=sys.stderr)
        return 2
    if smoke_flags - {args.smoke}:
        kind = "smoke" if args.smoke else "measured"
        print(f"run: refused: batch {args.batch} already holds runs that are not {kind}; "
              "keep smoke and measured runs in separate batches", file=sys.stderr)
        return 2
    status = 0
    for arm in arms:
        for task in tasks:
            for seed in dict.fromkeys(args.seed):
                if (arm.id, task.id, seed) in done and not args.rerun:
                    print(f"run: skip {arm.id} {task.id} seed {seed}: already recorded in {batch_file.name}")
                    continue
                run_id = results.unique_run_id(results.run_id_for(args.batch, arm.id, task.id, seed), taken)
                line = runner.run(arm, task, seed, args.batch, run_id)
                taken.add(run_id)
                try:
                    results.append(batch_file, line)
                except results.ResultError as exc:  # a bug: say so and go on with the batch
                    print(f"run: {run_id}: not recorded: {exc}", file=sys.stderr)
                    status = 1
                    continue
                print(f"run: {run_id}: {line['status']}, passed={str(line['passed']).lower()}"
                      + (f" ({line['reason']})" if line.get("reason") else ""))
                if line["status"] == "infra_error":
                    status = 1
    return status
