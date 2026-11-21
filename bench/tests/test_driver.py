"""The arm C driver against a stub ``nogg`` that plans, leads and signals done (medium)."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import BENCH
from test_run import TRANSCRIPTS, bench, docker_calls, docker_env, stub_agent  # noqa: F401 - fixtures

from nogg_bench import cli, forge
from nogg_bench import docker as docker_mod
from nogg_bench import run as run_mod
from nogg_bench.driver import NOGG, Driver, Result

BRIEF = "Plan a change that resolves the issue below.\n<issue>app.txt says broken</issue>\n"
CHANGE = "fix-app-text"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout


class StubWorld:
    """Answers the driver's commands: real git, a scripted ``nogg``, ``node`` and ``bd``.

    ``planning`` and ``lead`` are the watch events each session reports, one per
    poll, the last one repeated; a session's work happens at its kickoff. The Lead
    pushes its branch and calls ``gh`` (the real forge stand-in) with ``lead_gh``.
    """

    def __init__(self, repo: Path, planning=("working", "done"), lead=("working", "working", "done"),
                 lead_reason="PR #1 open", lead_gh=(("pr", "create", "--fill"),)) -> None:
        self.repo = repo
        self.events = {"planning": list(planning), "lead": list(lead)}
        self.lead_reason = lead_reason
        self.lead_gh = lead_gh
        self.gh: list[subprocess.CompletedProcess] = []
        self.calls: list[list[str]] = []
        self.now = 0.0
        self.sleeps: list[float] = []

    def clock(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def commit_on(self, branch: str, files: dict[str, str], message: str) -> None:
        """Commit ``files`` on a new branch from develop and push it, as a session would."""
        work = self.repo.parent / f"wt-{branch.replace('/', '-')}"
        git(self.repo, "worktree", "add", "--quiet", "-b", branch, str(work), "develop")
        for rel, text in files.items():
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            (work / rel).write_text(text)
        git(work, "add", "--all")
        git(work, "commit", "--quiet", "-m", message)
        git(work, "push", "--quiet", "origin", branch)

    def call_gh(self, branch: str, *argv: str) -> None:
        """The Lead's ``gh`` call in its worktree: the stand-in, run as the container runs it."""
        work = self.repo.parent / f"wt-{branch.replace('/', '-')}"
        self.gh.append(subprocess.run([sys.executable, "-I", forge.__file__, *argv], cwd=work,
                                      capture_output=True, text=True))

    def __call__(self, argv: list[str], cwd: Path | None = None) -> Result:
        self.calls.append(argv)
        if argv[0] == "git":
            done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
            return Result(done.returncode, done.stdout, done.stderr)
        if argv[0] == "node":  # nogg init: the installed tool files
            (self.repo / "scripts").mkdir(exist_ok=True)
            (self.repo / "scripts" / "nogg").write_text("#!/bin/sh\n")
            (self.repo / ".beads").mkdir(exist_ok=True)
            (self.repo / ".beads" / "config.yaml").write_text("prefix: bench\n")
            return Result(0, "installed\n", "")
        if argv[0] == "bd" and argv[1] == "ready":
            return Result(0, json.dumps([{"id": "bench-1"}, {"id": "bench-2"}]), "")
        if argv[0] != NOGG:
            return Result(127, "", f"{argv[0]}: not found")
        sub = argv[1:3]
        if sub == ["session", "launch"]:
            role = argv[argv.index("--role") + 1]
            return Result(0, f"note: something\nlaunched sf-{role}-bench\n", "")
        if sub == ["session", "kickoff"]:
            if argv[3] == "sf-planning-bench":
                self.commit_on("plan/bench/benchmark-issue", {
                    f"openspec/changes/{CHANGE}/proposal.md": "# Fix app text\n\nWhy and what.\n",
                    f"openspec/changes/{CHANGE}/tasks.md": "- [ ] TASK-FIX-001 fix app.txt\n",
                }, "plan: fix app text")
            else:
                self.commit_on(f"feat/{CHANGE}", {"app.txt": "fixed\n"}, "fix: app text")
                for argv in self.lead_gh:
                    self.call_gh(f"feat/{CHANGE}", *argv)
            return Result(0, "kicked off\n", "")
        if sub == ["session", "watch"]:
            role = "planning" if argv[-1] == "sf-planning-bench" else "lead"
            queue = self.events[role]
            event = queue.pop(0) if len(queue) > 1 else queue[0]
            reason = self.lead_reason if role == "lead" else "plan merged"
            return Result(0, json.dumps({"session": argv[-1], "event": event, "reason": reason}) + "\n", "")
        if argv[1] in ("materialize",) or sub == ["session", "stop"]:
            return Result(0, "", "")
        return Result(2, "", f"stub nogg: unexpected {argv}")


@pytest.fixture
def repo(tmp_path) -> Path:
    path = tmp_path / "repo"
    path.mkdir()
    git(path, "init", "--quiet", "-b", "main")
    git(path, "config", "user.email", "bench@example.invalid")
    git(path, "config", "user.name", "bench")
    (path / "app.txt").write_text("broken\n")
    git(path, "add", ".")
    git(path, "commit", "--quiet", "-m", "base")
    return path


def driver(repo: Path, world: StubWorld, timebox: float = 3600) -> Driver:
    return Driver(repo=repo, brief=BRIEF, agent="claude", model="claude-opus-5-5", effort="high",
                  timebox=timebox, nogging=repo.parent / "nogging", run=world, clock=world.clock,
                  sleep=world.sleep, log=lambda _line: None)


def nogg_calls(world: StubWorld, *sub: str) -> list[list[str]]:
    return [c for c in world.calls if c[0] == NOGG and c[1 : 1 + len(sub)] == list(sub)]


def test_the_driver_plans_leads_and_integrates(repo):
    world = StubWorld(repo)
    state = driver(repo, world).drive()
    assert state["outcome"] == "done" and state["reason"] == "PR #1 open"
    assert state["change"] == CHANGE and state["pr_count"] == 1
    assert state["sessions"] == ["sf-planning-bench", "sf-lead-bench"]
    # the diff base is the commit that installed Nogging, so its files are not counted as work
    assert git(repo, "log", "-1", "--format=%s", state["diff_base"]).strip() == "chore: install Nogging for the benchmark"
    changed = git(repo, "diff", "--name-only", state["diff_base"], "HEAD").split()
    assert sorted(changed) == ["app.txt", f"openspec/changes/{CHANGE}/proposal.md", f"openspec/changes/{CHANGE}/tasks.md"]
    assert (repo / "app.txt").read_text() == "fixed\n"
    assert git(repo, "branch", "--show-current").strip() == "develop"
    # every session gets the arm's agent, model and effort explicitly, and full access
    for launch in nogg_calls(world, "session", "launch"):
        assert launch[-7:] == ["--agent", "claude", "--model", "claude-opus-5-5", "--effort", "high", "--full-access"]
    plan_kickoff, lead_kickoff = nogg_calls(world, "session", "kickoff")
    assert plan_kickoff[-2:] == ["--message", BRIEF]  # the issue is the planning brief; no approval step
    assert lead_kickoff[-2:] == ["--change", CHANGE]
    assert ["--bead", "bench-1"] == nogg_calls(world, "session", "launch")[1][5:7]
    assert nogg_calls(world, "materialize") == [[NOGG, "materialize", CHANGE]]
    assert len(nogg_calls(world, "session", "stop")) == 2
    # the only remote is the local bare repository seeded from the truncated history
    assert git(repo, "remote", "get-url", "origin").strip() == str(repo.parent / "origin.git")


def pulls(repo: Path) -> list[dict]:
    return [json.loads(p.read_text()) for p in sorted((repo.parent / "forge" / "pulls").glob("*.json"))]


def test_the_leads_pull_request_is_recorded(repo):
    world = StubWorld(repo, lead_gh=(
        ("pr", "create", "--base", "develop", "--head", f"feat/{CHANGE}", "--title", "fix app text", "--body", "b"),
        ("pr", "checks", "--required", "--json", "name,state,bucket"),
        ("pr", "list", "--state", "open"), ("auth", "status"),
    ))
    state = driver(repo, world).drive()
    created, checks, listed, auth = world.gh
    # it succeeds without a network (the only remote is a directory), and the record is kept
    assert created.returncode == 0 and created.stdout == "https://forge.invalid/bench/repo/pull/1\n", created.stderr
    [record] = pulls(repo)
    assert (record["number"], record["head"], record["base"], record["title"]) == (
        1, f"feat/{CHANGE}", "develop", "fix app text")
    assert record["head_sha"] == git(repo, "rev-parse", f"origin/feat/{CHANGE}").strip()
    assert json.loads(checks.stdout) == [{"name": "bench-forge", "state": "SUCCESS", "bucket": "pass"}]
    assert listed.returncode == auth.returncode == 1 and "refused" in listed.stderr  # nothing else is answered
    assert state["outcome"] == "done" and state["pr_count"] == 1  # counted from the record


def test_pr_count_counts_recorded_pull_requests_not_branches(repo):
    # a Lead that pushes its branch but opens no pull request: the work is measured, pr_count is 0
    world = StubWorld(repo, lead_gh=())
    state = driver(repo, world).drive()
    assert (repo / "app.txt").read_text() == "fixed\n" and pulls(repo) == []
    assert state["outcome"] == "done" and state["pr_count"] == 0


def test_a_pull_request_merged_on_the_forge_is_in_the_result(repo):
    world = StubWorld(repo, lead_gh=(("pr", "create", "--fill"), ("pr", "merge", "--squash", "--delete-branch")))
    state = driver(repo, world).drive()
    assert [done.returncode for done in world.gh] == [0, 0], [done.stderr for done in world.gh]
    [record] = pulls(repo)
    assert record["state"] == "MERGED"
    assert git(repo, "merge-base", "--is-ancestor", record["merge_commit"], "develop") == ""
    assert (repo / "app.txt").read_text() == "fixed\n" and state["pr_count"] == 1


def test_a_forged_record_is_not_counted(repo):
    world = StubWorld(repo)
    d = driver(repo, world)
    d.drive()
    folder = repo.parent / "forge" / "pulls"
    base = d.state["diff_base"]
    (folder / "2.json").write_text(json.dumps({"number": 2, "head_sha": base}))  # nothing beyond the base
    (folder / "3.json").write_text(json.dumps({"number": 3, "head_sha": "--upload-pack=x", "merge_commit": 7}))
    (folder / "4.json").write_text(json.dumps({"number": 4, "head_sha": "ab" * 20}))  # no such commit
    (folder / "5.json").write_text("[1, 2]")
    (folder / "6.json").write_text("not json")
    assert d.integrate() == 1


def test_the_timebox_ends_a_driven_run(repo):
    world = StubWorld(repo, lead=("working",))
    state = driver(repo, world, timebox=200).drive()
    assert state["outcome"] == "timeout"
    assert world.now == 200 and all(s <= 30 for s in world.sleeps)  # injected sleep, never real
    assert len(nogg_calls(world, "session", "stop")) == 2
    assert state["pr_count"] == 1  # the work done so far is still integrated and measured


def test_a_blocked_planning_session_launches_no_lead(repo):
    world = StubWorld(repo, planning=("working", "blocked"))
    state = driver(repo, world).drive()
    assert state["outcome"] == "planning-blocked"
    assert [c[c.index("--role") + 1] for c in nogg_calls(world, "session", "launch")] == ["planning"]


def test_a_blocked_lead_is_reported_with_its_reason(repo):
    world = StubWorld(repo, lead=("blocked",), lead_reason="cannot open a pull request")
    state = driver(repo, world).drive()
    assert (state["outcome"], state["reason"], state["pr_count"]) == ("blocked", "cannot open a pull request", 1)


def test_a_failing_install_stops_the_driver(repo):
    def broken(argv, cwd=None):
        return Result(1, "", "Error: Node 16 is too old") if argv[0] == "node" else Result(0, "", "")

    state = Driver(repo=repo, brief=BRIEF, agent="claude", model="m", effort="e", timebox=10,
                   nogging=repo, run=broken, clock=lambda: 0.0, sleep=lambda s: None, log=lambda _l: None).drive()
    assert state == {"outcome": "error", "reason": "installing Nogging failed: Error: Node 16 is too old",
                     "pr_count": 0, "sessions": []}


# ---------------------------------------------------------- run with arm C

FAKE_DRIVER = '''\
import json, sys
from pathlib import Path
args = sys.argv[1:]
state = Path(args[args.index("--state") + 1])
seen = {"argv": args, "brief": Path(args[args.index("--brief") + 1]).read_text(),
        "nogging_tree": sorted(p.name for p in Path(args[args.index("--nogging") + 1]).iterdir())}
Path("../driver-saw.json").write_text(json.dumps(seen))
import subprocess
base = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
Path("app.txt").write_text("fixed\\n")
Path("PLAN.md").write_text("# Plan\\n\\nOne line.\\n")
home = Path.home() / ".claude/projects/-work-repo"
home.mkdir(parents=True, exist_ok=True)
(home / "lead.jsonl").write_text(Path(@TRANSCRIPT@).read_text())
import os
state.write_text(@STATE@)
'''


KEY = "sk-ant-test-0123456789"


def write_fake(path: Path, state_expr: str) -> None:
    transcript = repr(str(TRANSCRIPTS / "claude" / "-work-repo" / "sess-a.jsonl"))
    path.write_text(FAKE_DRIVER.replace("@TRANSCRIPT@", transcript).replace("@STATE@", state_expr))


@pytest.fixture
def nogging_checkout(tmp_path) -> Path:
    """A Nogging checkout with the token-usage adapters and a v3.6.0 tag."""
    root = tmp_path / "nogging"
    (root / "scripts" / "lib").mkdir(parents=True)
    for name in ("token_usage_adapters.py", "token_usage_store.py"):
        shutil.copy(BENCH.parent / "scripts" / "lib" / name, root / "scripts" / "lib" / name)
    (root / "bin").mkdir()
    (root / "bin" / "cli.js").write_text("// nogg\n")
    # a later ref also holds bench/ with hidden tests: it must never reach the container
    (root / "bench" / "tasks" / "t" / "hidden").mkdir(parents=True)
    (root / "bench" / "tasks" / "t" / "hidden" / "tests.patch").write_text("secret hidden test\n")
    git(root, "init", "--quiet", "-b", "main")
    git(root, "config", "user.email", "t@example.invalid")
    git(root, "config", "user.name", "t")
    git(root, "add", ".")
    git(root, "commit", "--quiet", "-m", "nogging")
    git(root, "tag", "v3.6.0")
    return root


def test_run_maps_the_driver_state(tmp_path, monkeypatch, nogging_checkout, bench, docker_env):
    for outcome, status in (("done", "completed"), ("blocked", "agent_error"), ("timeout", "timeout")):
        fake = tmp_path / f"driver-{outcome}.py"
        state = ('json.dumps({"outcome": %r, "reason": "r " + os.environ["ANTHROPIC_API_KEY"], '
                 '"diff_base": base, "pr_count": 2})' % outcome)
        write_fake(fake, state)
        monkeypatch.setattr(run_mod, "DRIVER", fake)
        args = cli.build_parser().parse_args(
            ["run", "--bench-dir", str(bench), "--batch", outcome, "--task", "stub-task", "--arm", "C",
             "--seed", "1", "--smoke", "--agent-stub", str(stub_agent(tmp_path)),
             "--nogging-checkout", str(nogging_checkout)])
        assert run_mod.command(args, environ={"ANTHROPIC_API_KEY": KEY}) == 0
        [line] = [json.loads(x) for x in (bench / "results" / f"{outcome}.jsonl").read_text().splitlines()]
        assert line["status"] == status, line
        assert line["pr_count"] == 2 and line["provenance"]["nogging_ref"] == "v3.6.0"
        assert line["markdown_lines"] == 3 and line["diff_stats"]["files_changed"] == 2
        assert line["passed"] is True
        assert (line.get("reason") is not None) == (status == "agent_error")
        assert KEY not in json.dumps(line)  # the driver's reason is agent-written: redacted
        if status == "agent_error":
            assert line["reason"] == "nogging driver: blocked: r [REDACTED]"
    saw = json.loads(next(docker_env["root"].glob("*/work/driver-saw.json")).read_text())
    assert saw["argv"][saw["argv"].index("--model") + 1] == "claude-opus-5-5"
    assert saw["argv"][saw["argv"].index("--timebox") + 1] == "5400"
    assert "app.txt says broken" in saw["brief"] and "needs no approval" in saw["brief"]
    assert saw["nogging_tree"] == ["bin", "scripts"]  # Nogging's source at the arm's ref
    agent = next(c for c in docker_calls(docker_env) if c[0] == "exec" and "agent.sh" in c[-1])
    assert agent[-1].startswith("exec timeout --kill-after=30 5700 ")  # timebox plus the driver's grace


def run_arms(bench: Path, batch: str, arms: list[str], stub: Path, nogging_checkout: Path) -> list[dict]:
    argv = ["run", "--bench-dir", str(bench), "--batch", batch, "--task", "stub-task", "--seed", "1", "--smoke",
            "--agent-stub", str(stub), "--nogging-checkout", str(nogging_checkout)]
    for arm in arms:
        argv += ["--arm", arm]
    env = {"ANTHROPIC_API_KEY": KEY, "OPENAI_API_KEY": KEY}
    assert run_mod.command(cli.build_parser().parse_args(argv), environ=env) == 0
    return [json.loads(x) for x in (bench / "results" / f"{batch}.jsonl").read_text().splitlines()]


def test_every_arm_gets_the_same_container(tmp_path, monkeypatch, nogging_checkout, bench, docker_env):
    fake = tmp_path / "driver.py"
    write_fake(fake, 'json.dumps({"outcome": "done", "diff_base": base, "pr_count": 1})')
    monkeypatch.setattr(run_mod, "DRIVER", fake)
    result_lines = run_arms(bench, "claude", ["A", "C"], stub_agent(tmp_path), nogging_checkout)
    result_lines += run_arms(bench, "codex", ["B"], stub_agent(tmp_path, cli_name="codex"), nogging_checkout)
    assert [x["arm"] for x in result_lines] == ["A", "C", "B"]
    starts = [c for c in docker_calls(docker_env) if c[0] == "run"]
    assert len(starts) == 3
    for start in starts:
        start[start.index("--name") + 1] = "<name>"  # the only word that differs between runs
    assert starts[0] == starts[1] == starts[2]
    security = [w for i, w in enumerate(starts[0]) if starts[0][i - 1] == "--security-opt"]
    assert security == ["seccomp=unconfined", "apparmor=unconfined"]
    for call in docker_calls(docker_env):  # no docker call of any arm asks for more
        assert "--privileged" not in call and not any(w.startswith("--cap-add") for w in call)
    options = [x["provenance"]["container_options"] for x in result_lines]
    assert options[0] == options[1] == options[2] == ["--security-opt", "seccomp=unconfined",
                                                      "--security-opt", "apparmor=unconfined"]


GH_DRIVER = '''\
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
def git(*a):
    return subprocess.run(["git", "-c", "user.name=bench", "-c", "user.email=bench@example.invalid", *a],
                          check=True, capture_output=True, text=True).stdout.strip()
base = git("rev-parse", "HEAD")
origin = Path("../origin.git").resolve()
git("init", "--quiet", "--bare", str(origin))
git("remote", "add", "origin", str(origin))
git("checkout", "--quiet", "-B", "develop")
git("push", "--quiet", "origin", "develop")
git("checkout", "--quiet", "-b", "feat/fix")
Path("app.txt").write_text("fixed\\n")
git("commit", "--quiet", "-am", "fix: app text")
git("push", "--quiet", "origin", "feat/fix")
# `gh` is whatever the container's PATH holds, called with a body that carries the credential
calls = [["pr", "create", "--base", "develop", "--head", "feat/fix", "--title", "fix app text",
          "--body", "key " + os.environ["ANTHROPIC_API_KEY"]], ["pr", "checks"], ["pr", "merge"], ["pr", "list"],
         ["api", "user"]]
saw = [subprocess.run(["gh", *c], capture_output=True, text=True) for c in calls]
Path("../gh-saw.json").write_text(json.dumps([[d.returncode, d.stdout, d.stderr] for d in saw]))
git("checkout", "--quiet", "develop")
git("pull", "--quiet", "origin", "develop")
home = Path.home() / ".claude/projects/-work-repo"
home.mkdir(parents=True, exist_ok=True)
(home / "lead.jsonl").write_text(Path(@TRANSCRIPT@).read_text())
pulls = sorted(Path("../forge/pulls").glob("*.json"))
Path(args[args.index("--state") + 1]).write_text(
    json.dumps({"outcome": "done", "diff_base": base, "pr_count": len(pulls)}))
'''


def test_run_puts_the_stand_in_on_the_path_and_keeps_its_records(tmp_path, monkeypatch, nogging_checkout, bench,
                                                                  docker_env):
    fake = tmp_path / "driver.py"
    fake.write_text(GH_DRIVER.replace("@TRANSCRIPT@", repr(str(TRANSCRIPTS / "claude" / "-work-repo" / "sess-a.jsonl"))))
    monkeypatch.setattr(run_mod, "DRIVER", fake)
    monkeypatch.setenv("PATH", f"{tmp_path / 'nogh'}{os.pathsep}{os.environ['PATH']}")
    (tmp_path / "nogh").mkdir()  # a host `gh` further down PATH must not be the one that answers
    [line_c, line_a] = run_arms(bench, "gh", ["C", "A"], stub_agent(tmp_path), nogging_checkout)
    assert (line_c["arm"], line_c["status"], line_c["pr_count"], line_c["passed"]) == ("C", "completed", 1, True), line_c
    created, checks, merged, listed, api = json.loads(next(docker_env["root"].glob("*/work/gh-saw.json")).read_text())
    assert created[:2] == [0, "https://forge.invalid/bench/repo/pull/1\n"] and checks[0] == merged[0] == 0
    assert listed[0] == api[0] == 1 and forge.NAME in listed[2] and "refused" in api[2]
    # the stand-in went in by `docker cp`, for the nogging arm only, and is this package's file
    copies = [c for c in docker_calls(docker_env) if c[0] == "cp" and c[-1].endswith(":/usr/local/bin/gh")]
    assert len(copies) == 1 and "gh-c-" in copies[0][-1]
    [installed] = docker_env["root"].glob("*/usr/local/bin/gh")  # arm A's container has none
    assert installed.read_bytes() == Path(forge.__file__).read_bytes() and os.access(installed, os.X_OK)
    # the run directory holds the record, redacted like every copy out of the container
    run_c = bench / "results" / "runs" / line_c["run_id"]
    record = json.loads((run_c / "forge" / "pulls" / "1.json").read_text())
    assert (record["title"], record["state"], record["body"]) == ("fix app text", "MERGED", "key [REDACTED]")
    calls = [json.loads(x)["call"] for x in (run_c / "forge" / "calls.jsonl").read_text().splitlines()]
    assert calls == ["pr create", "pr checks", "pr merge", "pr list", "api user"]
    assert KEY not in "".join(p.read_text() for p in run_c.rglob("*") if p.is_file())
    assert not (bench / "results" / "runs" / line_a["run_id"] / "forge").exists() and line_a["pr_count"] == 1


LARGE = pytest.mark.skipif(os.environ.get("NOGG_BENCH_DOCKER") != "1",
                           reason="large: needs NOGG_BENCH_DOCKER=1 and a Docker daemon")


@LARGE
@pytest.mark.parametrize("command", [
    "unshare --user --mount true",
    "unshare --user --map-root-user --mount sh -c 'mount -t tmpfs none /mnt'",
    # the full call of v3.6.0's scripts/openspec-sandbox
    "unshare --user --map-root-user --mount --pid --fork --kill-child=KILL --mount-proc true",
])
def test_large_the_container_options_allow_the_sandbox_namespaces(tmp_path, command):
    """Open check of TASK-BEN-010: the recorded options are enough for an unprivileged user."""
    from nogg_bench.credentials import Redactor

    docker = docker_mod.Docker(docker_mod.RunLog(tmp_path / "run.log", Redactor()))
    name = f"nogg-bench-large-options-{os.getpid()}"
    docker.start(name, "python:3.13-slim")
    try:
        done = docker.exec(name, command, workdir="/", user="nobody", timeout=120)
        assert done.returncode == 0, done.stderr
    finally:
        docker.remove(name)


@LARGE
@pytest.mark.skipif("ANTHROPIC_API_KEY" not in os.environ, reason="large: arm C needs the arm's credential")
def test_large_arm_c_finishes_a_smoke_run_on_an_example_task(tmp_path):
    """Open check of TASK-BEN-010: Nogging plans, leads, opens its pull request and signals done."""
    args = cli.build_parser().parse_args(
        ["run", "--bench-dir", str(BENCH), "--results-dir", str(tmp_path / "results"), "--batch", "large-c",
         "--arm", "C", "--task", "example-small-slugify", "--seed", "1", "--smoke"])
    assert run_mod.command(args) == 0
    [line] = [json.loads(x) for x in (tmp_path / "results" / "large-c.jsonl").read_text().splitlines()]
    assert line["status"] == "completed" and line["pr_count"] >= 1, line
    assert line["provenance"]["container_options"] == docker_mod.container_options()
    assert list((tmp_path / "results" / "runs" / line["run_id"] / "forge" / "pulls").glob("*.json"))


@pytest.mark.parametrize("state,status,pr_count", [
    ('json.dumps({"outcome": "done", "diff_base": base, "pr_count": "many"})', "completed", 0),
    ('json.dumps([1, 2])', "agent_error", 0),
    ('"not json"', "agent_error", 0),
    ('json.dumps({"outcome": "done", "diff_base": "../../etc", "pr_count": 1})', "agent_error", 0),
])
def test_a_malformed_driver_state_still_leaves_a_line(tmp_path, monkeypatch, nogging_checkout, bench, docker_env,
                                                      state, status, pr_count):
    fake = tmp_path / "driver.py"
    write_fake(fake, state)
    monkeypatch.setattr(run_mod, "DRIVER", fake)
    args = cli.build_parser().parse_args(
        ["run", "--bench-dir", str(bench), "--batch", "m", "--task", "stub-task", "--arm", "C", "--seed", "1",
         "--smoke", "--agent-stub", str(stub_agent(tmp_path)), "--nogging-checkout", str(nogging_checkout)])
    assert run_mod.command(args, environ={"ANTHROPIC_API_KEY": KEY}) == 0
    [line] = [json.loads(x) for x in (bench / "results" / "m.jsonl").read_text().splitlines()]
    assert (line["status"], line["pr_count"]) == (status, pr_count)


def test_a_planning_session_that_goes_idle_with_a_plan_counts_as_done(repo):
    world = StubWorld(repo, planning=("working", "idle"))
    state = driver(repo, world).drive()
    assert state["outcome"] == "done" and state["change"] == CHANGE


def test_an_idle_planning_session_without_a_plan_is_waited_for(repo):
    world = StubWorld(repo, planning=("idle",))
    world.commit_on = lambda *a, **k: None  # the planner never pushes a plan
    state = driver(repo, world, timebox=100).drive()
    assert state["outcome"] == "timeout"


def test_the_state_is_saved_right_after_the_install(repo):
    saved: list[dict] = []
    world = StubWorld(repo)
    d = driver(repo, world)
    d.save = lambda st: saved.append(dict(st))
    d.drive()
    assert saved[0]["diff_base"] and saved[0]["outcome"] == "error" and "change" not in saved[0]
    assert saved[-1]["outcome"] == "done"


def test_the_driver_module_runs_without_the_bench_package(tmp_path):
    """The container has python3 only: the driver must import nothing but the standard library."""
    copy = tmp_path / "driver.py"
    shutil.copy(run_mod.DRIVER, copy)
    done = subprocess.run([sys.executable, "-I", str(copy), "--help"], capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    assert "--timebox" in done.stdout
