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
check "tool bridge installed"      test -f "$repo/scripts/nogg"
check "install-hooks installed"    test -f "$repo/scripts/install-hooks"
check "boundary hook installed"    test -f "$repo/scripts/hooks/pre-tool-use-openspec-guard"
check "bridge is executable"       test -x "$repo/scripts/nogg"
check "skills copied"              test -f "$repo/.agents/skills/openspec-propose/SKILL.md"
check "all Claude agents installed" diff -qr "$root/.claude/agents" "$repo/.claude/agents"
check "all Claude commands installed" diff -qr "$root/.claude/commands" "$repo/.claude/commands"
check "launch profiles shipped"    test -f "$repo/.nogging/launch-profiles/restricted.json"
check "launch profiles ship trusted" test -f "$repo/.nogging/launch-profiles/trusted.json"
check "launch profiles ship codex fragments" test -f "$repo/.nogging/launch-profiles/restricted.codex.toml"
check "launch profiles ship trusted codex fragment" test -f "$repo/.nogging/launch-profiles/trusted.codex.toml"
check "launch profiles ship pi fragments" test -f "$repo/.nogging/launch-profiles/restricted.pi.toml"
check "launch profiles ship trusted pi fragment" test -f "$repo/.nogging/launch-profiles/trusted.pi.toml"
check "pi guard extension installed" test -f "$repo/.pi/extensions/specforge-guard.ts"
check "pi prompt plan.md installed"    test -f "$repo/.pi/prompts/plan.md"
check "pi prompt discovery-review.md installed" test -f "$repo/.pi/prompts/discovery-review.md"
check "pi prompt sync-now.md installed" test -f "$repo/.pi/prompts/sync-now.md"
check "launch prompts shipped"     test -f "$repo/.nogging/launch-prompts/autonomous.md"
check "reference docs under docs/nogging" test -f "$repo/docs/nogging/architecture.md"
check "codex guide under docs/nogging" test -f "$repo/docs/nogging/using-with-codex.md"
check "codex execpolicy floor installed" test -f "$repo/.codex/rules/specforge.rules"
check "codex floor keeps the always-on classes" \
  grep -Eq 'pattern=\["sudo"\]' "$repo/.codex/rules/specforge.rules"
check "codex floor keeps mkfs + variants" \
  grep -q 'mkfs.ext4' "$repo/.codex/rules/specforge.rules"
check "codex floor keeps the network-fetch classes" \
  grep -Eq 'pattern=\["curl"\]' "$repo/.codex/rules/specforge.rules"
check "codex floor no longer carries a git push rule (restricted-profile / sandbox concern)" \
  bash -c "! grep -Eq '^[[:space:]]*(prefix|regex)_rule.*push' '$repo/.codex/rules/specforge.rules'"
check "codex prompt plan.md installed"    test -f "$repo/.codex/prompts/plan.md"
check "codex prompt discovery-review.md installed" test -f "$repo/.codex/prompts/discovery-review.md"
check "codex prompt sync-now.md installed" test -f "$repo/.codex/prompts/sync-now.md"
check "AGENTS.md carries a Tool notes section" grep -q 'Tool notes' "$repo/AGENTS.md"
check "AGENTS.md Tool notes labels Claude Code"  grep -q 'Claude Code' "$repo/AGENTS.md"
check "AGENTS.md Tool notes labels Codex"        grep -q 'Codex' "$repo/AGENTS.md"
check "AGENTS.md Tool notes labels Pi"  grep -q '.pi/extensions/specforge-guard.ts' "$repo/AGENTS.md"
check "openspec scaffold written"  test -f "$repo/openspec/config.yaml"
check "project.md scaffold written" test -f "$repo/openspec/project.md"
check "config.json written"        test -f "$repo/.nogging/config.json"

name=$(node -e "process.stdout.write(require('$repo/.nogging/config.json').name)")
check "config name is repo basename" [ "$name" = "fresh" ]
ver=$(node -e "process.stdout.write(String(require('$repo/.nogging/config.json').nogging_version||''))")
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
      bash -c "grep -q 'Nogging is ready' <<< \"\$0\"" "$ready_out"
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
  bash -c "grep -q 'Nogging is \(ready\|installed but not ready\)' <<< \"\$0\"" "$verd_out"

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
check "gitignore adds locks line once" [ "$(grep -cx '.nogging/locks/' "$merged/.gitignore")" = "1" ]

check "CLAUDE.md keeps existing content" grep -q "Existing notes." "$merged/CLAUDE.md"
check "CLAUDE.md has one begin marker" [ "$(grep -c 'specforge:begin' "$merged/CLAUDE.md")" = "1" ]
check "CLAUDE.md has one end marker" [ "$(grep -c 'specforge:end' "$merged/CLAUDE.md")" = "1" ]
check "AGENTS.md created with block" grep -q "specforge:begin" "$merged/AGENTS.md"

# --- mergeCodex preserves a bd-written .codex/hooks.json ------------------
codexrepo="$work/codexmerge"
mkdir -p "$codexrepo/.codex"
git -C "$codexrepo" init -q
cat > "$codexrepo/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup|resume|clear",
        "hooks": [ { "type": "command", "command": "bd codex-hook SessionStart" } ] }
    ]
  }
}
JSON
printf '[features]\nhooks = true\n' > "$codexrepo/.codex/config.toml"
hooks_before=$(md5sum < "$codexrepo/.codex/hooks.json")
toml_before=$(md5sum < "$codexrepo/.codex/config.toml")

( cd "$codexrepo" && node "$cli" init --no-beads --no-systemd >/dev/null )
( cd "$codexrepo" && node "$cli" init --no-beads --no-systemd >/dev/null )

bd_entries=$(node -e "
  const h = require('$codexrepo/.codex/hooks.json');
  const ss = (h.hooks && h.hooks.SessionStart) || [];
  let n = 0;
  for (const e of ss) for (const x of (e.hooks||[])) if ((x.command||'') === 'bd codex-hook SessionStart') n++;
  process.stdout.write(String(n));
")
check "mergeCodex keeps the bd SessionStart entry exactly once" [ "$bd_entries" = "1" ]
check "mergeCodex does not rewrite a valid .codex/hooks.json" \
  [ "$hooks_before" = "$(md5sum < "$codexrepo/.codex/hooks.json")" ]
check "mergeCodex never touches .codex/config.toml" \
  [ "$toml_before" = "$(md5sum < "$codexrepo/.codex/config.toml")" ]
check "mergeCodex still installs the rules floor alongside" \
  test -f "$codexrepo/.codex/rules/specforge.rules"

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
check "re-init + update preserve Claude agents byte-for-byte" diff -qr "$root/.claude/agents" "$idem/.claude/agents"
check "re-init + update preserve Claude commands byte-for-byte" diff -qr "$root/.claude/commands" "$idem/.claude/commands"

# --- scaffold files are preserved -----------------------------------------
repo2="$work/existing"
mkdir -p "$repo2/openspec"
git -C "$repo2" init -q
printf '# Kept project doc\n' > "$repo2/openspec/project.md"
( cd "$repo2" && node "$cli" init --no-beads >/dev/null )
check "existing project.md untouched" grep -q "Kept project doc" "$repo2/openspec/project.md"

# --- rendered systemd unit ---------------------------------------------
unit=$(find "$repo/systemd" -name 'nogg-sync-*.service')
check "systemd service rendered" test -n "$unit"
check "service targets the repo" grep -qx "WorkingDirectory=$repo" "$unit"
check "service ExecStart is absolute" grep -qx "ExecStart=$repo/scripts/nogg sync" "$unit"
check "unit filename carries the slug" bash -c "[[ '$(basename "$unit")' == nogg-sync-fresh.service ]]"
tunit=$(find "$repo/systemd" -name 'nogg-sync-*.timer')
check "timer binds the slugged service" grep -qx "Unit=nogg-sync-fresh.service" "$tunit"

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
printf 'stale agent\n' > "$upd/.claude/agents/architect.md"
printf 'stale command\n' > "$upd/.claude/commands/plan.md"
mkdir -p "$upd/openspec/changes/my-change"
printf '# Tasks\n\n- [ ] TASK-X-001 do a thing\n' > "$upd/openspec/changes/my-change/tasks.md"
printf '# My project\n\nCustom purpose.\n' > "$upd/openspec/project.md"
node -e "
  const f='$upd/.nogging/config.json'; const d=require(f);
  d.nogging_version='0.0.1'; d.name='my-custom-name';
  require('fs').writeFileSync(f, JSON.stringify(d,null,2)+'\n');
"
changes_before=$(cd "$upd" && git -C "$upd" hash-object openspec/changes/my-change/tasks.md 2>/dev/null || md5sum "$upd/openspec/changes/my-change/tasks.md")

rc=0
( cd "$upd" && node "$cli" update --no-systemd >/dev/null ) || rc=$?
check "update exits 0" [ "$rc" -eq 0 ]

changes_after=$(cd "$upd" && git -C "$upd" hash-object openspec/changes/my-change/tasks.md 2>/dev/null || md5sum "$upd/openspec/changes/my-change/tasks.md")
check "update leaves openspec/changes untouched" [ "$changes_before" = "$changes_after" ]
check "update leaves openspec/project.md untouched" grep -q "Custom purpose." "$upd/openspec/project.md"
check "update refreshes a stale Claude agent" cmp -s "$root/.claude/agents/architect.md" "$upd/.claude/agents/architect.md"
check "update refreshes a stale Claude command" cmp -s "$root/.claude/commands/plan.md" "$upd/.claude/commands/plan.md"

new_name=$(node -e "process.stdout.write(require('$upd/.nogging/config.json').name)")
check "update keeps config name" [ "$new_name" = "my-custom-name" ]
new_ver=$(node -e "process.stdout.write(require('$upd/.nogging/config.json').nogging_version)")
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
check "re-init keeps custom config name" [ "$(node -e "process.stdout.write(require('$upd/.nogging/config.json').name)")" = "my-custom-name" ]

# --- not a git repo ------------------------------------------------------
plain="$work/plain"
mkdir -p "$plain"
rc=0
( cd "$plain" && node "$cli" init --no-beads >/dev/null 2>&1 ) || rc=$?
check "refuses outside a git repo" [ "$rc" -ne 0 ]

# --- install from a files-filtered package (what `npx github:` actually ships) --
# A local `node bin/cli.js init` copies straight from the checkout, so a manifest
# path missing from package.json "files" still works locally but breaks the real
# npx install. Pack the package and install from the extracted copy.
if command -v npm >/dev/null 2>&1; then
  pack="$work/pack"; mkdir -p "$pack"
  if ( cd "$root" && npm pack --pack-destination "$pack" >/dev/null 2>&1 ); then
    tgz=$(find "$pack" -name '*.tgz' | head -1)
    tar -xzf "$tgz" -C "$pack"
    pkg="$pack/package"
    packrepo="$work/packinstall"; mkdir -p "$packrepo"; git -C "$packrepo" init -q
    rc=0
    ( cd "$packrepo" && node "$pkg/bin/cli.js" init --no-beads --no-systemd >/dev/null 2>&1 ) || rc=$?
    check "packed install succeeds"                 [ "$rc" -eq 0 ]
    check "packed install ships the tool bridge"    test -f "$packrepo/scripts/nogg"
    check "packed install ships all Claude agents"  diff -qr "$root/.claude/agents" "$packrepo/.claude/agents"
    check "packed install ships all Claude commands" diff -qr "$root/.claude/commands" "$packrepo/.claude/commands"
    check "packed install ships launch profiles"    test -f "$packrepo/.nogging/launch-profiles/restricted.json"
    check "packed install ships codex fragments"    test -f "$packrepo/.nogging/launch-profiles/restricted.codex.toml"
    check "packed install ships trusted codex fragment" test -f "$packrepo/.nogging/launch-profiles/trusted.codex.toml"
    check "packed install ships pi fragments"    test -f "$packrepo/.nogging/launch-profiles/restricted.pi.toml"
    check "packed install ships trusted pi fragment" test -f "$packrepo/.nogging/launch-profiles/trusted.pi.toml"
    check "packed install ships the pi guard extension" test -f "$packrepo/.pi/extensions/specforge-guard.ts"
    check "packed install ships pi prompt plan.md" test -f "$packrepo/.pi/prompts/plan.md"
    check "packed install ships pi prompt discovery-review.md" test -f "$packrepo/.pi/prompts/discovery-review.md"
    check "packed install ships pi prompt sync-now.md" test -f "$packrepo/.pi/prompts/sync-now.md"
    check "packed install ships launch prompts"     test -f "$packrepo/.nogging/launch-prompts/no-autonomous-claim.md"
    check "packed install ships the orchestrator profile" test -f "$packrepo/.nogging/launch-profiles/orchestrator.json"
    check "packed install ships the orchestrator prompt"  test -f "$packrepo/.nogging/launch-prompts/orchestrator.md"
    check "packed install ships the orchestrator unit template" \
      test -f "$pkg/templates/systemd/nogg-orchestrator.service.tmpl"
    # A packed install WITH systemd renders the per-repo orchestrator unit.
    orcrepo="$work/packorc"; mkdir -p "$orcrepo"; git -C "$orcrepo" init -q
    orc_out=$( cd "$orcrepo" && node "$pkg/bin/cli.js" init --no-beads 2>&1 ) || true
    orc_unit=$(find "$orcrepo/systemd" -name 'nogg-orchestrator-*.service' 2>/dev/null | head -1)
    check "packed install renders the orchestrator unit" test -n "$orc_unit"
    check "orchestrator unit ExecStart calls orchestrator run" \
      grep -qx "ExecStart=$orcrepo/scripts/nogg orchestrator run" "$orc_unit"
    check "orchestrator unit restarts always"  grep -qx "Restart=always" "$orc_unit"
    check "orchestrator unit targets default.target" grep -qx "WantedBy=default.target" "$orc_unit"
    check "init prints the orchestrator enable line" \
      bash -c "printf '%s' \"\$1\" | grep -q 'nogg-orchestrator-'" _ "$orc_out"
    check "init prints the loginctl enable-linger hint" \
      bash -c "printf '%s' \"\$1\" | grep -q 'loginctl enable-linger'" _ "$orc_out"
    check "packed install ships the skills"         test -f "$packrepo/.agents/skills/openspec-propose/SKILL.md"
    check "packed install ships the codex rules floor" test -f "$packrepo/.codex/rules/specforge.rules"
    check "packed install ships codex prompt plan.md" test -f "$packrepo/.codex/prompts/plan.md"
    check "packed install ships codex prompt discovery-review.md" test -f "$packrepo/.codex/prompts/discovery-review.md"
    check "packed install ships codex prompt sync-now.md" test -f "$packrepo/.codex/prompts/sync-now.md"
    check "packed install AGENTS.md has Tool notes"  grep -q 'Tool notes' "$packrepo/AGENTS.md"
    check "packed install AGENTS.md labels Pi"       grep -q '.pi/extensions/specforge-guard.ts' "$packrepo/AGENTS.md"
  else
    echo "ok   - packed-install check skipped (npm pack failed)"
  fi
else
  echo "ok   - packed-install check skipped (npm not installed)"
fi

if [[ $fail -ne 0 ]]; then
  echo "installer CLI checks failed" >&2
  exit 1
fi
echo "all installer CLI checks passed"
