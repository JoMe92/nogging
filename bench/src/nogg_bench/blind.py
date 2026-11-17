"""Blinding: remove Nogging's process artefacts from a diff and prove it did.

The whole anonymisation of the review pack lives in this one module, so a review
of it is a review of what the reviewer can and cannot see. It is pure: text in,
text out, no files and no clock.

What is removed (design Decision 13):

* whole file sections of the diff whose path is a process artefact: the
  directories ``openspec/``, ``.beads/``, ``.nogging/``, ``.claude/``,
  ``.codex/``, ``.pi/`` and ``.agents/`` at the repository root, and the files
  ``AGENTS.md`` and ``CLAUDE.md`` at any depth;
* in commit text (everything outside a file section, as ``git format-patch``
  writes it): Bead tokens, ``Nogging-Writer:`` and ``Co-authored-by:`` lines, and
  the author and date headers, the diffstat and the mbox ``From`` line that
  would name who wrote the commit.

After that :func:`surviving_markers` looks for every marker again, in the whole
text and not only where :func:`anonymise` looked. A marker found there means the
anonymisation is not trustworthy for that run, and the pack is not written.
"""

from __future__ import annotations

import re

ARTEFACT_DIRS = ("openspec", ".beads", ".nogging", ".claude", ".codex", ".pi", ".agents")
ARTEFACT_FILES = ("AGENTS.md", "CLAUDE.md")

# A Bead id is a prefix, a dash and a short id with at least one lowercase letter
# (SPEC-hio1); a task id such as BEN-004 is not a Bead id but is stripped as the
# bracketed form [BEN-004] too, which is how commit subjects carry it.
_BEAD_BARE = r"[A-Z][A-Z0-9]{1,9}-(?=[a-z0-9]*[a-z])[a-z0-9]{3,8}"
_BEAD_BRACKETED = r"\[[A-Za-z][A-Za-z0-9]{1,9}(?:-[A-Za-z0-9]+)+\]"
BEAD_TOKEN = re.compile(rf"{_BEAD_BRACKETED}|(?<![\w-]){_BEAD_BARE}(?![\w-])")
_BEAD_TOKEN_STRICT = re.compile(rf"(?<![\w-]){_BEAD_BARE}(?![\w-])|\[{_BEAD_BARE}\]")

TRAILER_LINE = re.compile(r"^[+\- ]?\s*(?:Nogging-Writer|Co-authored-by)\s*:", re.IGNORECASE)
_MARKER_PATH = re.compile(
    r"(?<![\w./-])(?:" + "|".join(re.escape(d) for d in ARTEFACT_DIRS) + r")/"
    r"|(?<![\w./-])(?:AGENTS|CLAUDE)\.md(?![\w])"
)

_FILE_START = re.compile(r"^diff --git ")
_MBOX_FROM = re.compile(r"^From [0-9a-f]{7,40} ")
_AUTHOR_HEADER = re.compile(r"^(?:From|Date|Author|AuthorDate|Commit|CommitDate):")
_DIFFSTAT = re.compile(r"^ .+\|\s+(?:\d+|Bin)\b")
_DIFFSTAT_SUMMARY = re.compile(r"^ \d+ files? changed")


def is_artefact_path(path: str) -> bool:
    """True when ``path`` (repository-relative, ``/``-separated) is a process artefact."""
    parts = [p for p in path.strip().split("/") if p not in ("", ".")]
    if not parts:
        return False
    return parts[0] in ARTEFACT_DIRS or parts[-1] in ARTEFACT_FILES


def _header_paths(line: str) -> list[tuple[str, str]]:
    """Candidate ``(a_path, b_path)`` splits of a ``diff --git a/X b/Y`` line.

    A path with spaces is ambiguous; every split at `` b/`` is a candidate and
    the section is stripped when any candidate names an artefact.
    """
    rest = line[len("diff --git "):].strip().strip('"')
    if not rest.startswith("a/"):
        return [(rest, rest)]
    rest = rest[2:]
    out = []
    start = 0
    while True:
        i = rest.find(" b/", start)
        if i < 0:
            break
        out.append((rest[:i], rest[i + 3:]))
        start = i + 1
    return out or [(rest, rest)]


def _section_is_artefact(header: str) -> bool:
    return any(is_artefact_path(a) or is_artefact_path(b) for a, b in _header_paths(header))


def _split(diff: str) -> list[tuple[bool, list[str]]]:
    """Cut the text into ``(is_file_section, lines)`` blocks in order.

    A file section runs from a ``diff --git`` line to the next one. Text between
    a section and the next commit's header (``From <sha>`` of a format-patch
    series) is commit text again, so a series keeps each commit's text apart from
    the previous file's hunks.
    """
    blocks: list[tuple[bool, list[str]]] = []
    current: list[str] = []
    in_file = False
    for line in diff.splitlines():
        if _FILE_START.match(line):
            if current:
                blocks.append((in_file, current))
            current, in_file = [line], True
        elif in_file and _MBOX_FROM.match(line):
            blocks.append((True, current))
            current, in_file = [line], False
        else:
            current.append(line)
    if current:
        blocks.append((in_file, current))
    return blocks


def _clean_commit_text(lines: list[str]) -> list[str]:
    out = []
    for line in lines:
        if _MBOX_FROM.match(line) or _AUTHOR_HEADER.match(line):
            continue
        if _DIFFSTAT.match(line) or _DIFFSTAT_SUMMARY.match(line):
            continue
        if TRAILER_LINE.match(line):
            continue
        out.append(BEAD_TOKEN.sub("", line).rstrip() if BEAD_TOKEN.search(line) else line)
    return out


def anonymise(diff: str) -> str:
    """The diff with every process artefact removed (see the module docstring)."""
    kept: list[str] = []
    for is_file, lines in _split(diff):
        if is_file:
            if _section_is_artefact(lines[0]):
                continue
            kept.extend(lines)
        else:
            kept.extend(_clean_commit_text(lines))
    text = "\n".join(kept)
    return text + "\n" if text else ""


def surviving_markers(text: str, run_id: str | None = None) -> list[str]:
    """Every marker still in ``text``, as short human-readable descriptions.

    Looks at the whole text: a file header naming an artefact path, a path of an
    artefact directory or file anywhere, a ``Nogging-Writer:`` or ``Co-authored-by:``
    line, a Bead token, and the run ID. An empty list means the text is clean.
    """
    found: list[str] = []
    for number, line in enumerate(text.splitlines(), start=1):
        if TRAILER_LINE.match(line):
            found.append(f"line {number}: a commit trailer ({line.strip().split(':')[0]}:)")
        for token in _BEAD_TOKEN_STRICT.findall(line):
            found.append(f"line {number}: the Bead token {token}")
        if _FILE_START.match(line) and _section_is_artefact(line):
            found.append(f"line {number}: a diff section for an artefact path")
        for match in _MARKER_PATH.finditer(line):
            found.append(f"line {number}: the artefact path {match.group(0)}")
    if run_id and run_id in text:
        found.append("the run ID")
    return found
