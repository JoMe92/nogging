"""The blinded review pack: anonymisation first; the pack, key and import follow."""

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
