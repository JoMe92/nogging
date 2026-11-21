"""``nogg-bench select``: the rank function and the ordering (small), and the draw over a
temporary bench repository with commits (medium)."""

from __future__ import annotations

import hashlib
import json
import shutil
from datetime import date
from pathlib import Path

import pytest
import yaml
from conftest import FIXTURES
from curation_fixtures import PREREG_TEXT, commit, git, make_bench, read_task

from nogg_bench import draw, selection
from nogg_bench.cli import main
from nogg_bench.validate import validate

CUTOFF = date(2026, 3, 31)  # the later of the fixture preregistration's two training cutoffs
POOL = {"schema": 1, "seed": 7, "repositories": [
    {"full_name": "octo/beta", "language": "python", "rank": 2},
    {"full_name": "octo/gamma", "language": "python", "rank": 1},
    {"full_name": "octo/ts", "language": "typescript", "rank": 1}]}


def add_tasks(bench: Path, size: str, count: int, *, start: int = 0, post_cutoff: int = 0, verified: bool = True) -> list[str]:
    """``count`` candidates of one size class as `verify` leaves them; the first ``post_cutoff`` closed after the cutoff."""
    template = yaml.safe_load((FIXTURES / "valid/tasks/fixture-task/task.yaml").read_text())
    ids = []
    for number in range(start, start + count):
        ident = f"{size}-{number:02d}"
        task_dir = bench / "tasks" / ident
        shutil.copytree(FIXTURES / "valid/tasks/fixture-task", task_dir)
        task = dict(template, id=ident, size_class=size,
                    issue_closed_at=date(2026, 5, 1) if number < post_cutoff else date(2026, 2, 1))
        task["curation"] = {"status": "candidate"}
        if verified:
            task["curation"].update(hidden_tests_verified_by="nogg-bench verify 0123abc", verified_on=date(2026, 11, 21))
        (task_dir / "task.yaml").write_text(yaml.safe_dump(task, sort_keys=False))
        ids.append(ident)
    return ids


def pooled_bench(tmp_path: Path, **sizes: int) -> Path:
    """A bench whose pool was committed after the preregistration, with verified candidates per size class."""
    bench = make_bench(tmp_path)
    (bench / "curation/pool.json").write_text(json.dumps(POOL))
    commit(bench, "pool")
    for size, count in sizes.items():
        add_tasks(bench, size, count, post_cutoff=3)
    return bench


def statuses(bench: Path) -> dict[str, tuple]:
    return {p.parent.name: (c["status"], c.get("pilot", False)) for p in sorted((bench / "tasks").glob("*/task.yaml"))
            for c in [yaml.safe_load(p.read_text())["curation"]]}


# -------------------------------------------------------------------- small


def test_the_rank_key_is_the_sha256_of_seed_and_key():
    # Computed by hand: printf '7:octo/alpha' | sha256sum, and so on.
    assert selection.rank_key(7, "octo/alpha") == "a251dbda443baaff42b923a99238b6013f5826b146a7a45e652be2c9b7817e29"
    assert selection.rank_key(7, "octo/beta") == "6c4551ef360163fd6684b07de8fcb19cce573d8b109942e8d89184d6c3664f1a"
    assert selection.rank_key(7, "octo/gamma") == "366d8bd7770139d98e93244bcfafb5e7c8a2226b3004ed883062aecbe4cd055f"
    assert selection.ranked(7, ["octo/alpha", "octo/beta", "octo/gamma"]) == ["octo/gamma", "octo/beta", "octo/alpha"]
    assert selection.rank_key(8, "octo/alpha") != selection.rank_key(7, "octo/alpha")


def test_tasks_closed_after_the_cutoff_come_first():
    def task(ident, closed):
        return {"id": ident, "issue_closed_at": closed}
    # In rank order alone: gamma, beta, alpha. The cutoff day itself is not after the cutoff.
    tasks = [task("octo/alpha", date(2026, 4, 1)), task("octo/beta", "2026-03-31"), task("octo/gamma", date(2025, 12, 1))]
    assert selection.draw_order(7, tasks, CUTOFF) == ["octo/alpha", "octo/gamma", "octo/beta"]
    tasks[1]["issue_closed_at"] = "2026-06-01T10:00:00Z"
    assert selection.draw_order(7, tasks, CUTOFF) == ["octo/beta", "octo/alpha", "octo/gamma"]


# ---------------------------------------------------------- medium: the draw


def test_the_draw_is_reproducible(tmp_path, capsys):
    bench = pooled_bench(tmp_path, small=12, medium=10, large=11)
    add_tasks(bench, "small", 1, start=12, verified=False)  # small-12 was never verified: not in the draw
    assert main(["select", "--bench-dir", str(bench)]) == 0
    assert "small: 10 accepted of 12 verified, 4 for the pilot" in capsys.readouterr().out

    record_text = (bench / "curation/selection.json").read_text()
    record = json.loads(record_text)
    assert (record["seed"], record["method"], record["latest_training_cutoff"]) == (7, "seeded-draw", "2026-03-31")
    assert record["preregistration_hash"] == git(bench, "rev-parse", "HEAD:./PREREGISTRATION.md").strip()
    assert record["pool_hash"] == hashlib.sha256((bench / "curation/pool.json").read_bytes()).hexdigest()
    assert record["repositories"] == {"python": ["octo/gamma", "octo/beta"], "typescript": ["octo/ts"]}
    assert selection.check_draw(record) == []

    small = record["tickets"]["small"]
    post = selection.ranked(7, ["small-00", "small-01", "small-02"])
    pre = selection.ranked(7, [f"small-{n:02d}" for n in range(3, 12)])
    assert [e["task"] for e in small] == post + pre  # after the cutoff first, each group by rank
    assert [e["drawn"] for e in small] == [True] * 10 + [False] * 2
    assert [e["pilot"] for e in small] == [True] * 4 + [False] * 8
    after = statuses(bench)
    assert all(after[e["task"]] == ("accepted" if e["drawn"] else "candidate", e["pilot"])
               for entries in record["tickets"].values() for e in entries)
    assert sum(s == ("accepted", True) for s in after.values()) == 12 and after["small-12"] == ("candidate", False)
    assert len(after) == 34 and "small-12" not in record_text
    assert read_task(bench, post[0])["curation"]["hidden_tests_verified_by"] == "nogg-bench verify 0123abc"
    assert validate([bench / "tasks", bench / "curation"], bench) == []

    # A second draw from the same seed and pool selects the same tickets and changes no file.
    files = {p: p.read_bytes() for p in sorted(bench.rglob("*")) if p.is_file() and ".git" not in p.parts}
    assert main(["select", "--bench-dir", str(bench)]) == 0
    assert {p: p.read_bytes() for p in files} == files and (bench / "curation/selection.json").read_text() == record_text


def test_a_short_size_class_stops_the_draw(tmp_path, capsys):
    bench = pooled_bench(tmp_path, small=10, medium=10, large=8)
    before = statuses(bench)
    assert main(["select", "--bench-dir", str(bench)]) == 1
    err = capsys.readouterr().err
    assert "large has 8" in err and "10 per size class" in err and "small has" not in err
    assert statuses(bench) == before and set(before.values()) == {("candidate", False)}
    assert not (bench / "curation/selection.json").exists()


def test_an_unverified_candidate_is_not_drawn(tmp_path):
    bench = pooled_bench(tmp_path, small=10, medium=10, large=10)
    add_tasks(bench, "small", 1, start=10, verified=False)  # an eleventh, never verified
    by_hand = read_task(bench, "small-01")
    by_hand["curation"]["hidden_tests_verified_by"] = "product-owner"  # not verify's mark
    (bench / "tasks/small-01/task.yaml").write_text(yaml.safe_dump(by_hand, sort_keys=False))
    with pytest.raises(draw.CurationError, match="small has 9"):
        draw.select(bench)


def test_the_seed_was_fixed_before_the_pool(tmp_path, capsys):
    bench = pooled_bench(tmp_path, small=10, medium=10, large=10)
    first = git(bench, "rev-list", "--max-parents=0", "HEAD").strip()
    pool = git(bench, "rev-parse", "HEAD").strip()
    # An edit outside the selection block does not move the block's commit.
    (bench / "PREREGISTRATION.md").write_text(PREREG_TEXT + "\nA clarification.\n")
    commit(bench, "a clarification")
    assert draw.selection_commit(bench) == first
    assert main(["select", "--bench-dir", str(bench)]) == 0
    capsys.readouterr()

    # A seed committed after the pool: the draw refuses and names both commits.
    (bench / "PREREGISTRATION.md").write_text(PREREG_TEXT.replace("seed: 7", "seed: 8"))
    late = commit(bench, "another seed")
    before = (bench / "curation/selection.json").read_text(), statuses(bench)
    assert main(["select", "--bench-dir", str(bench)]) == 1
    err = capsys.readouterr().err
    assert late in err and pool in err and "not an ancestor" in err
    assert ((bench / "curation/selection.json").read_text(), statuses(bench)) == before


def test_the_pool_must_be_committed(tmp_path, capsys):
    bench = make_bench(tmp_path)
    (bench / "curation/pool.json").write_text(json.dumps(POOL))
    assert main(["select", "--bench-dir", str(bench)]) == 1
    assert "curation/pool.json is not committed" in capsys.readouterr().err


# ----------------------------------------- validate: only the draw accepts


def test_nobody_accepts_a_ticket_by_hand(tmp_path):
    bench = pooled_bench(tmp_path, small=11, medium=10, large=10)
    record = draw.select(bench)
    assert validate([bench / "tasks"], bench) == []
    left_out = record["tickets"]["small"][-1]["task"]
    path = bench / "tasks" / left_out / "task.yaml"
    task = read_task(bench, left_out)
    task["curation"]["status"] = "accepted"  # by hand: selection.json does not list it as drawn
    path.write_text(yaml.safe_dump(task, sort_keys=False))
    (problem,) = validate([bench / "tasks"], bench)
    assert (Path(problem.file), problem.field) == (path, "curation.status")
    assert f"task {left_out} is accepted" in problem.message and "curation/selection.json" in problem.message

    # Nor does anybody name a pilot ticket by hand.
    task["curation"]["status"] = "candidate"
    path.write_text(yaml.safe_dump(task, sort_keys=False))
    drawn = bench / "tasks" / record["tickets"]["small"][5]["task"] / "task.yaml"  # accepted, not for the pilot
    drawn.write_text(drawn.read_text().replace("status: accepted", "status: accepted\n  pilot: true"))
    (problem,) = validate([bench / "tasks"], bench)
    assert (Path(problem.file), problem.field) == (drawn, "curation.pilot")


def test_a_draw_record_out_of_order_is_refused():
    problems = selection.check_draw(json.loads((FIXTURES / "invalid/curation/selection.json").read_text()))
    assert [p.field for p in problems] == ["pool_hash", "tickets"]
    record = json.loads((FIXTURES / "valid/curation/selection.json").read_text())
    record["tickets"]["small"] = [dict(record["tickets"]["small"][0], task=t) for t in selection.ranked(7, ["a", "b"])[::-1]]
    assert [p.field for p in selection.check_draw(record)] == ["tickets.small"]
