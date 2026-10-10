#!/usr/bin/env bash
# Planning-flow documentation agrees across every surface (TASK-SSP-005):
# the supervised planning role, commit-before-materialize, cleanup before
# plan-end from a surviving canonical checkout, and the canonical,
# session-owned planning lock. Then a fresh install must carry the same text.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
def text(rel):
    return re.sub(r"\s+", " ", (root / rel).read_text())

COMMIT = r"(as the `planning` writer|NOGGING_WRITER=planning|Nogging-Writer: planning)"
MATERIALIZE = r"\bmaterialize\b"
SURVIVING = "surviving canonical checkout"
ROLE = "--role planning"
bad = []

def ordered(rel, t, *patterns):
    pos = 0
    for pat in patterns:
        m = re.search(pat, t[pos:])
        if not m:
            bad.append(f"{rel}: '{pat}' missing or out of order"); return
        pos += m.end()

commands = [".claude/commands/plan.md", ".codex/prompts/plan.md", ".pi/prompts/plan.md"]
for rel in commands:
    t = text(rel)
    for phrase in (ROLE, SURVIVING, "bd dep add", "canonical", "Nobody acquires the planning lock for you",
                   "never claim it", "Cleanup always precedes `plan-end`", "never releases its lock"):
        if phrase not in t:
            bad.append(f"{rel}: missing '{phrase}'")
    ordered(rel, t, "plan-begin", COMMIT, MATERIALIZE, "bd dep add", "fast-forward merge",
            "remove that worktree", "Release the planning lock", SURVIVING)

# Each surface that states the flow: commit before materialize, then cleanup,
# then plan-end from a surviving canonical checkout.
flow = ["AGENTS.md", "templates/agents-block.md", "docs/operating-model.md", "README.md",
        "docs/using-with-codex.md", "docs/using-with-pi.md", "docs/worktree-workflow.md",
        "docs/running-work-in-sessions.md", ".nogging/launch-prompts/orchestrator.md",
        ".claude/commands/orchestrate.md"]
for rel in flow:
    t = text(rel)
    ordered(rel, t, COMMIT, MATERIALIZE, r"(cleanup|clean, integrated|remove the clean)", SURVIVING)

# The supervised planning role and the session-owned canonical lock.
for rel in ["AGENTS.md", "templates/agents-block.md", "docs/operating-model.md", "README.md",
            "docs/running-work-in-sessions.md", "docs/security-model.md"]:
    t = text(rel)
    if ROLE not in t:
        bad.append(f"{rel}: does not name the supervised `{ROLE}` launch")
    if "canonical" not in t:
        bad.append(f"{rel}: does not name the canonical planning lock")
for rel in ["AGENTS.md", "templates/agents-block.md", "docs/running-work-in-sessions.md", "docs/security-model.md"]:
    if not re.search(r"never (release[s]? (a lock owned by )?)?another (live )?session", text(rel)):
        bad.append(f"{rel}: does not say stop/cleanup never release another session's lock")
for rel in ["AGENTS.md", "templates/agents-block.md", "docs/security-model.md"]:
    if not re.search(r"execution role", text(rel), re.I):
        bad.append(f"{rel}: does not keep execution roles fenced while a planning lock is held")

# The supervised planning launch prompt states the same order.
ordered(".nogging/launch-prompts/planning.md", text(".nogging/launch-prompts/planning.md"),
        "plan-begin", "planning writer", "Materialize", "dependencies", "Fast-forward",
        "retire", "plan-end", SURVIVING)

for line in bad:
    print("FAIL -", line)
if bad:
    sys.exit(1)
print("ok   - planning flow, role and canonical lock agree on every surface")
PY

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP - installed instructions: node not on PATH"
  exit 0
fi
target=$(mktemp -d "${TMPDIR:-/tmp}/nogg-planning-docs.XXXXXX")
trap 'chmod -R u+w "$target" 2>/dev/null; find "$target" -mindepth 1 -delete 2>/dev/null; rmdir "$target" 2>/dev/null || true' EXIT
git init -q "$target"
( cd "$target" && node "$root/bin/cli.js" init --no-beads --no-systemd --no-hooks >/dev/null )
python3 - "$root" "$target" <<'PY'
import sys
from pathlib import Path
root, target = map(Path, sys.argv[1:])
bad = []
for rel in [".claude/commands/plan.md", ".codex/prompts/plan.md", ".pi/prompts/plan.md",
            ".nogging/launch-prompts/planning.md", ".nogging/launch-prompts/orchestrator.md",
            ".claude/commands/orchestrate.md"]:
    if (target / rel).read_bytes() != (root / rel).read_bytes():
        bad.append(f"installed {rel} differs from the source")
for rel, template in [("AGENTS.md", "templates/agents-block.md"), ("CLAUDE.md", "templates/claude-block.md")]:
    if (root / template).read_text().strip() not in (target / rel).read_text():
        bad.append(f"installed {rel} does not carry {template} verbatim")
for line in bad:
    print("FAIL -", line)
if bad:
    sys.exit(1)
print("ok   - installed instructions carry the reconciled planning flow verbatim")
PY
