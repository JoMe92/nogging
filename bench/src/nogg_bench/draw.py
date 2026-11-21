"""``nogg-bench select``: the seeded draw of the benchmark tickets (design Decision 19).

The draw is a pure function of the preregistered seed and the committed pool:
per size class the verified candidates closed after the arm models' latest
training cutoff come first, then the others, each group ordered by the
SHA-256 of ``"<seed>:<task id>"``. The first ``per_size_class`` become
``accepted`` and the first ``pilot_per_size_class`` of those ``pilot: true``;
``curation/selection.json`` records the seed, the preregistration blob hash,
the pool hash and the ranked lists. Running it again changes nothing.

``select`` refuses, before it changes any file, when a size class is short
and when the commit that introduced the selection block is not an ancestor of
the commit that first added the pool: a seed chosen after the pool is known
could have been chosen for its outcome. (This module is not ``select.py``
because that name would shadow the standard library's for scripts run from
this directory.)
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import sys
from pathlib import Path

import yaml

from nogg_bench import prereg, selection
from nogg_bench.candidates import POOL, CurationError
from nogg_bench.records import RecordError, load_yaml
from nogg_bench.schema import SIZE_CLASSES, check_task
from nogg_bench.selection import DRAW_FILE, METHOD, SelectionError
from nogg_bench.validate import find_bench_dir
from nogg_bench.verify import verified


def _git(bench: Path, *args: str) -> str:
    done = prereg._git(bench, *args)
    return done.stdout if done.returncode == 0 else ""


def selection_commit(bench: Path) -> str | None:
    """The commit since which the preregistration's selection block reads as it does now."""
    current = selection.selection_block((bench / prereg.PREREGISTRATION).read_text(encoding="utf-8"))
    introduced = None
    for sha in _git(bench, "log", "--format=%H", "--", prereg.PREREGISTRATION).split():
        done = prereg._git(bench, "show", f"{sha}:./{prereg.PREREGISTRATION}")
        if done.returncode != 0 or selection.selection_block(done.stdout) != current:
            break
        introduced = sha
    return introduced


def seed_before_pool(bench: Path) -> None:
    """Refuse unless the selection block's commit is a proper ancestor of the pool's first commit."""
    added = _git(bench, "log", "--diff-filter=A", "--format=%H", "--", POOL).split()
    if not added or _git(bench, "status", "--porcelain", "--", POOL).strip():
        raise CurationError(f"{POOL} is not committed, or has uncommitted changes")
    pool, seed = added[-1], selection_commit(bench)
    ancestor = seed is not None and seed != pool and prereg._git(
        bench, "merge-base", "--is-ancestor", seed, pool).returncode == 0
    if not ancestor:
        raise CurationError(
            f"the selection block was committed in {seed}, which is not an ancestor of {pool}, the commit that "
            f"first added {POOL}; the seed must be fixed before the pool exists")


def select(bench: Path) -> dict:
    """Draw the tickets, write the statuses and ``selection.json``; returns that record."""
    sel, blob = selection.committed_selection(bench)
    seed_before_pool(bench)
    pool_bytes = (bench / POOL).read_bytes()
    tasks: dict[str, tuple[Path, dict]] = {}
    for path in sorted((bench / "tasks").glob("*/task.yaml")):
        data = load_yaml(path)
        problems = check_task(data, dir_name=path.parent.name)
        if problems:
            raise RecordError(problems[0].at(str(path)))
        if data["curation"]["status"] in ("candidate", "accepted") and verified(data):
            tasks[data["id"]] = (path, data)

    tickets: dict[str, list[dict]] = {}
    for size in SIZE_CLASSES:
        mine = [data for _, data in tasks.values() if data["size_class"] == size]
        tickets[size] = [
            {"task": ident, "rank_key": selection.rank_key(sel.seed, ident),
             "post_cutoff": selection.closed_after(tasks[ident][1], sel.latest_cutoff),
             "drawn": place < sel.per_size_class, "pilot": place < sel.pilot_per_size_class}
            for place, ident in enumerate(selection.draw_order(sel.seed, mine, sel.latest_cutoff))
        ]
    short = [f"{size} has {len(entries)}" for size, entries in tickets.items() if len(entries) < sel.per_size_class]
    if short:
        raise CurationError(f"too few verified candidates, {sel.per_size_class} per size class are needed: "
                            + ", ".join(short) + "; no task was changed")

    repositories: dict[str, list[str]] = {}
    for repo in sorted(json.loads(pool_bytes)["repositories"], key=lambda r: r["rank"]):
        repositories.setdefault(repo["language"], []).append(repo["full_name"])
    record = {"schema": 1, "method": METHOD, "seed": sel.seed, "preregistration_hash": blob,
              "pool_hash": hashlib.sha256(pool_bytes).hexdigest(),
              "latest_training_cutoff": sel.latest_cutoff.isoformat(),
              "repositories": repositories, "tickets": tickets}
    for entry in (e for entries in tickets.values() for e in entries):
        path, data = tasks[entry["task"]]
        new = copy.deepcopy(data)
        new["curation"].pop("pilot", None)
        new["curation"]["status"] = "accepted" if entry["drawn"] else "candidate"
        if entry["pilot"]:
            new["curation"]["pilot"] = True
        if new != data:
            path.write_text(yaml.safe_dump(new, sort_keys=False), encoding="utf-8")
    (bench / DRAW_FILE).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return record


def add_parser(sub) -> None:
    parser = sub.add_parser(
        "select", help="draw the benchmark and pilot tickets from the verified candidates",
        description="The seeded draw (design Decision 19): writes the statuses and curation/selection.json.",
    )
    parser.add_argument("--bench-dir", help="the bench directory (default: found from the working directory)")
    parser.set_defaults(handler=command)


def command(args: argparse.Namespace) -> int:
    bench = Path(args.bench_dir).resolve() if args.bench_dir else find_bench_dir()
    try:
        record = select(bench)
    except (CurationError, SelectionError) as exc:
        print(f"nogg-bench select: {exc}", file=sys.stderr)
        return 1
    except RecordError as exc:
        print(f"nogg-bench select: {exc.problem}", file=sys.stderr)
        return 1
    for size, entries in record["tickets"].items():
        drawn = [e for e in entries if e["drawn"]]
        print(f"select: {size}: {len(drawn)} accepted of {len(entries)} verified, "
              f"{sum(e['pilot'] for e in drawn)} for the pilot")
    return 0
