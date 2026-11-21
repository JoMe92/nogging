"""``nogg-bench verify``: check a candidate's hidden tests in its task container.

Design Decision 18. For each candidate the whole suite runs with the hidden
test patch on ``base_commit`` and again with the fix's non-test changes
(``hidden/fix.patch``, written by ``candidates issues``) applied, each side as
often as the preregistration says (``runs_per_side``).
Fail-to-pass is what fails at the base and passes on the fix, pass-to-pass
what passes on both. A candidate is dropped, with the reason recorded, when
that set is empty, when the runs of one side disagree, when the setup fails or
when the suite runs over the preregistered time limit.

``verify`` writes the identifiers and ``hidden_tests_verified_by: nogg-bench
verify <bench commit>`` with ``verified_on`` into the task, appends one line
per candidate to ``curation/verification.jsonl`` and never sets ``accepted``.
A candidate with a line there is not checked again: a second try could turn a
flaky drop into a pass.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import yaml

from nogg_bench import agents, prereg, selection, workspace
from nogg_bench.candidates import CurationError
from nogg_bench.credentials import Redactor
from nogg_bench.docker import Docker, DockerError, RunLog
from nogg_bench.records import RecordError, load_yaml
from nogg_bench.schema import check_task
from nogg_bench.selection import SelectionError
from nogg_bench.validate import find_bench_dir

VERIFIER = "nogg-bench verify"
RECORDS = "curation/verification.jsonl"
LOGS = "curation/verify-logs"
FIX_PATCH = "fix.patch"  # next to the hidden test patch


class Dropped(Exception):
    """The candidate is dropped; the message is the recorded reason."""


def outcomes(output: str) -> dict[str, bool]:
    """``{test identifier: passed}`` from ``PASSED <id>`` / ``FAILED <id>`` lines (``pytest -rA``).

    As in a run, a test passes only when it is reported ``PASSED`` and nothing else.
    """
    seen: dict[str, set[str]] = {}
    for line in output.splitlines():
        match = workspace._OUTCOME.match(line.strip())
        if match:
            seen.setdefault(match.group(2).strip(), set()).add(match.group(1))
    return {ident: kinds == {"PASSED"} for ident, kinds in seen.items()}


def derive(base: dict[str, bool], fix: dict[str, bool]) -> tuple[list[str], list[str]]:
    """``(fail_to_pass, pass_to_pass)``; a test not reported at the base fails there."""
    passing = sorted(ident for ident, ok in fix.items() if ok)
    return [t for t in passing if not base.get(t, False)], [t for t in passing if base.get(t, False)]


def verified(task: dict) -> bool:
    """Whether ``verify`` has passed this task: its mark, its date and a fail-to-pass test."""
    curation = task.get("curation") or {}
    return (str(curation.get("hidden_tests_verified_by", "")).startswith(VERIFIER + " ")
            and "verified_on" in curation and bool((task.get("hidden_tests") or {}).get("fail_to_pass")))


@dataclass
class Verifier:
    bench: Path
    suite_time_limit: int  # seconds, from the preregistration
    runs_per_side: int  # suite runs at the base and on the fix, from the preregistration
    bench_commit: str
    clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)
    docker_binary: str = "docker"

    def verify(self, task_dir: Path) -> dict:
        """Check one candidate, write the outcome into its ``task.yaml`` and return the record line."""
        path = task_dir / "task.yaml"
        task = load_yaml(path)
        problems = check_task(task, dir_name=task_dir.name)
        if problems:
            raise RecordError(problems[0].at(str(path)))
        if task["curation"]["status"] != "candidate":
            raise CurationError(f"task {task['id']} has curation.status {task['curation']['status']}; "
                                "verify checks candidates only")
        log_path = self.bench / LOGS / f"{task['id']}.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        docker = Docker(RunLog(log_path, Redactor()), self.docker_binary)
        name = f"nogg-bench-verify-{task['id']}"
        by = f"{VERIFIER} {self.bench_commit}"
        record = {"task": task["id"], "outcome": "verified", "reason": None, "verified_by": by,
                  "at": self.clock().astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
        curation = {"status": "candidate"}
        try:
            with tempfile.TemporaryDirectory(prefix="nogg-bench-verify-") as scratch:
                f2p, p2p = self._check(task, task_dir, docker, name, Path(scratch))
            curation.update(hidden_tests_verified_by=by, verified_on=self.clock().date())
        except Dropped as exc:
            f2p, p2p = [], []
            record.update(outcome="dropped", reason=str(exc))
            docker.log.write(f"dropped: {exc}")
        finally:
            docker.remove(name)
        task["hidden_tests"].update(fail_to_pass=f2p, pass_to_pass=p2p)
        task["curation"] = curation
        path.write_text(yaml.safe_dump(task, sort_keys=False), encoding="utf-8")
        record.update(fail_to_pass=len(f2p), pass_to_pass=len(p2p))
        with (self.bench / RECORDS).open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        return record

    def _check(self, task: dict, task_dir: Path, docker: Docker, name: str, scratch: Path) -> tuple[list[str], list[str]]:
        env = task["environment"]
        hidden = task_dir / task["hidden_tests"]["patch"]
        fix = hidden.parent / FIX_PATCH
        if not hidden.is_file() or not fix.is_file():
            raise Dropped(f"the task has no {hidden.name} or no {FIX_PATCH} under hidden/")
        try:
            workspace.prepare_repo(task, self.bench, scratch / "repo")
        except workspace.WorkspaceError as exc:
            raise Dropped(f"setup failed: {exc}") from exc
        docker.image_digest(env["image"])
        docker.remove(name)  # a container left by an interrupted check
        docker.start(name, env["image"])
        docker.copy_in(name, scratch / "repo", "/work/repo")
        docker.copy_in(name, hidden, "/work/hidden.patch")
        docker.copy_in(name, fix, f"/work/{FIX_PATCH}")
        for command in env["setup"]:
            done = docker.exec(name, command, timeout=1800)
            if done.returncode != 0:
                raise Dropped(f"setup failed (exit {done.returncode}): {command}")
        (scratch / "tools.sh").write_text(agents.TOOLS, encoding="utf-8")  # git, as a run installs it
        docker.copy_in(name, scratch / "tools.sh", "/work/tools.sh")
        if docker.exec(name, "sh ../tools.sh", timeout=1800).returncode != 0:
            raise Dropped("setup failed: git could not be installed in the container")
        suite = env["test_command"].replace("{tests}", "").strip()
        self._apply(docker, name, "hidden.patch", "the hidden test patch does not apply at the base commit")
        base = self._runs(docker, name, suite, "at the base commit")
        self._apply(docker, name, FIX_PATCH, "the fix's non-test changes do not apply at the base commit")
        fixed = self._runs(docker, name, suite, "on the fix")
        f2p, p2p = derive(base, fixed)
        if not f2p:
            raise Dropped("no test fails at the base commit and passes on the fix")
        return f2p, p2p

    @staticmethod
    def _apply(docker: Docker, name: str, patch: str, failure: str) -> None:
        if docker.exec(name, f"git apply --whitespace=nowarn ../{patch}", timeout=300).returncode != 0:
            raise Dropped(failure)

    def _runs(self, docker: Docker, name: str, suite: str, where: str) -> dict[str, bool]:
        runs = []
        for _ in range(self.runs_per_side):
            done = docker.exec(name, suite, timeout=self.suite_time_limit)
            if done.returncode is None:
                raise Dropped(f"the suite ran over the time limit of {self.suite_time_limit} seconds {where}")
            runs.append(outcomes(done.stdout + done.stderr))
            if not runs[-1]:
                raise Dropped(f"the suite reported no test {where} (exit {done.returncode})")
        differing = sorted(t for t in set().union(*runs) if len({run.get(t) for run in runs}) > 1)
        if differing:
            raise Dropped(f"flaky {where}: the runs disagree on {', '.join(differing)}")
        return runs[0]


def recorded(bench: Path) -> set[str]:
    path = bench / RECORDS
    return {json.loads(line)["task"] for line in path.read_text(encoding="utf-8").splitlines()} if path.is_file() else set()


def add_parser(sub) -> None:
    parser = sub.add_parser(
        "verify", help="check candidates' hidden tests at the base commit and on the fix",
        description="Verify candidate tasks in their task containers (design Decision 18).",
    )
    parser.add_argument("tasks", nargs="*", help="task IDs (default: every candidate without a verification record)")
    parser.add_argument("--bench-dir", help="the bench directory (default: found from the working directory)")
    parser.add_argument("--docker", default="docker", help=argparse.SUPPRESS)
    parser.set_defaults(handler=command)


def command(args: argparse.Namespace, *, clock: Callable[[], datetime] | None = None) -> int:
    bench = Path(args.bench_dir).resolve() if args.bench_dir else find_bench_dir()
    try:
        sel, _ = selection.committed_selection(bench)
        done = recorded(bench)
        again = sorted(set(args.tasks) & done)
        if again:
            raise CurationError(f"{', '.join(again)} already in {RECORDS}; a candidate is checked once")
        dirs = [bench / "tasks" / t for t in args.tasks] or sorted(
            p.parent for p in (bench / "tasks").glob("*/task.yaml")
            if p.parent.name not in done and (load_yaml(p).get("curation") or {}).get("status") == "candidate")
        verifier = Verifier(bench, sel.suite_time_limit_seconds, sel.runs_per_side, prereg.bench_commit(bench),
                            docker_binary=args.docker)
        if clock is not None:
            verifier.clock = clock
        for task_dir in dirs:
            record = verifier.verify(task_dir)
            detail = record["reason"] or f"{record['fail_to_pass']} fail-to-pass, {record['pass_to_pass']} pass-to-pass"
            print(f"verify: {record['task']}: {record['outcome']}: {detail}")
    except (CurationError, SelectionError, DockerError) as exc:
        print(f"nogg-bench verify: {exc}", file=sys.stderr)
        return 1
    except RecordError as exc:
        print(f"nogg-bench verify: {exc.problem}", file=sys.stderr)
        return 1
    return 0
