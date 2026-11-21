"""The blinded review pack: anonymisation, the pack and its key, the sheet import."""

from __future__ import annotations

import csv
import json
import random
import shutil
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import pytest
from conftest import FIXTURES

from nogg_bench.blind import anonymise, is_artefact_path, surviving_markers
from nogg_bench.cli import main
from nogg_bench.review_pack import (
    SHEET_COLUMNS,
    PackError,
    build_pack,
    import_sheet,
    new_labels,
)
from nogg_bench.validate import validate

# ---------------------------------------------------------------- the diffs

SOURCE = """\
diff --git a/src/miniutil/text.py b/src/miniutil/text.py
index 1111111..2222222 100644
--- a/src/miniutil/text.py
+++ b/src/miniutil/text.py
@@ -1,3 +1,4 @@
 def slugify(value):
-    return value.lower()
+    return "-".join(value.lower().split())
"""


def section(path: str, body: str = "+x") -> str:
    return (
        f"diff --git a/{path} b/{path}\nnew file mode 100644\nindex 0000000..3333333\n"
        f"--- /dev/null\n+++ b/{path}\n@@ -0,0 +1 @@\n{body}\n"
    )


COMMIT_TEXT = """\
From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001
From: Nogging Lead <lead@nogging.bot>
Date: Fri, 20 Nov 2026 10:05:00 +0000
Subject: [PATCH] fix(text): collapse separators [SPEC-hio1]

Collapse runs of dashes. Closes SPEC-hio1.

Nogging-Writer: lead-agent
Co-authored-by: Nogging Backend Engineer <backend-engineer@nogging.bot>
---
 src/miniutil/text.py | 2 +-
 openspec/changes/x/tasks.md | 4 ++++
 2 files changed, 5 insertions(+), 1 deletion(-)

"""


# ----------------------------------------------- small: anonymisation per kind


@pytest.mark.parametrize(
    "path",
    [
        "openspec/changes/x/tasks.md",
        ".beads/issues.jsonl",
        ".nogging/config.json",
        ".claude/agents/architect.md",
        ".codex/config.toml",
        ".pi/settings.json",
        ".agents/skills/x/SKILL.md",
        "AGENTS.md",
        "CLAUDE.md",
        "docs/AGENTS.md",
    ],
)
def test_an_artefact_path_section_is_removed(path):
    assert is_artefact_path(path)
    out = anonymise(SOURCE + section(path))
    assert out == SOURCE
    assert surviving_markers(out) == []


@pytest.mark.parametrize("path", ["src/openspec_utils.py", "docs/openspec/intro.md", "README.md", "src/.claude.py"])
def test_an_ordinary_path_is_kept(path):
    assert not is_artefact_path(path)
    assert anonymise(section(path)) == section(path)


def test_the_source_diff_is_kept_byte_for_byte():
    assert anonymise(SOURCE) == SOURCE


def test_a_rename_out_of_an_artefact_path_is_removed():
    renamed = (
        "diff --git a/openspec/old.md b/docs/new.md\nsimilarity index 100%\n"
        "rename from openspec/old.md\nrename to docs/new.md\n"
    )
    assert anonymise(SOURCE + renamed) == SOURCE


def test_commit_text_loses_tokens_trailers_and_authorship():
    out = anonymise(COMMIT_TEXT + SOURCE)
    assert "Nogging-Writer" not in out
    assert "Co-authored-by" not in out
    assert "SPEC-hio1" not in out
    assert "nogging.bot" not in out
    assert "openspec" not in out
    assert "Date:" not in out
    assert "Subject: [PATCH] fix(text): collapse separators" in out
    assert "Collapse runs of dashes. Closes" in out
    assert out.endswith(SOURCE)
    assert surviving_markers(out) == []


def test_a_format_patch_series_is_cleaned_commit_by_commit():
    second = COMMIT_TEXT.replace("0123456789abcdef", "fedcba9876543210")
    out = anonymise(COMMIT_TEXT + SOURCE + second + section("openspec/x.md"))
    assert "Nogging-Writer" not in out
    assert out.count("Subject: [PATCH]") == 2
    assert "openspec" not in out
    assert out.count("diff --git") == 1


def test_a_task_id_in_brackets_is_removed_from_commit_text_too():
    out = anonymise("Subject: [PATCH] feat: x [TASK-BEN-004]\n\n" + SOURCE)
    assert "BEN-004" not in out


# ----------------------------- small: a marker survives anonymisation


@pytest.mark.parametrize(
    "line, what",
    [
        ("+# see SPEC-abc1 for details", "Bead token"),
        ("+# [SPEC-abc1]", "Bead token"),
        ("+Nogging-Writer: lead", "trailer"),
        ("+Co-authored-by: A <a@b.c>", "trailer"),
        ("+docs live in openspec/changes/x", "artefact path"),
        ("+see AGENTS.md", "artefact path"),
        ("+store in .beads/x", "artefact path"),
    ],
)
def test_a_marker_in_the_content_survives_anonymisation_and_is_found(line, what):
    out = anonymise(SOURCE + f"{line}\n")
    found = surviving_markers(out)
    assert found and what in found[0]


def test_the_run_id_counts_as_a_marker():
    assert surviving_markers("+value = 'fixture-batch-a-fixture-task-1'\n", "fixture-batch-a-fixture-task-1") == [
        "the run ID"
    ]


@pytest.mark.parametrize("text", ["+UTF-8 and SHA-256 and ISO-8601\n", "+[PATCH 1/2] [RFC-2119]\n", "+openspecs/ is a word\n"])
def test_ordinary_text_is_not_a_marker(text):
    assert surviving_markers(text) == []


# ------------------------------------- small: label randomness vs arm order


def test_labels_are_distinct_and_come_from_the_random_source_alone():
    labels = new_labels(200, random.Random(7))
    assert len(set(labels)) == 200
    assert labels == new_labels(200, random.Random(7))
    assert labels != new_labels(200, random.Random(8))


def test_item_order_does_not_follow_the_arm_order(tmp_path):
    """Over many fixed random sources the first item is an arm-A run about as often as an arm-C run,
    and the order for one source does not depend on the order the runs came in."""
    bench = make_bench(tmp_path)
    first_arms = Counter()
    for seed in range(120):
        out = tmp_path / f"pack{seed}"
        key_path, _ = build_pack(bench, "fixture-batch", out, rng=random.Random(seed))
        key = json.loads(key_path.read_text())
        first_label = next(csv.DictReader((out / "record-sheet.csv").open()))["item"]
        first_arms[arm_of(key["items"][first_label])] += 1
    assert 36 <= first_arms["A"] <= 84 and first_arms["A"] + first_arms["C"] == 120


def test_the_same_source_gives_the_same_pack_whatever_order_the_lines_come_in(tmp_path):
    bench = make_bench(tmp_path)
    key_one, _ = build_pack(bench, "fixture-batch", tmp_path / "one", rng=random.Random(3))
    results = bench / "results" / "fixture-batch.jsonl"
    lines = results.read_text().splitlines()
    results.write_text("\n".join(reversed(lines)) + "\n")
    key_two, _ = build_pack(bench, "fixture-batch", tmp_path / "two", rng=random.Random(3))
    assert json.loads(key_one.read_text())["items"] == json.loads(key_two.read_text())["items"]


# ------------------------------------------------ medium: a temporary bench


def arm_of(run_id: str) -> str:
    return "A" if "-a-" in run_id else "C"


def make_bench(tmp_path: Path, diffs: dict[str, str] | None = None) -> Path:
    """A bench directory with the fixture task and the completed arm A and arm C result lines."""
    bench = tmp_path / "bench"
    shutil.copytree(FIXTURES / "valid" / "tasks", bench / "tasks")
    shutil.copytree(FIXTURES / "valid" / "curation", bench / "curation")  # the draw that accepted the task
    (bench / "results").mkdir()
    source = (FIXTURES / "valid" / "results" / "fixture-batch.jsonl").read_text().splitlines()
    kept = [json.loads(line) for line in source]
    kept = [r for r in kept if r["status"] == "completed"]
    assert {r["arm"] for r in kept} == {"A", "C"}
    (bench / "results" / "fixture-batch.jsonl").write_text("".join(json.dumps(r) + "\n" for r in kept))
    for run in kept:
        diff = (diffs or {}).get(run["arm"]) or (
            (COMMIT_TEXT + SOURCE + section("openspec/changes/x/tasks.md") + section(".beads/issues.jsonl"))
            if run["arm"] == "C"
            else SOURCE
        )
        target = bench / run["diff_path"]
        target.parent.mkdir(parents=True)
        target.write_text(diff)
    return bench


def pack_items(out: Path) -> dict[str, str]:
    return {p.stem: p.read_text() for p in sorted((out / "items").glob("*.md"))}


def test_the_pack_does_not_reveal_the_arm(tmp_path):
    bench = make_bench(tmp_path)
    out = tmp_path / "pack"
    key_path, count = build_pack(bench, "fixture-batch", out, rng=random.Random(1))
    assert count == 2
    items = pack_items(out)
    assert len(items) == 2
    for label, text in items.items():
        assert f"# Item {label}" in text
        assert "slugify leaves runs of dashes" in text  # the issue text
        assert "def slugify" in text  # the diff
        assert surviving_markers(text) == []
        for secret in ("openspec/", "SPEC-", "Nogging-Writer", "Co-authored-by", "fixture-batch", "nogging.bot"):
            assert secret not in text
    everything = "\n".join(p.read_text() for p in out.rglob("*") if p.is_file())
    assert "fixture-batch" not in everything
    assert "fixture-task" not in everything
    assert sorted(p.name for p in out.iterdir()) == ["items", "record-sheet.csv"]
    key = json.loads(key_path.read_text())
    assert not key_path.resolve().is_relative_to(out.resolve())
    assert key_path == tmp_path / "pack.key.json"
    assert sorted(key["items"]) == sorted(items)
    assert {arm_of(r) for r in key["items"].values()} == {"A", "C"}


def test_the_key_must_be_outside_the_pack(tmp_path):
    bench = make_bench(tmp_path)
    out = tmp_path / "pack"
    with pytest.raises(PackError, match="outside the pack directory"):
        build_pack(bench, "fixture-batch", out, key_path=out / "key.json")
    assert not out.exists()


def test_a_marker_that_survives_refuses_the_pack_and_names_the_run(tmp_path):
    bench = make_bench(tmp_path, diffs={"C": SOURCE + "+# SPEC-hio1 was here\n"})
    out = tmp_path / "pack"
    with pytest.raises(PackError, match=r"run fixture-batch-c-fixture-task-1: a marker survives anonymisation"):
        build_pack(bench, "fixture-batch", out)
    assert not out.exists()
    assert not (tmp_path / "pack.key.json").exists()


def test_the_cli_refuses_with_a_message_and_a_failing_exit_code(tmp_path, capsys):
    bench = make_bench(tmp_path, diffs={"A": SOURCE + "+see openspec/x\n"})
    code = main(["review-pack", "--bench-dir", str(bench), "--batch", "fixture-batch", "--out", str(tmp_path / "p")])
    assert code == 1
    assert "fixture-batch-a-fixture-task-1" in capsys.readouterr().err


def test_only_completed_runs_are_packed(tmp_path):
    bench = make_bench(tmp_path)
    results = bench / "results" / "fixture-batch.jsonl"
    full = (FIXTURES / "valid" / "results" / "fixture-batch.jsonl").read_text()
    results.write_text(full)  # holds a timeout and an infra_error line as well
    for line in map(json.loads, full.splitlines()):
        if line["diff_path"]:
            target = bench / line["diff_path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(SOURCE)
    _key, count = build_pack(bench, "fixture-batch", tmp_path / "pack", rng=random.Random(2))
    assert count == 2


def test_a_batch_that_does_not_exist_or_is_empty_is_refused(tmp_path):
    bench = make_bench(tmp_path)
    with pytest.raises(PackError, match="no such batch"):
        build_pack(bench, "missing", tmp_path / "pack")


def test_an_invalid_result_line_is_refused(tmp_path):
    bench = make_bench(tmp_path)
    results = bench / "results" / "fixture-batch.jsonl"
    record = json.loads(results.read_text().splitlines()[0])
    record["status"] = "mystery"
    results.write_text(json.dumps(record) + "\n")
    with pytest.raises(PackError, match=r"fixture-batch.jsonl:1: status"):
        build_pack(bench, "fixture-batch", tmp_path / "pack")


def test_a_pack_directory_with_content_is_not_overwritten(tmp_path):
    bench = make_bench(tmp_path)
    out = tmp_path / "pack"
    out.mkdir()
    (out / "keep.txt").write_text("x")
    with pytest.raises(PackError, match="not empty"):
        build_pack(bench, "fixture-batch", out)
    assert (out / "keep.txt").read_text() == "x"


def test_the_cli_builds_a_pack(tmp_path, capsys):
    bench = make_bench(tmp_path)
    out = tmp_path / "cli-pack"
    assert main(["review-pack", "--bench-dir", str(bench), "--batch", "fixture-batch", "--out", str(out)]) == 0
    assert "wrote 2 item(s)" in capsys.readouterr().out
    assert (tmp_path / "cli-pack.key.json").is_file()


# ----------------------------------------------- medium: the filled sheet


NOW = lambda: datetime(2026, 11, 21, 9, 30, tzinfo=timezone.utc)  # noqa: E731


def fill(out: Path, rows: list[dict]) -> Path:
    """Write the reviewer's sheet: row ``i`` of ``rows`` fills the ``i``th row of the blank sheet."""
    sheet = out / "record-sheet.csv"
    blank = list(csv.DictReader(sheet.open()))
    filled = out.parent / f"{out.name}-filled.csv"
    with filled.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=SHEET_COLUMNS)
        writer.writeheader()
        for base, extra in zip(blank, rows):
            writer.writerow({**base, **extra})
    return filled


GOOD = [
    {"merge_decision": "merge", "critical": 0, "major": 0, "minor": 1, "review_minutes": 6.5, "comment": "Clean."},
    {
        "merge_decision": "merge-after-changes",
        "critical": 0,
        "major": 1,
        "minor": 2,
        "review_minutes": 11,
        "comment": "Needs a test, with a comma, and a quote \"",
    },
]


def built(tmp_path: Path):
    bench = make_bench(tmp_path)
    out = tmp_path / "pack"
    key_path, _ = build_pack(bench, "fixture-batch", out, rng=random.Random(5))
    return bench, out, key_path


def test_the_blank_sheet_has_one_row_per_item_and_the_documented_columns(tmp_path):
    _bench, out, _key = built(tmp_path)
    rows = list(csv.DictReader((out / "record-sheet.csv").open()))
    assert tuple(rows[0]) == SHEET_COLUMNS
    assert sorted(r["item"] for r in rows) == sorted(pack_items(out))
    assert all(r["merge_decision"] == "" for r in rows)


def test_a_filled_sheet_is_imported_as_review_records_that_validate_accepts(tmp_path):
    bench, out, key_path = built(tmp_path)
    sheet = fill(out, GOOD)
    target, count = import_sheet(bench, sheet, key_path, now=NOW)
    assert (target, count) == (bench / "results" / "review" / "pack.jsonl", 2)
    records = [json.loads(line) for line in target.read_text().splitlines()]
    key = json.loads(key_path.read_text())["items"]
    assert {r["item"]: r["run_id"] for r in records} == key
    assert {r["pack"] for r in records} == {"pack"}
    assert records[0]["reviewed_at"] == "2026-11-21T09:30:00Z"
    assert sorted(r["merge_decision"] for r in records) == ["merge", "merge-after-changes"]
    assert any(r["comment"].endswith('a quote "') for r in records)
    assert records[0]["defects"].keys() == {"critical", "major", "minor"}
    assert validate([target], bench) == []
    assert validate([], bench) == []


def test_an_unknown_decision_is_refused_naming_the_row_and_the_value(tmp_path):
    bench, out, key_path = built(tmp_path)
    bad = [GOOD[0], {**GOOD[1], "merge_decision": "approve"}]
    sheet = fill(out, bad)
    with pytest.raises(PackError) as err:
        import_sheet(bench, sheet, key_path, now=NOW)
    message = str(err.value)
    assert ":3 " in message and "merge_decision" in message and "'approve'" in message
    assert not (bench / "results" / "review").exists()  # nothing was appended


@pytest.mark.parametrize(
    "change, needle",
    [
        ({"review_minutes": ""}, "review_minutes"),
        ({"review_minutes": 0}, "review_minutes"),
        ({"review_minutes": "soon"}, "review_minutes"),
        ({"major": "two"}, "major"),
        ({"minor": -1}, "minor"),
        ({"critical": ""}, "critical"),
    ],
)
def test_a_bad_number_is_refused(tmp_path, change, needle):
    bench, out, key_path = built(tmp_path)
    sheet = fill(out, [{**GOOD[0], **change}, GOOD[1]])
    with pytest.raises(PackError, match=needle):
        import_sheet(bench, sheet, key_path, now=NOW)
    assert not (bench / "results" / "review").exists()


def test_an_item_not_in_the_key_or_a_missing_item_is_refused(tmp_path):
    bench, out, key_path = built(tmp_path)
    sheet = fill(out, GOOD)
    text = sheet.read_text().replace(next(iter(json.loads(key_path.read_text())["items"])), "zzzz", 1)
    sheet.write_text(text)
    with pytest.raises(PackError) as err:
        import_sheet(bench, sheet, key_path, now=NOW)
    assert "'zzzz' is not in the key" in str(err.value)
    assert "items missing from the sheet" in str(err.value)


def test_a_sheet_that_leaves_an_item_out_is_refused(tmp_path):
    bench, out, key_path = built(tmp_path)
    sheet = fill(out, GOOD)
    lines = sheet.read_text().splitlines()
    sheet.write_text("\n".join(lines[:2]) + "\n")
    with pytest.raises(PackError, match="items missing from the sheet"):
        import_sheet(bench, sheet, key_path, now=NOW)


def test_a_wrong_header_is_refused(tmp_path):
    bench, out, key_path = built(tmp_path)
    sheet = fill(out, GOOD)
    sheet.write_text(sheet.read_text().replace("review_minutes", "minutes", 1))
    with pytest.raises(PackError, match="the header must be exactly"):
        import_sheet(bench, sheet, key_path, now=NOW)


def test_the_same_sheet_is_not_imported_twice(tmp_path):
    bench, out, key_path = built(tmp_path)
    sheet = fill(out, GOOD)
    import_sheet(bench, sheet, key_path, now=NOW)
    with pytest.raises(PackError, match="not imported twice"):
        import_sheet(bench, sheet, key_path, now=NOW)
    target = bench / "results" / "review" / "pack.jsonl"
    assert len(target.read_text().splitlines()) == 2


def test_the_cli_imports_a_sheet(tmp_path, capsys):
    bench, out, key_path = built(tmp_path)
    sheet = fill(out, GOOD)
    code = main(["review-pack", "--bench-dir", str(bench), "--import", str(sheet), "--key", str(key_path)])
    assert code == 0
    assert "imported 2 review record(s)" in capsys.readouterr().out
    assert validate([], bench) == []


def test_the_cli_refuses_a_bad_sheet_with_exit_code_one(tmp_path, capsys):
    bench, out, key_path = built(tmp_path)
    sheet = fill(out, [GOOD[0], {**GOOD[1], "merge_decision": "ship-it"}])
    assert main(["review-pack", "--bench-dir", str(bench), "--import", str(sheet), "--key", str(key_path)]) == 1
    assert "'ship-it'" in capsys.readouterr().err


def test_the_cli_needs_its_arguments(tmp_path, capsys):
    bench = make_bench(tmp_path)
    assert main(["review-pack", "--bench-dir", str(bench), "--batch", "fixture-batch"]) == 1
    assert main(["review-pack", "--bench-dir", str(bench), "--import", "x.csv"]) == 1
    assert "needs" in capsys.readouterr().err
