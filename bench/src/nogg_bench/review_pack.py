"""``nogg-bench review-pack``: a blinded review pack, and the import of its sheet.

Build (design Decision 13)::

    nogg-bench review-pack --batch <batch> --out <dir> [--key <file>]

writes, for the completed runs of the batch, one item per run under a random
label, in random order: the task's issue text and the anonymised diff
(:mod:`nogg_bench.blind`). The pack holds ``items/<label>.md`` and
``record-sheet.csv`` and nothing that names a run, an arm or a task. The key
from label to run ID goes outside the pack directory (``<dir>.key.json`` unless
``--key`` says otherwise). Import::

    nogg-bench review-pack --import <sheet> --key <key>

validates the filled sheet against the key and appends review records to
``results/review/<pack>.jsonl``.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import random
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

from nogg_bench.blind import anonymise, surviving_markers
from nogg_bench.records import RecordError, load_yaml, read_jsonl
from nogg_bench.schema import (
    DEFECT_SEVERITIES,
    MERGE_DECISIONS,
    check_result,
    check_review,
)
from nogg_bench.validate import find_bench_dir

SHEET_COLUMNS = ("item", "merge_decision", *DEFECT_SEVERITIES, "review_minutes", "comment")
LABEL_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"  # no characters that read alike
LABEL_LENGTH = 4


class PackError(Exception):
    """The pack or the import cannot be done; the message says why."""


# ------------------------------------------------------------------ building

def new_labels(count: int, rng: random.Random) -> list[str]:
    """``count`` distinct random labels. Nothing about a run goes into a label."""
    labels: list[str] = []
    seen: set[str] = set()
    while len(labels) < count:
        label = "".join(rng.choice(LABEL_ALPHABET) for _ in range(LABEL_LENGTH))
        if label not in seen:
            seen.add(label)
            labels.append(label)
    return labels


def _completed_runs(bench: Path, batch: str) -> tuple[list[dict], int]:
    path = bench / "results" / f"{batch}.jsonl"
    if not path.is_file():
        raise PackError(f"{path}: no such batch")
    runs: list[dict] = []
    skipped = 0
    seen: set[str] = set()
    try:
        for number, record in read_jsonl(path):
            problems = check_result(record)
            if problems:
                p = problems[0]
                raise PackError(f"{path}:{number}: {p.field}: {p.message}")
            if record["run_id"] in seen:
                raise PackError(f"{path}:{number}: run_id: {record['run_id']} appears twice")
            seen.add(record["run_id"])
            if record["status"] == "completed":
                runs.append(record)
            else:
                skipped += 1
    except RecordError as exc:
        raise PackError(str(exc.problem)) from exc
    if not runs:
        raise PackError(f"{path}: no completed run to review")
    return runs, skipped


def _issue_text(bench: Path, task_id: str) -> str:
    for base in (bench / "tasks", bench / "examples" / "tasks"):
        task_yaml = base / task_id / "task.yaml"
        if task_yaml.is_file():
            try:
                task = load_yaml(task_yaml)
                issue = task_yaml.parent / task["issue"]
                return issue.read_text(encoding="utf-8").rstrip("\n")
            except (RecordError, OSError, KeyError, TypeError) as exc:
                raise PackError(f"{task_yaml}: the issue text cannot be read") from exc
    raise PackError(f"task {task_id}: no task.yaml under {bench / 'tasks'}")


def _diff_text(runs_root: Path, run: dict) -> str:
    path = runs_root / run["diff_path"]
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PackError(f"run {run['run_id']}: cannot read diff {path}: {exc.strerror}") from exc


def _fence(text: str) -> str:
    longest = 0
    run = 0
    for ch in text:
        run = run + 1 if ch == "`" else 0
        longest = max(longest, run)
    return "`" * max(3, longest + 1)


def render_item(label: str, issue: str, diff: str) -> str:
    fence = _fence(issue + diff)
    return (
        f"# Item {label}\n\n"
        "## Issue\n\n"
        f"{issue}\n\n"
        "## Diff\n\n"
        f"{fence}diff\n{diff}{fence}\n"
    )


def _sheet_text(labels: Iterable[str]) -> str:
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(SHEET_COLUMNS)
    for label in labels:
        writer.writerow([label, "", "", "", "", "", ""])
    return buffer.getvalue()


def _inside(path: Path, directory: Path) -> bool:
    try:
        path.resolve().relative_to(directory.resolve())
    except ValueError:
        return False
    return True


def build_pack(
    bench: Path,
    batch: str,
    out: Path,
    key_path: Path | None = None,
    runs_root: Path | None = None,
    rng: random.Random | None = None,
) -> tuple[Path, int]:
    """Write the pack and its key. Returns ``(key path, item count)``.

    Everything is checked before anything is written: a run whose diff still
    holds a marker after anonymisation stops the whole pack and is named.
    """
    rng = rng or random.SystemRandom()
    runs_root = runs_root or bench
    key_path = key_path or out.parent / f"{out.name}.key.json"
    if _inside(key_path, out):
        raise PackError(f"the key {key_path} must be outside the pack directory {out}")
    if out.exists() and any(out.iterdir()):
        raise PackError(f"{out}: the pack directory exists and is not empty")
    if key_path.exists():
        raise PackError(f"{key_path}: the key file exists; a new pack needs a new key")

    runs, _skipped = _completed_runs(bench, batch)
    runs.sort(key=lambda r: r["run_id"])  # so the shuffle below is the only source of order
    rendered: dict[str, str] = {}
    leaks: list[str] = []
    for run in runs:
        clean = anonymise(_diff_text(runs_root, run))
        markers = surviving_markers(clean, run["run_id"])
        if markers:
            leaks.append(f"run {run['run_id']}: a marker survives anonymisation ({markers[0]})")
            continue
        rendered[run["run_id"]] = clean
    if leaks:
        raise PackError("; ".join(leaks) + "; no pack written")

    order = [r["run_id"] for r in runs]
    rng.shuffle(order)
    labels = new_labels(len(order), rng)
    by_id = {r["run_id"]: r for r in runs}
    issues = {task: _issue_text(bench, task) for task in {r["task"] for r in runs}}

    items = {}
    for label, run_id in zip(labels, order):
        item = render_item(label, issues[by_id[run_id]["task"]], rendered[run_id])
        items[label] = (run_id, item)
    # the issue text is the same for every arm, but the run ID must not be in it either
    for label, (run_id, item) in items.items():
        if run_id in item:
            raise PackError(f"run {run_id}: its run ID appears in the item text; no pack written")

    (out / "items").mkdir(parents=True, exist_ok=True)
    for label, (_run_id, item) in items.items():
        (out / "items" / f"{label}.md").write_text(item, encoding="utf-8")
    (out / "record-sheet.csv").write_text(_sheet_text(labels), encoding="utf-8")
    key = {
        "schema": 1,
        "pack": out.name,
        "batch": batch,
        "items": {label: run_id for label, (run_id, _item) in items.items()},
    }
    key_path.parent.mkdir(parents=True, exist_ok=True)
    key_path.write_text(json.dumps(key, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return key_path, len(items)


# ----------------------------------------------------------------- importing

def _load_key(key_path: Path) -> dict:
    try:
        key = json.loads(key_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise PackError(f"{key_path}: cannot read the key: {exc.strerror}") from exc
    except json.JSONDecodeError as exc:
        raise PackError(f"{key_path}: the key is not valid JSON: {exc.msg}") from exc
    if (
        not isinstance(key, dict)
        or key.get("schema") != 1
        or not isinstance(key.get("pack"), str)
        or not isinstance(key.get("items"), dict)
    ):
        raise PackError(f"{key_path}: not a review-pack key")
    return key


def _whole_number(text: str) -> int | None:
    text = text.strip()
    return int(text) if text.isdigit() else None


def _parse_rows(sheet: Path, key: dict, reviewed_at: str) -> list[dict]:
    try:
        text = sheet.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise PackError(f"{sheet}: cannot read the sheet: {exc.strerror}") from exc
    reader = csv.reader(io.StringIO(text))
    rows = list(reader)
    if not rows or tuple(c.strip() for c in rows[0]) != SHEET_COLUMNS:
        raise PackError(f"{sheet}: the header must be exactly {','.join(SHEET_COLUMNS)}")

    problems: list[str] = []
    records: list[dict] = []
    seen: set[str] = set()
    for number, row in enumerate(rows[1:], start=2):
        if not any(cell.strip() for cell in row):
            continue
        if len(row) != len(SHEET_COLUMNS):
            problems.append(f"{sheet}:{number}: expected {len(SHEET_COLUMNS)} columns, found {len(row)}")
            continue
        cells = dict(zip(SHEET_COLUMNS, row))
        label = cells["item"].strip()
        where = f"{sheet}:{number} (item {label or '?'})"
        if label not in key["items"]:
            problems.append(f"{where}: item: {label!r} is not in the key")
            continue
        if label in seen:
            problems.append(f"{where}: item: listed twice")
            continue
        seen.add(label)
        decision = cells["merge_decision"].strip()
        if decision not in MERGE_DECISIONS:
            problems.append(
                f"{where}: merge_decision: {decision!r} is not one of {', '.join(MERGE_DECISIONS)}"
            )
        defects: dict[str, int] = {}
        for severity in DEFECT_SEVERITIES:
            value = _whole_number(cells[severity])
            if value is None:
                problems.append(f"{where}: {severity}: {cells[severity]!r} is not a whole number of defects")
            else:
                defects[severity] = value
        try:
            minutes = float(cells["review_minutes"])
        except ValueError:
            minutes = 0.0
        if not minutes > 0:
            problems.append(f"{where}: review_minutes: {cells['review_minutes']!r} must be a number above zero")
        if len(defects) == len(DEFECT_SEVERITIES) and decision in MERGE_DECISIONS and minutes > 0:
            records.append(
                {
                    "schema": 1,
                    "pack": key["pack"],
                    "item": label,
                    "run_id": key["items"][label],
                    "merge_decision": decision,
                    "defects": defects,
                    "review_minutes": minutes,
                    "comment": cells["comment"].strip(),
                    "reviewed_at": reviewed_at,
                }
            )
    missing = sorted(set(key["items"]) - seen)
    if missing:
        problems.append(f"{sheet}: items missing from the sheet: {', '.join(missing)}")
    if not problems:
        for record in records:
            for problem in check_review(record):
                problems.append(f"{sheet}: item {record['item']}: {problem.field}: {problem.message}")
    if problems:
        raise PackError("\n".join(problems))
    return records


def import_sheet(
    bench: Path,
    sheet: Path,
    key_path: Path,
    now: Callable[[], datetime] | None = None,
) -> tuple[Path, int]:
    """Validate the filled sheet against the key and append the review records.

    Nothing is appended unless every row is valid and every item of the key has
    a row. Returns ``(review file, record count)``.
    """
    key = _load_key(key_path)
    stamp = (now or (lambda: datetime.now(timezone.utc)))().strftime("%Y-%m-%dT%H:%M:%SZ")
    records = _parse_rows(sheet, key, stamp)
    target = bench / "results" / "review" / f"{key['pack']}.jsonl"
    if target.exists():
        try:
            already = {rec.get("item") for _n, rec in read_jsonl(target) if isinstance(rec, dict)}
        except RecordError as exc:
            raise PackError(str(exc.problem)) from exc
        done = sorted(already & {r["item"] for r in records})
        if done:
            raise PackError(f"{target}: already holds records for items {', '.join(done)}; not imported twice")
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = "".join(json.dumps(r, sort_keys=True) + "\n" for r in records)
    with target.open("a", encoding="utf-8") as handle:
        handle.write(payload)
    return target, len(records)


# ------------------------------------------------------------------- command

def _command(args: argparse.Namespace) -> int:
    bench = Path(args.bench_dir).resolve() if args.bench_dir else find_bench_dir()
    try:
        if args.import_sheet:
            if not args.key:
                raise PackError("--import needs --key <key>")
            if args.batch or args.out:
                raise PackError("--import does not take --batch or --out")
            target, count = import_sheet(bench, Path(args.import_sheet), Path(args.key))
            print(f"imported {count} review record(s) into {target}")
            return 0
        if not args.batch or not args.out:
            raise PackError("building a pack needs --batch <batch> and --out <dir>")
        runs_root = Path(args.runs_root).resolve() if args.runs_root else None
        key_path, count = build_pack(
            bench,
            args.batch,
            Path(args.out),
            Path(args.key) if args.key else None,
            runs_root,
        )
        print(f"wrote {count} item(s) to {args.out}; key: {key_path} (keep it away from the reviewer)")
        return 0
    except PackError as exc:
        print(f"review-pack: {exc}", file=sys.stderr)
        return 1


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser(
        "review-pack",
        help="write a blinded review pack for a batch, or import the filled record sheet",
        description=(
            "Build a blinded review pack from the completed runs of a batch "
            "(--batch, --out), or import a filled sheet (--import, --key)."
        ),
    )
    parser.add_argument("--batch", help="the batch whose completed runs are reviewed")
    parser.add_argument("--out", help="the pack directory to write (must be new or empty)")
    parser.add_argument("--key", help="the key file: written outside the pack on build, read on --import")
    parser.add_argument("--import", dest="import_sheet", metavar="SHEET", help="import this filled record sheet")
    parser.add_argument("--runs-root", help="directory the results' diff_path is relative to (default: the bench directory)")
    parser.add_argument("--bench-dir", help="the bench directory (default: found from the working directory)")
    parser.set_defaults(handler=_command)
