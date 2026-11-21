#!/usr/bin/env bash
# The lean install (adaptive-ceremony TASK-CER-006): the lean agents block, the
# pointer-only Claude block and the on-demand skills, chosen by the target's
# `ceremony.mode`. Under the default `always-full` an install is unchanged.
# Offline: no network, no bd/Dolt (stubbed for doctor), no tmux server, no systemd.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
cli="$root/bin/cli.js"

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

# --- medium: temporary target repositories -----------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "ok   - install checks skipped (node not installed)"
  [ "$fail" -eq 0 ] || exit 1
  echo "all ceremony install checks passed"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stubs="$work/stubs"; mkdir -p "$stubs" "$work/tmux"
printf '#!/usr/bin/env bash\nif [[ "$*" == *--json* ]]; then echo "[]"; fi\nexit 0\n' >"$stubs/bd"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/dolt"
chmod +x "$stubs/bd" "$stubs/dolt"

flags=(--no-beads --no-hooks --no-systemd)
new_repo() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" -c user.name=Test -c user.email=test@test.local commit --allow-empty -qm init
}
run() { # <repo> <args...>; stdout+stderr to $out, status to $status
  local repo="$1"; shift
  status=0
  out=$(cd "$repo" && NOGG_PREFLIGHT_TIMEOUT_MS=500 node "$cli" "$@" 2>&1) || status=$?
}
doctor() { # <repo>; output to $out
  out=$(cd "$1" && env -u TMUX PATH="$stubs:$PATH" NOGGING_ROOT="$1" TMUX_TMPDIR="$work/tmux" \
    scripts/nogg doctor 2>&1) || true
}
set_mode() { # <repo> <mode>
  python3 - "$1/.nogging/config.json" "$2" <<'PY'
import json, sys
path, mode = sys.argv[1:]
data = json.load(open(path))
data["ceremony"] = {"mode": mode}
open(path, "w").write(json.dumps(data, indent=2) + "\n")
PY
}
tree() { # <repo>: per-file hashes of the install, without what doctor and Python write
  (cd "$1" && find . -type f -not -path './.git/*' -not -path './.nogging/locks/*' \
    -not -path './.nogging/state/*' -not -path '*/__pycache__/*' | LC_ALL=C sort | xargs sha256sum)
}
block_is() { # <repo> <file> <template>: the managed block equals the template, byte for byte
  python3 - "$1/$2" "$root/$3" <<'PY'
import sys
installed, template = (open(path).read() for path in sys.argv[1:])
begin, end = "<!-- nogging:begin -->\n", "<!-- nogging:end -->\n"
block = installed[installed.index(begin) + len(begin):installed.index(end)]
sys.exit(0 if block == template.rstrip() + "\n" else 1)
PY
}
skills_absent() { # <repo>: no Nogging skill of the lean install, under either root
  [ ! -e "$1/.claude/skills" ] && ! compgen -G "$1/.agents/skills/nogging-lead-workflow" >/dev/null \
    && [ -z "$(cd "$1" && grep -l 'skills/nogging-\(lead-workflow\|planning\|sessions\|specialists\|recovery\)/' \
      .nogging/installed-manifest.json)" ]
}
skills_installed() { # <repo>: every source skill, byte-equal, under both roots
  local name
  for name in "$root"/templates/skills/*/; do
    name=$(basename "$name")
    cmp -s "$root/templates/skills/$name/SKILL.md" "$1/.claude/skills/$name/SKILL.md" || return 1
    cmp -s "$root/templates/skills/$name/SKILL.md" "$1/.agents/skills/$name/SKILL.md" || return 1
  done
}
named_skills_exist() { # <repo>: every skill path the installed block names is a file
  local rel
  for rel in $(grep -o '\.\(claude\|agents\)/skills/nogging-[a-z-]*/SKILL\.md' "$1/AGENTS.md" | sort -u); do
    [ -f "$1/$rel" ] || return 1
  done
  grep -q 'skills/nogging-' "$1/AGENTS.md"
}
lean_installed() { block_is "$1" AGENTS.md templates/agents-block-lean.md && skills_installed "$1"; }
block_lines() { sed -n '/<!-- nogging:begin -->/,/<!-- nogging:end -->/p' "$1/AGENTS.md" | wc -l; }
mismatch='^WARN  AGENTS.md carries the .* Nogging block, but ceremony.mode is'

# "The default install is unchanged": no ceremony block, today's blocks, no new skill.
plain="$work/plain/repo"; new_repo "$plain"
run "$plain" init "${flags[@]}"
check "default init: exits 0" test "$status" -eq 0
check "default init: the agents block equals today's template" block_is "$plain" AGENTS.md templates/agents-block.md
check "default init: the Claude block equals today's template" block_is "$plain" CLAUDE.md templates/claude-block.md
check "default init: no new skill" skills_absent "$plain"
default_tree=$(tree "$plain")

repo="$work/switch/repo"; new_repo "$repo"
printf '# My project\n\nOwn instructions.\n' >"$repo/AGENTS.md"
run "$repo" init "${flags[@]}"
cp "$repo/.nogging/config.json" "$work/config.default.json"
doctor "$repo"
check "default install: doctor reports no block mismatch" bash -c '! grep -Eq "$1" <<<"$2"' _ "$mismatch" "$out"

# An unknown mode falls back to the default.
set_mode "$repo" sometimes
run "$repo" update "${flags[@]}"
check "unknown mode: the full block stays" block_is "$repo" AGENTS.md templates/agents-block.md
check "unknown mode: no new skill" skills_absent "$repo"

# "A mode change is noticed": the mode is switched and update has not run yet.
set_mode "$repo" adaptive
doctor "$repo"
check "mode switched to adaptive, no update yet: doctor warns" \
  grep -Eq '^WARN  AGENTS.md carries the full Nogging block, but ceremony.mode is adaptive' <<<"$out"

# "The lean install is short": init in a repository whose mode is adaptive.
run "$repo" init "${flags[@]}"
check "lean init: exits 0" test "$status" -eq 0
check "lean init: the agents block is the lean template" block_is "$repo" AGENTS.md templates/agents-block-lean.md
check "lean init: the agents block has fewer than 150 lines" test "$(block_lines "$repo")" -lt 150
check "lean init: the Claude block is the pointer" block_is "$repo" CLAUDE.md templates/claude-block-lean.md
check "lean init: the skills are installed under both roots" skills_installed "$repo"
check "lean init: every skill the block names exists" named_skills_exist "$repo"
check "lean init: the repository's own instructions are kept" grep -Fxq 'Own instructions.' "$repo/AGENTS.md"
doctor "$repo"
check "lean install: doctor reports no block mismatch" bash -c '! grep -Eq "$1" <<<"$2"' _ "$mismatch" "$out"
before=$(tree "$repo")
run "$repo" update "${flags[@]}"
check "lean update, no change: writes nothing" test "$before" = "$(tree "$repo")"

# `always-fast` is lean as well.
set_mode "$repo" always-fast
run "$repo" update "${flags[@]}"
check "always-fast: the lean block and the skills stay" lean_installed "$repo"

# Back to the default: doctor notices, update switches the blocks and removes the skills.
cp "$work/config.default.json" "$repo/.nogging/config.json"
doctor "$repo"
check "mode switched back, no update yet: doctor warns" \
  grep -Eq '^WARN  AGENTS.md carries the lean Nogging block, but ceremony.mode is always-full' <<<"$out"
run "$repo" update "${flags[@]}"
check "update after switching back: exits 0" test "$status" -eq 0
check "update after switching back: today's agents block" block_is "$repo" AGENTS.md templates/agents-block.md
check "update after switching back: today's Claude block" block_is "$repo" CLAUDE.md templates/claude-block.md
check "update after switching back: the skills are gone" skills_absent "$repo"
doctor "$repo"
check "after switching back: doctor reports no block mismatch" bash -c '! grep -Eq "$1" <<<"$2"' _ "$mismatch" "$out"
# Apart from the repository's own AGENTS.md text, the round trip leaves a default install.
check "the round trip leaves the default install, byte for byte" \
  test "$(grep -v ' ./AGENTS.md$' <<<"$default_tree")" = "$(tree "$repo" | grep -v ' ./AGENTS.md$')"

# A skill the operator edited is kept when the mode goes back, and named.
set_mode "$repo" adaptive
run "$repo" update "${flags[@]}"
printf '\nOwn note.\n' >>"$repo/.claude/skills/nogging-recovery/SKILL.md"
cp "$work/config.default.json" "$repo/.nogging/config.json"
run "$repo" update "${flags[@]}"
check "an edited skill is kept on the way back" grep -Fxq 'Own note.' "$repo/.claude/skills/nogging-recovery/SKILL.md"
check "an edited skill is named in the output" \
  grep -Fq '.claude/skills/nogging-recovery/SKILL.md was edited locally and is kept' <<<"$out"
check "the unedited skills are removed" test ! -e "$repo/.agents/skills/nogging-recovery"

# `remove` takes the skills of a lean install with it.
set_mode "$repo" adaptive
run "$repo" update --force "${flags[@]}"
run "$repo" remove
check "remove: exits 0" test "$status" -eq 0
check "remove: the skills are gone" test ! -e "$repo/.agents/skills/nogging-lead-workflow/SKILL.md" -a \
  ! -e "$repo/.claude/skills/nogging-lead-workflow/SKILL.md"

if [ "$fail" -ne 0 ]; then
  echo "ceremony install checks failed" >&2
  exit 1
fi
echo "all ceremony install checks passed"
