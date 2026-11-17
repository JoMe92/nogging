"""The unattended driver of a ``nogging`` arm (design Decision 7). It runs inside the container.

    python3 driver.py --brief ../brief.md --agent claude --model M --effort E \\
        --timebox SECONDS --nogging ../bench/nogging --state ../bench/state.json

Run from the task repository (``/work/repo``), it plays the Product Owner:

1. installs Nogging from the source tree at the arm's ref (``node bin/cli.js
   init``), commits that as the diff base, and gives the repository a
   ``develop`` branch and a local bare ``origin`` seeded from the truncated
   history (Nogging's worktrees branch from ``origin/develop``);
2. starts a planning session whose kickoff is the brief, waits for its done
   signal, or for it to go idle with a new change on a plan branch (v3.6.0's
   planning prompt has no signal step), merges the plan branch into
   ``develop`` (no approval step) and materialises the change's Beads;
3. starts a ``--full-access`` Lead for the first ready Bead with the whole
   change authorised, and waits for its done signal or the timebox;
4. merges every implementation branch into ``develop`` (the count is the
   result line's ``pr_count``), stops its sessions and writes ``state.json``.

Every session is launched with the arm's agent, model and effort as explicit
flags, so Nogging's tier routing cannot pick another model. The driver uses
only the standard library: the container has python3, nothing else from the
bench. Its outside world (commands, clock, sleep) is injectable for tests.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

NOGG = "./scripts/nogg"
POLL_SECONDS = 30
PROTECTED = {"main", "develop", "HEAD"}


@dataclass
class Result:
    returncode: int
    stdout: str
    stderr: str


def run_command(argv: list[str], cwd: Path | None = None) -> Result:
    done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, stdin=subprocess.DEVNULL, check=False)
    return Result(done.returncode, done.stdout, done.stderr)


class DriverError(Exception):
    """A step of the driver failed; ``outcome`` goes to ``state.json``."""

    def __init__(self, outcome: str, reason: str) -> None:
        super().__init__(reason)
        self.outcome = outcome
        self.reason = reason


@dataclass
class Driver:
    repo: Path
    brief: str
    agent: str
    model: str
    effort: str
    timebox: float
    nogging: Path
    run: Callable[..., Result] = run_command
    clock: Callable[[], float] = time.monotonic
    sleep: Callable[[float], None] = time.sleep
    log: Callable[[str], None] = lambda line: print(line, flush=True)
    save: Callable[[dict], None] = lambda state: None
    sessions: list[str] = field(default_factory=list)
    state: dict = field(default_factory=dict)

    # -- plumbing ----------------------------------------------------------

    def sh(self, *argv: str, what: str) -> str:
        self.log("$ " + " ".join(argv))
        done = self.run(list(argv), cwd=self.repo)
        if done.returncode != 0:
            last = (done.stderr.strip().splitlines() or done.stdout.strip().splitlines() or ["no output"])[-1]
            raise DriverError("error", f"{what} failed: {last}")
        return done.stdout

    def git(self, *args: str, what: str = "git") -> str:
        return self.sh("git", *args, what=what)

    def launch_flags(self) -> list[str]:
        return ["--agent", self.agent, "--model", self.model, "--effort", self.effort, "--full-access"]

    def launch(self, *args: str, what: str) -> str:
        out = self.sh(NOGG, "session", "launch", *args, *self.launch_flags(), what=what)
        match = re.search(r"^launched (\S+)", out, re.M)
        if not match:
            raise DriverError("error", f"{what}: no session name in the launch output")
        self.sessions.append(match.group(1))
        return match.group(1)

    def wait(self, name: str, deadline: float, settled: Callable[[], bool] | None = None) -> tuple[str, str | None]:
        """Poll the session's watch events until it signals or ends, or the deadline passes.

        ``settled`` decides for a session that goes idle or ends without a done
        signal (a planning session has no signal step) whether its work is there.
        """
        while True:
            out = self.run([NOGG, "session", "watch", "--once", "--format", "jsonl", name], cwd=self.repo).stdout
            for line in out.splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                kind = event.get("event") if isinstance(event, dict) else None
                if kind in ("idle", "ended") and settled is not None and settled():
                    return "done", f"the session went {kind} with its work pushed"
                if kind in ("done", "blocked", "ended"):
                    return kind, event.get("reason")
            if self.clock() >= deadline:
                return "timeout", None
            self.sleep(min(POLL_SECONDS, max(deadline - self.clock(), 0)))

    # -- the steps ---------------------------------------------------------

    def install(self) -> None:
        self.sh("node", str(self.nogging / "bin" / "cli.js"), "init", what="installing Nogging")
        if not (self.repo / ".beads").exists():
            self.sh("bd", "init", what="initialising Beads")
        self.git("add", "--all")
        self.git("commit", "--quiet", "--allow-empty", "-m", "chore: install Nogging for the benchmark")
        self.state["diff_base"] = self.git("rev-parse", "HEAD").strip()
        self.save(self.state)  # a later kill still leaves the diff base behind
        self.git("branch", "--force", "develop")
        self.git("checkout", "--quiet", "develop")
        self.git("init", "--quiet", "--bare", str(self.repo.parent / "origin.git"))
        self.git("remote", "add", "origin", str(self.repo.parent / "origin.git"))
        self.git("push", "--quiet", "origin", "main", "develop")

    def changes(self) -> set[str]:
        root = self.repo / "openspec" / "changes"
        return {p.name for p in root.iterdir() if p.is_dir() and p.name != "archive"} if root.is_dir() else set()

    def branches(self) -> list[str]:
        """Local and origin branches, short names, without duplicates."""
        self.run(["git", "fetch", "--quiet", "origin"], cwd=self.repo)
        out = self.git("for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes/origin")
        names: list[str] = []
        for ref in out.split():
            short = ref.split("/", 2)[2] if ref.startswith("refs/heads/") else ref.split("/", 3)[3]
            if short not in names and short not in PROTECTED:
                names.append(short)
        return names

    def merge(self, branch: str) -> bool:
        """Merge ``branch`` (local, else origin's) into develop; False when it adds nothing or conflicts."""
        local = self.run(["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"], cwd=self.repo)
        ref = branch if local.returncode == 0 else f"origin/{branch}"
        ahead = self.git("rev-list", "--count", f"develop..{ref}").strip()
        if ahead == "0":
            return False
        merged = self.run(["git", "merge", "--no-ff", "--quiet", "-m", f"Merge {branch}", ref], cwd=self.repo)
        if merged.returncode != 0:
            self.run(["git", "merge", "--abort"], cwd=self.repo)
            self.log(f"merge of {branch} conflicts; left out")
            return False
        return True

    def planned_changes(self, before: set[str]) -> set[str]:
        """New openspec changes on any plan branch."""
        found: set[str] = set()
        for branch in self.branches():
            if not branch.startswith("plan/"):
                continue
            local = self.run(["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"], cwd=self.repo)
            ref = branch if local.returncode == 0 else f"origin/{branch}"
            listed = self.run(["git", "ls-tree", "-d", "--name-only", f"{ref}:openspec/changes"], cwd=self.repo)
            if listed.returncode == 0:
                found |= {n for n in listed.stdout.split() if n != "archive"} - before
        return found

    def plan(self, deadline: float) -> str:
        before = self.changes()
        name = self.launch("--role", "planning", "--planning-id", "bench", "--description", "benchmark-issue",
                           what="launching the planning session")
        self.sh(NOGG, "session", "kickoff", name, "--message", self.brief, what="kicking off planning")
        outcome, reason = self.wait(name, deadline, settled=lambda: bool(self.planned_changes(before)))
        if outcome != "done":
            raise DriverError("timeout" if outcome == "timeout" else f"planning-{outcome}",
                              reason or f"the planning session ended as {outcome}")
        for branch in self.branches():
            if branch.startswith("plan/"):
                self.merge(branch)
        self.git("push", "--quiet", "origin", "develop")
        new = sorted(self.changes() - before)
        if not new:
            raise DriverError("planning-no-change", "the planning session left no new openspec change")
        change = new[0]
        self.state["change"] = change
        # The planning session may have materialised the Beads itself; a refusal here is not fatal.
        done = self.run([NOGG, "materialize", change], cwd=self.repo)
        if done.returncode != 0:
            self.log(f"materialize {change}: exit {done.returncode} (the planning session may have done it)")
        return change

    def lead(self, change: str, deadline: float) -> tuple[str, str | None]:
        out = self.sh("bd", "ready", "--label", f"openspec:change:{change}", "--exclude-label", "po-only",
                      "--json", what="finding the first ready Bead")
        try:
            beads = json.loads(out or "[]")
        except ValueError as exc:
            raise DriverError("error", f"bd ready printed no JSON: {exc}") from exc
        if not beads:
            raise DriverError("lead-no-bead", f"no ready Bead for change {change}")
        name = self.launch("--role", "lead", "--bead", beads[0]["id"], what="launching the Lead")
        self.sh(NOGG, "session", "kickoff", name, "--change", change, what="kicking off the Lead")
        return self.wait(name, deadline)

    def integrate(self) -> int:
        """Merge every implementation branch into develop; the count is ``pr_count``."""
        count = 0
        for branch in self.branches():
            if not branch.startswith("plan/") and self.merge(branch):
                count += 1
        return count

    def stop_sessions(self) -> None:
        for name in self.sessions:
            self.run([NOGG, "session", "stop", name], cwd=self.repo)

    def drive(self) -> dict:
        deadline = self.clock() + self.timebox
        self.state.update(outcome="error", reason=None, pr_count=0, sessions=self.sessions)
        try:
            self.install()
            change = self.plan(deadline)
            outcome, reason = self.lead(change, deadline)
            self.state.update(outcome=outcome, reason=reason)
        except DriverError as exc:
            self.state.update(outcome=exc.outcome, reason=exc.reason)
        finally:
            self.stop_sessions()
            if "diff_base" in self.state:
                try:
                    self.git("checkout", "--quiet", "develop")
                    self.state["pr_count"] = self.integrate()
                except DriverError as exc:
                    self.log(f"integration failed: {exc.reason}")
            self.save(self.state)
        return self.state


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Drive a nogging arm unattended.")
    p.add_argument("--brief", required=True, type=Path)
    p.add_argument("--agent", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--effort", required=True)
    p.add_argument("--timebox", required=True, type=float, help="seconds")
    p.add_argument("--nogging", required=True, type=Path, help="Nogging source tree at the arm's ref")
    p.add_argument("--state", required=True, type=Path)
    args = p.parse_args(argv)
    def save(state: dict) -> None:
        args.state.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")

    driver = Driver(
        repo=Path.cwd(), brief=args.brief.read_text(encoding="utf-8"), agent=args.agent, model=args.model,
        effort=args.effort, timebox=args.timebox, nogging=args.nogging.resolve(), save=save,
    )
    state = driver.drive()
    return 0 if state["outcome"] == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
