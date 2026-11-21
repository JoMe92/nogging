"""``nogg-bench candidates``: collect repositories and issues by the preregistered criteria.

Design Decision 18. ``repos`` searches GitHub through the ``gh`` command line
(read-only calls) and writes the pool snapshot and the pool log; ``skip``
records why the curating agent passed over a repository; ``issues`` writes one
``candidate`` task per qualifying issue of the repositories taken in draw
order. Every number comes from the committed preregistration.

Files under ``bench/curation/``: ``pool.json`` (the snapshot: time, queries,
the qualifying repositories per language in draw order), ``pool-log.jsonl``
(every repository not taken, with its reason), ``recipes/<owner>__<name>.yaml``
(the environment of a repository, written by the curating agent).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import yaml

from nogg_bench import selection, workspace
from nogg_bench.records import RecordError, load_yaml
from nogg_bench.schema import check_task
from nogg_bench.selection import Selection, SelectionError
from nogg_bench.validate import find_bench_dir

POOL = "curation/pool.json"
POOL_LOG = "curation/pool-log.jsonl"
RECIPES = "curation/recipes"
DEFAULT_DEPTH = 10

ISSUES_QUERY = """\
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 50, after: $cursor, states: CLOSED, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title body url closedAt stateReason
        closedByPullRequestsReferences(first: 10, includeClosedPrs: true) {
          nodes { number url merged baseRefOid author { __typename login } }
        }
      }
    }
  }
}"""


class CurationError(Exception):
    """A curation command refuses; the message says why."""


class Gh:
    """The ``gh`` command line, for reading only: ``GET`` calls and one GraphQL query."""

    def __init__(self, binary: str = "gh") -> None:
        self.binary = binary

    def _run(self, args: list[str]) -> str:
        try:
            done = subprocess.run([self.binary, "api", *args], capture_output=True, text=True, check=False)
        except FileNotFoundError as exc:
            raise CurationError(f"{self.binary} not found") from exc
        if done.returncode != 0:
            last = (done.stderr.strip().splitlines() or [""])[-1]
            raise CurationError(f"gh api {args[2] if args[:1] == ['--method'] else args[0]} failed: {last}")
        return done.stdout

    def get(self, endpoint: str, params: dict[str, Any] | None = None, *, accept: str | None = None) -> Any:
        args = ["--method", "GET", endpoint]
        for key, value in (params or {}).items():
            args += ["-f", f"{key}={value}"]
        if accept:
            return self._run([*args, "-H", f"Accept: {accept}"])
        return json.loads(self._run(args))

    def issues_page(self, owner: str, name: str, cursor: str | None) -> dict:
        args = ["graphql", "-f", f"query={ISSUES_QUERY}", "-f", f"owner={owner}", "-f", f"name={name}"]
        if cursor:
            args += ["-f", f"cursor={cursor}"]
        data = json.loads(self._run(args))
        try:
            return data["data"]["repository"]["issues"]
        except (KeyError, TypeError):
            raise CurationError(f"gh api graphql returned no issues for {owner}/{name}") from None


def _stamp(now: datetime) -> str:
    return now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _append(path: Path, entry: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")


def _read_json(path: Path, what: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CurationError(f"{what} {path} cannot be read; run `candidates repos` first") from exc


# -------------------------------------------------------------------- repos


def collect_repos(bench: Path, gh: Gh, now: datetime, *, depth: int = DEFAULT_DEPTH, max_pages: int = 10) -> dict:
    """Search, apply every repository criterion in draw order, write the pool and its log."""
    sel, blob = selection.committed_selection(bench)
    pool_path, log_path = bench / POOL, bench / POOL_LOG
    if pool_path.exists():
        raise CurationError(f"{POOL} exists; the pool is taken once and committed before anything else")
    excluded = selection.load_exclusions(bench / sel.exclusion_list)
    pushed = (now - timedelta(days=sel.last_commit_within_days)).date()
    merged = (now - timedelta(days=sel.merged_pull_requests_within_days)).date()
    queries, kept, unchecked = [], [], {}
    for language in sel.languages:
        query = f"language:{language} stars:{sel.min_stars}..{sel.max_stars} pushed:>={pushed} archived:false fork:false"
        queries.append(query)
        found: dict[str, dict] = {}
        for page in range(1, max_pages + 1):
            items = gh.get("search/repositories", {"q": query, "sort": "stars", "order": "desc",
                                                   "per_page": 100, "page": page}).get("items", [])
            found.update({item["full_name"]: item for item in items})
            if len(items) < 100:
                break
        qualifying = 0
        for rank, name in enumerate(selection.ranked(sel.seed, found), start=1):
            repo = found[name]
            reason = selection.repo_refusal(repo, sel, excluded)
            if reason is None and qualifying >= depth:
                unchecked[language] = unchecked.get(language, 0) + 1
                continue
            if reason is None:
                commits = gh.get(f"repos/{name}/commits", {"per_page": 1})
                last = datetime.fromisoformat(commits[0]["commit"]["committer"]["date"].replace("Z", "+00:00"))
                count = gh.get("search/issues", {"q": f"repo:{name} is:pr is:merged merged:>={merged}",
                                                 "per_page": 1})["total_count"]
                reason = selection.activity_refusal(last, count, now, sel)
            if reason is not None:
                _append(log_path, {"repo": name, "reason": reason, "by": "candidates repos", "at": _stamp(now)})
                continue
            qualifying += 1
            kept.append({
                "full_name": name, "language": language, "rank": rank, "license": repo["license"]["spdx_id"],
                "stars": repo["stargazers_count"], "default_branch": repo.get("default_branch"),
                "last_commit_at": _stamp(last), "merged_pull_requests": count,
            })
    pool = {"schema": 1, "taken_at": _stamp(now), "seed": sel.seed, "preregistration_hash": blob,
            "queries": queries, "depth": depth, "unchecked": unchecked, "repositories": kept}
    pool_path.parent.mkdir(parents=True, exist_ok=True)
    pool_path.write_text(json.dumps(pool, indent=2) + "\n", encoding="utf-8")
    return pool


def record_skip(bench: Path, repo: str, reason: str, now: datetime) -> None:
    """The curating agent's one freedom: pass over a pool repository, with the reason on record."""
    pool = _read_json(bench / POOL, "the pool")
    if repo not in {r["full_name"] for r in pool["repositories"]}:
        raise CurationError(f"{repo} is not in {POOL}")
    if not reason.strip():
        raise CurationError("a skip needs a reason")
    _append(bench / POOL_LOG, {"repo": repo, "reason": reason.strip(), "by": "candidates skip", "at": _stamp(now)})


def recipe_path(bench: Path, full_name: str) -> Path:
    return bench / RECIPES / (full_name.replace("/", "__") + ".yaml")


def chosen_repositories(bench: Path, sel: Selection) -> list[dict]:
    """The repositories taken per language in draw order: not skipped, each with a recipe."""
    pool = _read_json(bench / POOL, "the pool")
    log = bench / POOL_LOG
    skipped = {json.loads(line)["repo"] for line in log.read_text(encoding="utf-8").splitlines()} if log.is_file() else set()
    chosen: list[dict] = []
    for language, want in sel.repositories.items():
        mine = sorted((r for r in pool["repositories"] if r["language"] == language), key=lambda r: r["rank"])
        taken = [r for r in mine if r["full_name"] not in skipped][:want]
        if len(taken) < want:
            raise CurationError(f"the pool has {len(taken)} {language} repositories left, {want} are needed")
        for repo in taken:
            recipe = recipe_path(bench, repo["full_name"])
            if not recipe.is_file():
                raise CurationError(
                    f"{repo['full_name']} is next in draw order for {language}: write its environment recipe "
                    f"{recipe.relative_to(bench)} or record a skip with `candidates skip`")
        chosen += taken
    return chosen


# ------------------------------------------------------------------- issues


def split_patch(text: str) -> tuple[str, str, workspace.PatchStats]:
    """``(test changes, non-test changes, stats of the non-test changes)`` of a pull request diff."""
    tests, other = [], []
    for chunk in re.split(r"(?m)^(?=diff --git )", text):
        files = workspace.parse_patch(chunk).files
        if files:
            (tests if selection.is_test_file(files[0]) else other).append(chunk)
    return "".join(tests), "".join(other), workspace.parse_patch("".join(other))


def task_id(full_name: str, number: int) -> str:
    return re.sub(r"[^a-z0-9]+", "-", f"{full_name}-{number}".lower()).strip("-")


def issue_refusal(issue: dict) -> tuple[str | None, dict | None]:
    """``(reason, None)`` when the issue's links disqualify it, else ``(None, the fix pull request)``."""
    if issue.get("stateReason") != "COMPLETED":
        return "not closed as completed", None
    linked = [p for p in (issue.get("closedByPullRequestsReferences") or {}).get("nodes") or [] if p and p.get("merged")]
    if len(linked) != 1:
        return f"{len(linked)} linked merged pull requests, exactly one is needed", None
    author = linked[0].get("author") or {}
    if selection.is_bot(author.get("login"), author.get("__typename")):
        return "the fix pull request's author is a bot account", None
    return None, linked[0]


def collect_issues(bench: Path, gh: Gh) -> dict[str, Counter]:
    """Write a ``candidate`` task per qualifying issue; returns the outcome counts per repository."""
    sel, _ = selection.committed_selection(bench)
    summary: dict[str, Counter] = {}
    for repo in chosen_repositories(bench, sel):
        full_name = repo["full_name"]
        try:
            recipe = load_yaml(recipe_path(bench, full_name))
        except RecordError as exc:
            raise CurationError(str(exc.problem)) from exc
        counts = summary.setdefault(full_name, Counter())
        owner, name = full_name.split("/", 1)
        cursor = None
        while True:
            page = gh.issues_page(owner, name, cursor)
            for issue in page["nodes"]:
                counts[_candidate(bench, gh, sel, repo, recipe, issue)] += 1
            if not page["pageInfo"]["hasNextPage"]:
                break
            cursor = page["pageInfo"]["endCursor"]
    return summary


def _candidate(bench: Path, gh: Gh, sel: Selection, repo: dict, recipe: Any, issue: dict) -> str:
    """Write the task for one issue, or return why it is not a candidate."""
    reason, fix = issue_refusal(issue)
    if reason:
        return reason
    full_name = repo["full_name"]
    text = f"# {issue['title']}\n\n{(issue.get('body') or '').strip()}\n"
    reason = selection.issue_text_refusal(text, fix["url"])
    if reason:
        return reason
    diff = gh.get(f"repos/{full_name}/pulls/{fix['number']}", accept="application/vnd.github.diff")
    tests, other, stats = split_patch(diff)
    if not tests or not other:
        return "the fix does not change both test and non-test files"
    ident = task_id(full_name, issue["number"])
    task_dir = bench / "tasks" / ident
    if task_dir.exists():
        return "already written"
    task = {
        "schema": 1, "id": ident, "repo": f"https://github.com/{full_name}.git", "base_commit": fix["baseRefOid"],
        "language": repo["language"], "license": repo["license"], "issue": "issue.md",
        "issue_url": issue["url"], "fix_pr_url": fix["url"], "issue_closed_at": issue["closedAt"],
        "size_class": selection.size_class(len(stats.files), stats.insertions + stats.deletions, sel),
        "environment": recipe,
        "hidden_tests": {"patch": "hidden/tests.patch", "fail_to_pass": [], "pass_to_pass": []},
        "curation": {"status": "candidate"},
    }
    problems = check_task(task, dir_name=ident)
    if problems:
        raise CurationError(f"candidate {ident} is not a valid task: {problems[0].field}: {problems[0].message}")
    (task_dir / "hidden").mkdir(parents=True)
    (task_dir / "task.yaml").write_text(yaml.safe_dump(task, sort_keys=False), encoding="utf-8")
    (task_dir / "issue.md").write_text(text, encoding="utf-8")
    (task_dir / "hidden" / "tests.patch").write_text(tests, encoding="utf-8")
    (task_dir / "hidden" / "fix.patch").write_text(other, encoding="utf-8")
    return "candidate"


# ---------------------------------------------------------------------- cli


def add_parser(sub) -> None:
    parser = sub.add_parser(
        "candidates", help="collect repositories and issues by the preregistered criteria",
        description="Collect benchmark candidates mechanically (design Decision 18).",
    )
    parser.add_argument("--bench-dir", help="the bench directory (default: found from the working directory)")
    parser.add_argument("--gh", default="gh", help=argparse.SUPPRESS)
    steps = parser.add_subparsers(dest="step", metavar="<step>")
    steps.required = True
    repos = steps.add_parser("repos", help="search GitHub and write the pool snapshot and the pool log")
    repos.add_argument("--depth", type=int, default=DEFAULT_DEPTH,
                       help="qualifying repositories to keep per language, in draw order (default: %(default)s)")
    steps.add_parser("issues", help="write a candidate task per qualifying issue of the repositories taken")
    skip = steps.add_parser("skip", help="record why a pool repository is passed over")
    skip.add_argument("repo", help="owner/name as in the pool")
    skip.add_argument("--reason", required=True)
    parser.set_defaults(handler=command)


def command(args: argparse.Namespace) -> int:
    bench = Path(args.bench_dir).resolve() if args.bench_dir else find_bench_dir()
    now = datetime.now(timezone.utc)
    try:
        if args.step == "repos":
            pool = collect_repos(bench, Gh(args.gh), now, depth=args.depth)
            print(f"candidates repos: {len(pool['repositories'])} repositories in {POOL}; the rest in {POOL_LOG}")
        elif args.step == "skip":
            record_skip(bench, args.repo, args.reason, now)
        else:
            for repo, counts in collect_issues(bench, Gh(args.gh)).items():
                print(f"candidates issues: {repo}: " + "; ".join(f"{n} {what}" for what, n in sorted(counts.items())))
    except (CurationError, SelectionError) as exc:
        print(f"nogg-bench candidates {args.step}: {exc}", file=sys.stderr)
        return 1
    return 0
