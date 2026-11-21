#!/usr/bin/env python3
"""The local forge stand-in: ``gh`` on the ``PATH`` of a ``nogging`` arm's container (design Decision 20).

An unattended Nogging Lead ends by opening a pull request, and the run
container has a local bare ``origin`` and no forge. This file is copied in as
``/usr/local/bin/gh`` and answers exactly four calls against that origin:

    gh pr create   records a pull request for a pushed branch, prints its URL
    gh pr view     shows a recorded pull request (text, or --json fields)
    gh pr checks   reports one check, passed (there is no CI in the container)
    gh pr merge    merges the head into the base inside the bare origin

Every other call is refused with exit status 1. It never reaches the network:
it refuses an ``origin`` that is not a local bare repository, runs only local
git plumbing with ``--git-dir`` on it (never fetch, push or clone), and imports
no network module. It reads no credential and no environment variable.

Each pull request is one JSON file, ``<origin's parent>/forge/pulls/<n>.json``
(``/work/forge`` in the container); ``calls.jsonl`` beside it lists which calls
were answered and which refused, by subcommand only. The run copies the
directory into the run directory. Standard library only, like the driver.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

NAME = "gh (nogg-bench local forge stand-in)"
ANSWERED = ("create", "view", "checks", "merge")
DIR_NAME = "forge"
# .invalid never resolves (RFC 2606): the URL is a name for the record, not an address.
URL = "https://forge.invalid/bench/repo/pull/{number}"
CHECK = {"name": "bench-forge", "state": "SUCCESS", "bucket": "pass", "workflow": "", "link": "", "event": "",
         "description": "no CI in the run container; the stand-in reports checks as passed"}
IDENTITY = {"GIT_AUTHOR_NAME": "bench", "GIT_AUTHOR_EMAIL": "bench@example.invalid",
            "GIT_COMMITTER_NAME": "bench", "GIT_COMMITTER_EMAIL": "bench@example.invalid"}
_WORD = re.compile(r"^[a-z][a-z-]*$")


class Refused(Exception):
    """The call is not answered; the message goes to stderr and the exit status is 1."""


def run_git(argv: list[str], cwd: Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *argv], cwd=cwd, env={**os.environ, **(env or {})}, capture_output=True,
                          text=True, stdin=subprocess.DEVNULL, check=False)


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class _Parser(argparse.ArgumentParser):
    def __init__(self) -> None:
        super().__init__(add_help=False, allow_abbrev=False)

    def error(self, message: str):  # an unknown flag is a refusal, not a usage screen
        raise Refused(message)


def _parsers() -> dict[str, _Parser]:
    create, view, checks, merge = _Parser(), _Parser(), _Parser(), _Parser()
    create.add_argument("-B", "--base")
    create.add_argument("-H", "--head")
    create.add_argument("-t", "--title")
    create.add_argument("-b", "--body")
    create.add_argument("-F", "--body-file")
    create.add_argument("-d", "--draft", action="store_true")
    for flag in (("-f", "--fill"), ("--fill-first",), ("--fill-verbose",), ("--no-maintainer-edit",)):
        create.add_argument(*flag, action="store_true")
    for flag in (("-l", "--label"), ("-a", "--assignee"), ("-r", "--reviewer"), ("-m", "--milestone")):
        create.add_argument(*flag, action="append")  # accepted and not recorded: nobody reads them here
    for parser in (view, checks, merge):
        parser.add_argument("selector", nargs="?")
    for parser in (view, checks):
        parser.add_argument("--json")
        parser.add_argument("-q", "--jq")
    view.add_argument("-c", "--comments", action="store_true")
    for flag in ("--required", "--watch", "--fail-fast"):
        checks.add_argument(flag, action="store_true")
    checks.add_argument("-i", "--interval")
    merge.add_argument("-m", "--merge", action="store_true")
    merge.add_argument("-s", "--squash", action="store_true")
    merge.add_argument("-d", "--delete-branch", action="store_true")
    merge.add_argument("--auto", action="store_true")
    merge.add_argument("-t", "--subject")
    merge.add_argument("-b", "--body")
    return {"create": create, "view": view, "checks": checks, "merge": merge}


class Forge:
    def __init__(self, cwd: Path) -> None:
        self.cwd = cwd
        self.origin = self._origin()
        self.dir = self.origin.parent / DIR_NAME

    def _origin(self) -> Path:
        done = run_git(["remote", "get-url", "origin"], cwd=self.cwd)
        url = done.stdout.strip()
        if done.returncode != 0 or not url:
            raise Refused("no origin remote in this directory")
        path = Path(url)
        if "://" in url or not path.is_absolute() or not path.is_dir():
            raise Refused("origin is not a local repository; this stand-in never reaches the network")
        bare = run_git(["--git-dir", str(path), "rev-parse", "--is-bare-repository"])
        if bare.returncode != 0 or bare.stdout.strip() != "true":
            raise Refused("origin is not a local bare repository")
        return path

    def git(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
        return run_git(["--git-dir", str(self.origin), *args], env=env)

    def sha(self, branch: str) -> str | None:
        done = self.git("rev-parse", "--verify", "--quiet", f"refs/heads/{branch}^{{commit}}")
        return done.stdout.strip() if done.returncode == 0 else None

    # -- records -----------------------------------------------------------

    def pulls(self) -> list[dict]:
        found = []
        for path in (self.dir / "pulls").glob("*.json"):
            try:
                record = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(record, dict) and isinstance(record.get("number"), int):
                found.append(record)
        return sorted(found, key=lambda r: r["number"])

    def save(self, record: dict) -> None:
        path = self.dir / "pulls" / f"{record['number']}.json"
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, path)

    def reserve(self) -> int:
        """The next free number; the exclusive create keeps two concurrent calls apart."""
        (self.dir / "pulls").mkdir(parents=True, exist_ok=True)
        number = max([r["number"] for r in self.pulls()], default=0) + 1
        while True:
            try:
                os.close(os.open(self.dir / "pulls" / f"{number}.json", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
                return number
            except FileExistsError:
                number += 1

    def find(self, selector: str | None) -> dict:
        pulls = self.pulls()
        match = re.fullmatch(r"#?(\d+)|.*/pull/(\d+)/?", selector or "")
        if match:
            number = int(match.group(1) or match.group(2))
            found = [r for r in pulls if r["number"] == number]
            if not found:
                raise Refused(f"no pull request #{number} is recorded")
            return found[0]
        branch = selector or run_git(["branch", "--show-current"], cwd=self.cwd).stdout.strip()
        found = [r for r in pulls if r.get("head") == branch]
        if not found:
            raise Refused(f'no pull requests found for branch "{branch}"')
        return ([r for r in found if r.get("state") == "OPEN"] or found)[-1]

    # -- the four answers --------------------------------------------------

    def create(self, args: argparse.Namespace) -> int:
        head = args.head or run_git(["branch", "--show-current"], cwd=self.cwd).stdout.strip()
        base = args.base or ("develop" if self.sha("develop") else "main")
        if not head:
            raise Refused("not on a branch; name one with --head")
        if ":" in head:
            raise Refused("a head in another repository is not answered here")
        if head == base:
            raise Refused(f"head and base are both {base}")
        head_sha = self.sha(head)
        if self.sha(base) is None:
            raise Refused(f"base branch {base} is not in the local origin")
        if head_sha is None:
            raise Refused(f"branch {head} is not in the local origin; push it first (git push origin {head})")
        for other in self.pulls():
            if (other.get("head"), other.get("base"), other.get("state")) == (head, base, "OPEN"):
                raise Refused(f'a pull request for branch "{head}" into branch "{base}" already exists:\n{other["url"]}')
        body = args.body or ""
        if args.body_file:
            body = sys.stdin.read() if args.body_file == "-" else Path(args.body_file).read_text(encoding="utf-8")
        title = args.title or self.git("log", "-1", "--format=%s", head_sha).stdout.strip() or head
        number = self.reserve()
        record = {"number": number, "url": URL.format(number=number), "title": title, "body": body, "base": base,
                  "head": head, "head_sha": head_sha, "state": "OPEN", "draft": bool(args.draft),
                  "created_at": now(), "merged_at": None, "merge_commit": None}
        self.save(record)
        print(record["url"])
        return 0

    def view(self, args: argparse.Namespace) -> int:
        pr = self.find(args.selector)
        if args.json is not None or args.jq is not None:
            return _emit(self._as_gh(pr), args.json, args.jq)
        print(f"title:\t{pr['title']}\nstate:\t{pr['state']}\nnumber:\t{pr['number']}\nurl:\t{pr['url']}\n"
              f"base:\t{pr['base']}\nhead:\t{pr['head']}\nchecks:\tpassed\n--\n{pr.get('body') or ''}")
        return 0

    def checks(self, args: argparse.Namespace) -> int:
        self.find(args.selector)
        if args.json is not None or args.jq is not None:
            return _emit([CHECK], args.json, args.jq)
        print(f"{CHECK['name']}\tpass\t0\t\t{CHECK['description']}")
        return 0

    def merge(self, args: argparse.Namespace) -> int:
        pr = self.find(args.selector)
        number, base, head = pr["number"], pr["base"], pr["head"]
        if pr.get("state") == "MERGED":
            print(f"Pull request #{number} was already merged")
            return 0
        base_sha, head_sha = self.sha(base), self.sha(head)
        if base_sha is None or head_sha is None:
            raise Refused(f"pull request #{number}: branch {base if base_sha is None else head} is not in the local origin")
        tree = self.git("merge-tree", "--write-tree", base_sha, head_sha)
        if tree.returncode == 1:
            raise Refused(f"pull request #{number} is not mergeable: the merge has conflicts")
        if tree.returncode != 0:
            raise Refused("git merge-tree --write-tree failed (git 2.38 or later is needed)")
        parents = ["-p", base_sha] if args.squash else ["-p", base_sha, "-p", head_sha]
        message = args.subject or f"Merge pull request #{number} from {head}"
        commit = self.git("commit-tree", tree.stdout.split()[0], *parents, "-m", message, "-m", pr["title"], env=IDENTITY)
        if commit.returncode != 0:
            raise Refused(f"pull request #{number}: writing the merge commit failed")
        merged = commit.stdout.strip()
        if self.git("update-ref", f"refs/heads/{base}", merged, base_sha).returncode != 0:
            raise Refused(f"pull request #{number}: {base} moved during the merge; try again")
        pr.update(state="MERGED", merged_at=now(), merge_commit=merged, head_sha=head_sha,
                  merge_method="squash" if args.squash else "merge")
        self.save(pr)
        if args.delete_branch:
            print(f"note: branch {head} is kept; the benchmark measures it", file=sys.stderr)
        print(f"Merged pull request #{number} ({pr['title']})")
        return 0

    @staticmethod
    def _as_gh(pr: dict) -> dict:
        is_open = pr["state"] == "OPEN"
        return {
            "number": pr["number"], "url": pr["url"], "title": pr["title"], "body": pr.get("body") or "",
            "state": pr["state"], "isDraft": bool(pr.get("draft")), "baseRefName": pr["base"],
            "headRefName": pr["head"], "headRefOid": pr["head_sha"], "createdAt": pr["created_at"],
            "mergedAt": pr.get("merged_at"), "closed": not is_open, "reviewDecision": "",
            "mergeable": "MERGEABLE" if is_open else "UNKNOWN", "mergeStateStatus": "CLEAN" if is_open else "UNKNOWN",
            "statusCheckRollup": [{"__typename": "CheckRun", "name": CHECK["name"], "status": "COMPLETED",
                                   "conclusion": "SUCCESS"}],
        }


def _emit(data: dict | list, fields: str | None, jq: str | None) -> int:
    """``--json a,b`` picks fields; ``--jq .a`` then prints one of them. No other jq is answered."""
    names = [f for f in (fields or "").split(",") if f]
    if not names:
        raise Refused("--json needs field names, and --jq needs --json")
    rows = data if isinstance(data, list) else [data]
    unknown = sorted(set(names) - set(rows[0]))
    if unknown:
        raise Refused(f"unknown JSON field: {', '.join(unknown)} (available: {', '.join(sorted(rows[0]))})")
    picked = [{name: row[name] for name in names} for row in rows]
    out = picked if isinstance(data, list) else picked[0]
    if jq is not None:
        match = re.fullmatch(r"\.([A-Za-z]+)", jq)
        if not match or match.group(1) not in names or isinstance(out, list):
            raise Refused("only --jq .<field> of one --json field is answered here")
        value = out[match.group(1)]
        print(value if isinstance(value, str) else json.dumps(value))
        return 0
    print(json.dumps(out))
    return 0


def _log(directory: Path, words: list[str], code: int) -> None:
    """Which call, by subcommand words only (never a flag value, a title or a body), and how it ended."""
    call = " ".join(w if _WORD.match(w) else "?" for w in words[:2])
    try:
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / "calls.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"at": now(), "call": call, "exit": code}) + "\n")
    except OSError:
        pass


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    forge, code = None, 1
    try:
        try:
            forge = Forge(Path.cwd())
        except Refused:
            if argv[:1] == ["pr"] and argv[1:2] and argv[1] in ANSWERED:
                raise
        if argv[:1] != ["pr"] or not argv[1:2] or argv[1] not in ANSWERED:
            raise Refused("only pr create, pr view, pr checks and pr merge are answered here, against the local origin")
        args = _parsers()[argv[1]].parse_args(argv[2:])
        code = getattr(forge, argv[1])(args)
    except Refused as exc:
        print(f"{NAME}: refused: {exc}", file=sys.stderr)
    except (OSError, KeyError, TypeError, ValueError) as exc:  # a damaged record, an unreadable body file
        print(f"{NAME}: failed: {type(exc).__name__}: {exc}", file=sys.stderr)
    if forge is not None:
        _log(forge.dir, argv, code)
    return code


if __name__ == "__main__":
    sys.exit(main())
