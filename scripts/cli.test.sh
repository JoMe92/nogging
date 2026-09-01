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

( cd "$repo" && node "$cli" init --no-beads --dry-run >/dev/null )
check "dry-run writes nothing" [ -z "$(find "$repo" -type f -not -path '*/.git/*')" ]

( cd "$repo" && node "$cli" init --no-beads >/dev/null )
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

# --- bd init bootstrap (only where bd is installed) ----------------------
if command -v bd >/dev/null 2>&1; then
  bdrepo="$work/bdinit"
  mkdir -p "$bdrepo"
  git -C "$bdrepo" init -q
  ( cd "$bdrepo" && node "$cli" init --no-systemd >/dev/null 2>&1 ) || true
  check "init creates the beads tracker" test -d "$bdrepo/.beads"
  before=$(find "$bdrepo/.beads" -type f | sort | md5sum)
  ( cd "$bdrepo" && node "$cli" init --no-systemd >/dev/null 2>&1 ) || true
  after=$(find "$bdrepo/.beads" -type f | sort | md5sum)
  check "second init leaves .beads file set unchanged" [ "$before" = "$after" ]

  nobd="$work/nobd"
  mkdir -p "$nobd"; git -C "$nobd" init -q
  nobd_out=$( cd "$nobd" && node "$cli" init --no-beads --no-systemd 2>&1 ) || true
  check "--no-beads skips the tracker" [ ! -d "$nobd/.beads" ]
  check "verdict names the tracker gap after --no-beads" \
    bash -c "grep -q 'not ready' <<< \"\$0\" && grep -qi 'tracker' <<< \"\$0\"" "$nobd_out"

  # ready verdict only where the full toolchain is present and doctor passes
  if command -v dolt >/dev/null 2>&1 \
     && ( cd "$bdrepo" && bd list --json >/dev/null 2>&1 ); then
    ready_out=$( cd "$bdrepo" && node "$cli" init --no-systemd 2>&1 ) || true
    check "verdict says ready in a provisioned repo" \
      bash -c "grep -q 'SpecForge is ready' <<< \"\$0\"" "$ready_out"
  else
    echo "ok   - ready-verdict check skipped (toolchain incomplete)"
  fi
else
  echo "ok   - bd init bootstrap skipped (bd not installed)"
fi

# --- readiness verdict without any toolchain --------------------------------
verd="$work/verdict"
mkdir -p "$verd"; git -C "$verd" init -q
verd_out=$( cd "$verd" && node "$cli" init --no-beads --no-systemd 2>&1 ) || true
check "init always prints a readiness verdict" \
  bash -c "grep -q 'SpecForge is \(ready\|installed but not ready\)' <<< \"\$0\"" "$verd_out"

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

( cd "$merged" && node "$cli" init --no-beads >/dev/null )
( cd "$merged" && node "$cli" init --no-beads >/dev/null )

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

# --- strict idempotency: commit, re-run, expect no tracked diff ----------
idem="$work/idempotent"
mkdir -p "$idem"
git -C "$idem" init -q
git -C "$idem" config user.email t@example.com
git -C "$idem" config user.name test
( cd "$idem" && node "$cli" init --no-beads >/dev/null )
git -C "$idem" add -A
git -C "$idem" -c core.hooksPath=/dev/null commit -q -m "install specforge"
( cd "$idem" && node "$cli" init --no-beads >/dev/null )
( cd "$idem" && node "$cli" update >/dev/null )
check "re-init + update produce no tracked diff" git -C "$idem" diff --quiet

# --- scaffold files are preserved -----------------------------------------
repo2="$work/existing"
mkdir -p "$repo2/openspec"
git -C "$repo2" init -q
printf '# Kept project doc\n' > "$repo2/openspec/project.md"
( cd "$repo2" && node "$cli" init --no-beads >/dev/null )
check "existing project.md untouched" grep -q "Kept project doc" "$repo2/openspec/project.md"

# --- rendered systemd unit ---------------------------------------------
unit=$(find "$repo/systemd" -name 'specforge-sync-*.service')
check "systemd service rendered" test -n "$unit"
check "service targets the repo" grep -qx "WorkingDirectory=$repo" "$unit"
check "service ExecStart is absolute" grep -qx "ExecStart=$repo/scripts/specforge sync" "$unit"
check "unit filename carries the slug" bash -c "[[ '$(basename "$unit")' == specforge-sync-fresh.service ]]"
tunit=$(find "$repo/systemd" -name 'specforge-sync-*.timer')
check "timer binds the slugged service" grep -qx "Unit=specforge-sync-fresh.service" "$tunit"

# --- --no-systemd -----------------------------------------------------
nos="$work/nosystemd"
mkdir -p "$nos"; git -C "$nos" init -q
( cd "$nos" && node "$cli" init --no-beads --no-systemd >/dev/null )
check "--no-systemd skips the unit" [ ! -d "$nos/systemd" ]

# --- core.hooksPath warning ------------------------------------------
hp="$work/hookspath"
mkdir -p "$hp/.beads/hooks"; git -C "$hp" init -q
git -C "$hp" config core.hooksPath .beads/hooks
out=$( cd "$hp" && node "$cli" init --no-beads 2>&1 )
check "warns when core.hooksPath diverts git" bash -c "grep -q 'core.hooksPath' <<< \"\$0\"" "$out"

# --- update preserves target-owned state -------------------------------
upd="$work/update"
mkdir -p "$upd"; git -C "$upd" init -q
( cd "$upd" && node "$cli" init --no-beads --no-systemd >/dev/null )
mkdir -p "$upd/openspec/changes/my-change"
printf '# Tasks\n\n- [ ] TASK-X-001 do a thing\n' > "$upd/openspec/changes/my-change/tasks.md"
printf '# My project\n\nCustom purpose.\n' > "$upd/openspec/project.md"
node -e "
  const f='$upd/.specforge/config.json'; const d=require(f);
  d.specforge_version='0.0.1'; d.name='my-custom-name';
  require('fs').writeFileSync(f, JSON.stringify(d,null,2)+'\n');
"
changes_before=$(cd "$upd" && git -C "$upd" hash-object openspec/changes/my-change/tasks.md 2>/dev/null || md5sum "$upd/openspec/changes/my-change/tasks.md")

rc=0
( cd "$upd" && node "$cli" update --no-systemd >/dev/null ) || rc=$?
check "update exits 0" [ "$rc" -eq 0 ]

changes_after=$(cd "$upd" && git -C "$upd" hash-object openspec/changes/my-change/tasks.md 2>/dev/null || md5sum "$upd/openspec/changes/my-change/tasks.md")
check "update leaves openspec/changes untouched" [ "$changes_before" = "$changes_after" ]
check "update leaves openspec/project.md untouched" grep -q "Custom purpose." "$upd/openspec/project.md"

new_name=$(node -e "process.stdout.write(require('$upd/.specforge/config.json').name)")
check "update keeps config name" [ "$new_name" = "my-custom-name" ]
new_ver=$(node -e "process.stdout.write(require('$upd/.specforge/config.json').specforge_version)")
check "update bumps recorded version" [ "$new_ver" != "0.0.1" ]

# update before init is refused
bare="$work/bare"; mkdir -p "$bare"; git -C "$bare" init -q
rc=0
( cd "$bare" && node "$cli" update >/dev/null 2>&1 ) || rc=$?
check "update before init is refused" [ "$rc" -ne 0 ]

# re-running init over an install is idempotent, not an error
rc=0
( cd "$upd" && node "$cli" init --no-beads --no-systemd >/dev/null 2>&1 ) || rc=$?
check "init over an existing install succeeds (idempotent)" [ "$rc" -eq 0 ]
check "re-init keeps custom config name" [ "$(node -e "process.stdout.write(require('$upd/.specforge/config.json').name)")" = "my-custom-name" ]

# --- not a git repo ------------------------------------------------------
plain="$work/plain"
mkdir -p "$plain"
rc=0
( cd "$plain" && node "$cli" init --no-beads >/dev/null 2>&1 ) || rc=$?
check "refuses outside a git repo" [ "$rc" -ne 0 ]

if [[ $fail -ne 0 ]]; then
  echo "installer CLI checks failed" >&2
  exit 1
fi
echo "all installer CLI checks passed"
