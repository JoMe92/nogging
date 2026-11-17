"""The repository the agent sees, its diff, and the hidden tests (design Decision 7).

:func:`prepare_repo` clones the task's repository on the host and truncates it
to ``base_commit``: one branch at the base, no tag, no remote, no reflog and no
unreachable object, so the fix is not in the history the container receives.
The rest are pure functions over patch text and test output.
"""

from __future__ import annotations

import re
import shlex
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

BRANCH = "main"


class WorkspaceError(Exception):
    pass


def _git(repo: Path, *args: str) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise WorkspaceError(f"git {args[0]} failed: {done.stderr.strip().splitlines()[-1:] or ['']}")
    return done.stdout


def repo_source(task: dict, bench: Path) -> str:
    repo = task["repo"]
    return repo if re.match(r"^[a-z][a-z0-9+.-]*://|^git@", repo) else str(bench / repo)


def prepare_repo(task: dict, bench: Path, dest: Path) -> None:
    """Clone the task's repository into ``dest`` at ``base_commit``, history truncated."""
    done = subprocess.run(
        ["git", "clone", "--quiet", "--no-checkout", repo_source(task, bench), str(dest)],
        capture_output=True, text=True, check=False,
    )
    if done.returncode != 0:
        raise WorkspaceError(f"cloning {task['repo']} failed: {done.stderr.strip()}")
    base = task["base_commit"]
    _git(dest, "checkout", "--quiet", "-B", BRANCH, base)
    for ref in _git(dest, "for-each-ref", "--format=%(refname)").split():
        if ref != f"refs/heads/{BRANCH}":
            _git(dest, "update-ref", "-d", ref)
    for remote in _git(dest, "remote").split():
        _git(dest, "remote", "remove", remote)
    for leftover in ("FETCH_HEAD", "ORIG_HEAD", "packed-refs.lock"):
        (dest / ".git" / leftover).unlink(missing_ok=True)
    _git(dest, "reflog", "expire", "--expire=now", "--all")
    _git(dest, "gc", "--quiet", "--prune=now")
    _git(dest, "config", "user.name", "bench")
    _git(dest, "config", "user.email", "bench@example.invalid")
    problems = history_problems(dest, base)
    if problems:
        raise WorkspaceError("; ".join(problems))


def history_problems(repo: Path, base: str) -> list[str]:
    """What in ``repo`` would reveal a commit after ``base``: later commits, refs, remotes, objects."""
    out: list[str] = []
    later = _git(repo, "rev-list", "--all", f"^{base}").split()
    if later:
        out.append(f"{len(later)} commit(s) after the base commit are reachable")
    remotes = _git(repo, "remote").split()
    if remotes:
        out.append(f"remote(s) left: {', '.join(remotes)}")
    refs = [r for r in _git(repo, "for-each-ref", "--format=%(refname)").split() if r != f"refs/heads/{BRANCH}"]
    if refs:
        out.append(f"ref(s) left: {', '.join(refs)}")
    reachable = set(_git(repo, "rev-list", "--all").split())
    stored = set()
    for line in _git(repo, "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)").splitlines():
        sha, kind = line.split()
        if kind == "commit":
            stored.add(sha)
    if stored - reachable:
        out.append(f"{len(stored - reachable)} unreachable commit object(s) are stored")
    return out


# ----------------------------------------------------------------- patches


@dataclass
class PatchStats:
    files: list[str] = field(default_factory=list)
    new_files: set[str] = field(default_factory=set)
    insertions: int = 0
    deletions: int = 0
    markdown_lines: int = 0

    def diff_stats(self) -> dict:
        return {"files_changed": len(self.files), "insertions": self.insertions, "deletions": self.deletions}


def _unquote(path: str) -> str:
    path = path.strip()
    if path.startswith('"') and path.endswith('"'):
        path = path[1:-1].encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")
    return path


def parse_patch(text: str) -> PatchStats:
    """Files, insertions, deletions and added Markdown lines of a ``git diff`` patch."""
    stats = PatchStats()
    current: str | None = None
    old: str | None = None
    in_hunk = False
    for line in text.splitlines():
        if line.startswith("diff --git "):
            in_hunk, current, old = False, None, None
            match = re.match(r'^diff --git "?a/(.+?)"? "?b/(.+?)"?$', line)
            if match:
                current = _unquote(match.group(2))
                stats.files.append(current)
            continue
        if not in_hunk:
            if line.startswith("--- "):
                old = line[4:]
            elif line.startswith("+++ ") and current is not None:
                new = _unquote(line[4:])
                if new != "/dev/null":
                    current = new[2:] if new.startswith("b/") else new
                    stats.files[-1] = current
                if old == "/dev/null":
                    stats.new_files.add(current)
            elif line.startswith("new file mode") and current is not None:
                stats.new_files.add(current)
            if line.startswith("@@"):
                in_hunk = True
            continue
        if line.startswith("@@"):
            continue
        if line.startswith("+"):
            stats.insertions += 1
            if current and current.lower().endswith(".md"):
                stats.markdown_lines += 1
        elif line.startswith("-"):
            stats.deletions += 1
    return stats


def overwritten_paths(agent: PatchStats, hidden: PatchStats) -> list[str]:
    """The hidden test paths the agent's diff also touched."""
    return sorted(set(agent.files) & set(hidden.files))


def restore_script(base: str, hidden: PatchStats, patch_path: str = "../hidden.patch") -> str:
    """Shell that puts every hidden path back to the base version, then applies the hidden tests."""
    existing = [p for p in hidden.files if p not in hidden.new_files]
    steps = []
    if existing:
        steps.append(f"git checkout --quiet {shlex.quote(base)} -- {shlex.join(existing)}")
    if hidden.new_files:
        steps.append(f"rm -rf -- {shlex.join(sorted(hidden.new_files))}")
    steps.append(f"git apply --whitespace=nowarn {shlex.quote(patch_path)}")
    return " && ".join(steps)


def diff_script(diff_base: str) -> str:
    """Shell that prints the work against ``diff_base``: committed, uncommitted and new files."""
    return f"git add --all --intent-to-add . >/dev/null 2>&1; git diff --binary {shlex.quote(diff_base)}"


# ------------------------------------------------------------------- tests


def test_script(task: dict) -> str:
    hidden = task["hidden_tests"]
    ids = [*hidden["fail_to_pass"], *hidden["pass_to_pass"]]
    return task["environment"]["test_command"].replace("{tests}", shlex.join(ids))


_OUTCOME = re.compile(r"^(PASSED|FAILED|ERROR|XPASS|XFAIL|SKIPPED)\s+(.+?)(?:\s+-\s.*)?$")


def parse_test_output(output: str, task: dict) -> dict:
    """Per-test results from ``PASSED <id>`` / ``FAILED <id>`` lines (``pytest -rA``).

    A test passes only when it is reported ``PASSED`` and nothing else (an
    ``ERROR`` in teardown after ``PASSED`` fails it). A test that is not
    reported at all fails.
    """
    seen: dict[str, set[str]] = {}
    for line in output.splitlines():
        match = _OUTCOME.match(line.strip())
        if match:
            seen.setdefault(match.group(2).strip(), set()).add(match.group(1))
    hidden = task["hidden_tests"]
    return {
        group: {ident: seen.get(ident) == {"PASSED"} for ident in hidden[group]}
        for group in ("fail_to_pass", "pass_to_pass")
    }


def passes(tests: dict) -> bool:
    """The pass rule: every fail-to-pass and every pass-to-pass test passed."""
    f2p, p2p = tests.get("fail_to_pass", {}), tests.get("pass_to_pass", {})
    return bool(f2p) and all(f2p.values()) and all(p2p.values())
