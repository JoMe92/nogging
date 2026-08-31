#!/usr/bin/env bash
# Focused checks for the installer CLI (bin/cli.js).
#
# Node is required to exercise the CLI. The repository test runner is otherwise
# offline and bash-only, so when node is absent this test skips with a PASS
# rather than failing the suite.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$root/bin/cli.js"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - skipped (node not installed)"
  echo "all installer CLI checks passed"
  exit 0
fi

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- init into a fresh repo -------------------------------------------------
repo="$work/fresh"
mkdir -p "$repo"
git -C "$repo" init -q

( cd "$repo" && node "$cli" init --dry-run >/dev/null )
check "dry-run writes nothing" [ -z "$(find "$repo" -type f -not -path '*/.git/*')" ]

( cd "$repo" && node "$cli" init >/dev/null )
check "tool bridge installed"      test -f "$repo/scripts/specforge"
check "install-hooks installed"    test -f "$repo/scripts/install-hooks"
check "boundary hook installed"    test -f "$repo/scripts/hooks/pre-tool-use-openspec-guard"
check "bridge is executable"       test -x "$repo/scripts/specforge"
check "skills copied"              test -f "$repo/.agents/skills/openspec-propose/SKILL.md"
check "reference docs under docs/specforge" test -f "$repo/docs/specforge/architecture.md"
check "openspec scaffold written"  test -f "$repo/openspec/config.yaml"
check "project.md scaffold written" test -f "$repo/openspec/project.md"
check "config.json written"        test -f "$repo/.specforge/config.json"

name=$(node -e "process.stdout.write(require('$repo/.specforge/config.json').name)")
check "config name is repo basename" [ "$name" = "fresh" ]
ver=$(node -e "process.stdout.write(String(require('$repo/.specforge/config.json').specforge_version||''))")
check "config records a version" [ -n "$ver" ]

# --- idempotent merges ----------------------------------------------------
merged="$work/merged"
mkdir -p "$merged/.claude"
git -C "$merged" init -q
cat > "$merged/.claude/settings.json" <<'JSON'
{
  "model": "sonnet",
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "bd prime --hook-json" } ] }
    ]
  }
}
JSON
printf 'node_modules/\n' > "$merged/.gitignore"
printf '# My project\n\nExisting notes.\n' > "$merged/CLAUDE.md"

( cd "$merged" && node "$cli" init >/dev/null )
( cd "$merged" && node "$cli" init >/dev/null )

guard_count=$(node -e "
  const s = require('$merged/.claude/settings.json');
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  let n = 0;
  for (const e of pre) for (const h of (e.hooks||[])) if ((h.command||'').includes('pre-tool-use-openspec-guard')) n++;
  process.stdout.write(String(n));
")
check "guard hook added exactly once" [ "$guard_count" = "1" ]

sess_kept=$(node -e "
  const s = require('$merged/.claude/settings.json');
  const ss = (s.hooks && s.hooks.SessionStart) || [];
  process.stdout.write(String(ss.length));
")
check "existing SessionStart hook preserved" [ "$sess_kept" = "1" ]
check "unrelated setting preserved" node -e "process.exit(require('$merged/.claude/settings.json').model === 'sonnet' ? 0 : 1)"

check "gitignore keeps original line" grep -qx 'node_modules/' "$merged/.gitignore"
check "gitignore adds locks line once" [ "$(grep -cx '.specforge/locks/' "$merged/.gitignore")" = "1" ]

check "CLAUDE.md keeps existing content" grep -q "Existing notes." "$merged/CLAUDE.md"
check "CLAUDE.md has one begin marker" [ "$(grep -c 'specforge:begin' "$merged/CLAUDE.md")" = "1" ]
check "CLAUDE.md has one end marker" [ "$(grep -c 'specforge:end' "$merged/CLAUDE.md")" = "1" ]
check "AGENTS.md created with block" grep -q "specforge:begin" "$merged/AGENTS.md"

# --- scaffold files are preserved -----------------------------------------
repo2="$work/existing"
mkdir -p "$repo2/openspec"
git -C "$repo2" init -q
printf '# Kept project doc\n' > "$repo2/openspec/project.md"
( cd "$repo2" && node "$cli" init >/dev/null )
check "existing project.md untouched" grep -q "Kept project doc" "$repo2/openspec/project.md"

# --- not a git repo ------------------------------------------------------
plain="$work/plain"
mkdir -p "$plain"
rc=0
( cd "$plain" && node "$cli" init >/dev/null 2>&1 ) || rc=$?
check "refuses outside a git repo" [ "$rc" -ne 0 ]

if [[ $fail -ne 0 ]]; then
  echo "installer CLI checks failed" >&2
  exit 1
fi
echo "all installer CLI checks passed"
