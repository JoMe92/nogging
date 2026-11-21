#!/usr/bin/env bash
# The lean install (adaptive-ceremony TASK-CER-006): the lean agents block, the
# pointer-only Claude block and the on-demand skills, chosen by the target's
# `ceremony.mode`. Under the default `always-full` an install is unchanged.
# Offline: no network, no bd/Dolt (stubbed for doctor), no tmux server, no systemd.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}

# --- small: the sources ------------------------------------------------------
if python3 - "$root" <<'PY'
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
norm = lambda text: " ".join(text.split())
full = norm((root / "templates/agents-block.md").read_text())
lean_raw = (root / "templates/agents-block-lean.md").read_text()
claude_raw = (root / "templates/claude-block-lean.md").read_text()
lean = norm(lean_raw)
skills_dir = root / "templates/skills"
skills = {path.parent.name: path.read_text() for path in sorted(skills_dir.glob("*/SKILL.md"))}
everything = lean + " " + norm(" ".join(skills.values()))
bad = []

if len(lean_raw.splitlines()) >= 150:
    bad.append(f"the lean agents block has {len(lean_raw.splitlines())} lines, not under 150")
if len(claude_raw.splitlines()) > 12 or "`AGENTS.md`" not in claude_raw or "Claude-only" in claude_raw:
    bad.append("the lean Claude block is not a pointer to AGENTS.md only")
for name, raw in (("agents", lean_raw), ("Claude", claude_raw)):
    if "<!-- nogging:instructions lean -->" not in raw:
        bad.append(f"the lean {name} block lacks the line doctor recognises it by")

# Every skill path the block names exists in the one source, under both roots'
# names, and every source skill is named; a skill's name is its directory.
named = set(re.findall(r"\.(claude|agents)/skills/(nogging-[a-z-]+)/SKILL\.md", lean_raw))
for kind, name in sorted(named):
    if name not in skills:
        bad.append(f"the lean block names .{kind}/skills/{name}/SKILL.md, which has no source")
for name, raw in skills.items():
    for kind in ("claude", "agents"):
        if (kind, name) not in named:
            bad.append(f"the lean block does not name .{kind}/skills/{name}/SKILL.md")
    if not re.search(rf"^---\nname: {name}\ndescription: \S.*\n---\n", raw):
        bad.append(f"{name}/SKILL.md lacks the name and description front matter")
if set(skills) != {"nogging-lead-workflow", "nogging-planning", "nogging-sessions",
                   "nogging-specialists", "nogging-recovery"}:
    bad.append(f"unexpected skill set: {sorted(skills)}")

# "The hard rules survive the diet": every phrase is in today's block (so the
# list stays honest) and in the lean block or a skill it names. The Antigravity
# paragraph is not listed: its rules stay in the installed guide, which the
# sessions skill points to, and the diet adds nothing specific to it.
phrases = [
    "must not edit `openspec/`",
    "Work only on a Bead that has been claimed by the Main Worker",
    "Commit a Bead in several coherent steps, not as one commit at the end",
    "`task_sizing.commit_lines`", "`./scripts/nogg task-sizing`",
    "Conventional Commit containing the Bead ID (e.g. `[SPEC-abc]`)",
    "holds the tests for the code it changes",
    "`./scripts/nogg test changed`", "`./scripts/nogg test commit`", "`./scripts/nogg test bead`",
    "`./scripts/nogg test full` is only for a release, the nightly run or an explicit recorded reason",
    "`Test-Integrity: <reason>` commit trailer and a discovery note on the Bead",
    "`./scripts/nogg run-quiet -- <command>`", "never poll a running command",
    "`bd close <id>`", "`./scripts/nogg task-done <id>`", "refuses unless the Bead is already closed",
    "listing every commit SHA",
    "`discovery` label plus a required human-readable note", "`bd list --label discovery`",
    "`progress: <next step>`", "`in_progress`", "breadcrumb",
    "`.nogging/locks/planning.lock`", "`.nogging/locks/openspec.readonly`",
    "A held planning lock never makes `openspec/` writable for an execution role",
    "claiming a Bead, closing it, writing the evidence note, and committing stay with the Main Worker",
    "no delegated context may write `openspec/`",
    "`Co-authored-by: <specialist persona name> <specialist persona email>`",
    "`./scripts/nogg worktree plan <planning-id> <description>`", "is never claimed",
    "`NOGGING_WRITER=planning`", "`plan-end` always precedes worktree retirement",
    "`openspec validate <change> --strict --no-interactive`",
    "never release another session's planning lock",
    "The commit precedes `materialize`",
    "orchestrate-only by default", "never signs an acceptance report", "`/orchestrate takeover {plan|code}`",
    "`bd dolt pull` once at session start", "`bd dolt push` before the session ends",
    "`scripts/hooks/pre-tool-use-openspec-guard`",
    "The assigned `claude/*` branch is never a PR source",
    "`.codex/rules/nogging.rules`", "never a loop of one-second polls",
    "`.pi/extensions/nogging-guard.ts`", "`restricted` is floor-only",
    "`npx github:JoMe92/nogging update`",
]
for phrase in phrases:
    if phrase not in full:
        bad.append(f"test list: '{phrase}' is not a phrase of today's block")
    if phrase not in everything:
        bad.append(f"hard rule lost in the diet: '{phrase}'")

# The write boundary, the Bead token and the test commands stay in the block
# itself, with the rules the lean block states beyond today's block.
for phrase in ["must not edit `openspec/`", "`openspec/` is read-only for every execution agent",
               "`.nogging/locks/planning.lock`", "(e.g. `[SPEC-abc]`)", "configured commit range",
               "`./scripts/nogg test changed`", "`./scripts/nogg test commit`", "`./scripts/nogg test bead`",
               "`Test-Integrity: <reason>`", "`discovery` label plus a required human-readable note",
               "`progress: <next step>`", "`./scripts/nogg session signal done", "`./scripts/nogg session signal blocked",
               "`./scripts/nogg recover` before selecting work with `bd ready`",
               "Product Owner", "Orchestration Agent", "Planning Agent", "Main Worker", "Specialists"]:
    if phrase not in lean:
        bad.append(f"the lean block itself does not carry '{phrase}'")

for line in bad:
    print("FAIL -", line)
sys.exit(1 if bad else 0)
PY
then
  echo "ok   - the lean block is under 150 lines, names every skill, and keeps the hard rules"
else
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "ceremony install checks failed" >&2
  exit 1
fi
echo "all ceremony install checks passed"
