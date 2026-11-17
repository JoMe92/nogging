"""The arm C driver against a stub ``nogg`` that plans, leads and signals done (medium)."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import BENCH
from test_run import TRANSCRIPTS, bench, docker_calls, docker_env, stub_agent  # noqa: F401 - fixtures

from nogg_bench import cli
from nogg_bench import run as run_mod
from nogg_bench.driver import NOGG, Driver, Result

BRIEF = "Plan a change that resolves the issue below.\n<issue>app.txt says broken</issue>\n"
CHANGE = "fix-app-text"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout


class StubWorld:
    """Answers the driver's commands: real git, a scripted ``nogg``, ``node`` and ``bd``.

    ``planning`` and ``lead`` are the watch events each session reports, one per
    poll, the last one repeated; a session's work happens at its kickoff.
    """

    def __init__(self, repo: Path, planning=("working", "done"), lead=("working", "working", "done"),
                 lead_reason="PR #1 open") -> None:
        self.repo = repo
        self.events = {"planning": list(planning), "lead": list(lead)}
        self.lead_reason = lead_reason
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
