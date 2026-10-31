#!/usr/bin/env bash
# Focused checks for the installer CLI (bin/cli.js).
#
# Node is required to exercise the CLI. The repository test runner is otherwise
# offline and bash-only, so when node is absent this test skips with a PASS
# rather than failing the suite.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$root/bin/cli.js"
# The nested consumers below must skip the shipped self-tests by default.
unset NOGG_SELFTEST

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

expected_version=$(node -p "require('$root/package.json').version")
check "version subcommand matches package" \
  test "$(node "$cli" version)" = "$expected_version"
check "--version matches package" \
  test "$(node "$cli" --version)" = "$expected_version"

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
check "lead-launch guard hook installed" test -f "$repo/scripts/hooks/pre-tool-use-lead-launch-guard"
check "lead-launch guard hook is executable" test -x "$repo/scripts/hooks/pre-tool-use-lead-launch-guard"
check "bridge is executable"       test -x "$repo/scripts/nogg"
check "skills copied"              test -f "$repo/.agents/skills/openspec-propose/SKILL.md"
check "all Claude agents installed" diff -qr "$root/.claude/agents" "$repo/.claude/agents"
check "all Claude commands installed" diff -qr "$root/.claude/commands" "$repo/.claude/commands"
check "orchestrator permissions example template shipped" test -f "$repo/templates/claude/orchestrator-permissions.example.json"
check "init never injects orchestrator permissions template into settings" bash -c "! grep -q 'git push --force' '$repo/.claude/settings.json'"
check "launch profiles shipped"    test -f "$repo/.nogging/launch-profiles/restricted.json"
check "launch profiles ship trusted" test -f "$repo/.nogging/launch-profiles/trusted.json"
check "launch profiles ship codex fragments" test -f "$repo/.nogging/launch-profiles/restricted.codex.toml"
check "launch profiles ship trusted codex fragment" test -f "$repo/.nogging/launch-profiles/trusted.codex.toml"
check "launch profiles ship pi fragments" test -f "$repo/.nogging/launch-profiles/restricted.pi.toml"
check "launch profiles ship trusted pi fragment" test -f "$repo/.nogging/launch-profiles/trusted.pi.toml"
check "pi guard extension installed" test -f "$repo/.pi/extensions/nogging-guard.ts"
check "pi prompt plan.md installed"    test -f "$repo/.pi/prompts/plan.md"
check "pi prompt discovery-review.md installed" test -f "$repo/.pi/prompts/discovery-review.md"
check "pi prompt sync-now.md installed" test -f "$repo/.pi/prompts/sync-now.md"
check "pi glm-usage extension installed" test -f "$repo/.pi/nogging/extensions/glm-usage/index.ts"
check "pi extension home README installed" test -f "$repo/.pi/nogging/README.md"
check "init scaffolds pi_extensions empty and enables nothing" \
  node -e "const c=require('$repo/.nogging/config.json'); process.exit(Array.isArray(c.pi_extensions) && c.pi_extensions.length===0 ? 0 : 1)"
check "launch prompts shipped"     test -f "$repo/.nogging/launch-prompts/autonomous.md"
check "planning prompt shipped" test -f "$repo/.nogging/launch-prompts/planning.md"
check "reference docs under docs/nogging" test -f "$repo/docs/nogging/architecture.md"
check "codex guide under docs/nogging" test -f "$repo/docs/nogging/using-with-codex.md"
check "pi guide under docs/nogging" test -f "$repo/docs/nogging/using-with-pi.md"
check "security guide under docs/nogging" test -f "$repo/docs/nogging/security-model.md"
check "compatibility guide under docs/nogging" test -f "$repo/docs/nogging/compatibility.md"
check "codex execpolicy floor installed" test -f "$repo/.codex/rules/nogging.rules"
check "codex floor keeps the always-on classes" \
  grep -Eq 'pattern=\["sudo"\]' "$repo/.codex/rules/nogging.rules"
check "codex floor keeps mkfs + variants" \
  grep -q 'mkfs.ext4' "$repo/.codex/rules/nogging.rules"
check "codex floor keeps the network-fetch classes" \
  grep -Eq 'pattern=\["curl"\]' "$repo/.codex/rules/nogging.rules"
check "codex floor no longer carries a git push rule (restricted-profile / sandbox concern)" \
  bash -c "! grep -Eq '^[[:space:]]*(prefix|regex)_rule.*push' '$repo/.codex/rules/nogging.rules'"
check "codex prompt plan.md installed"    test -f "$repo/.codex/prompts/plan.md"
check "codex prompt discovery-review.md installed" test -f "$repo/.codex/prompts/discovery-review.md"
check "codex prompt sync-now.md installed" test -f "$repo/.codex/prompts/sync-now.md"
check "AGENTS.md carries a Tool notes section" grep -q 'Tool notes' "$repo/AGENTS.md"
check "AGENTS.md Tool notes labels Claude Code"  grep -q 'Claude Code' "$repo/AGENTS.md"
check "AGENTS.md Tool notes labels Codex"        grep -q 'Codex' "$repo/AGENTS.md"
check "AGENTS.md Tool notes labels Pi"  grep -q '.pi/extensions/nogging-guard.ts' "$repo/AGENTS.md"
check "openspec scaffold written"  test -f "$repo/openspec/config.yaml"
check "project.md scaffold written" test -f "$repo/openspec/project.md"
check "config.json written"        test -f "$repo/.nogging/config.json"

# A consumer's scripts/test runs its own tests, not the shipped self-tests the
# installed manifest records (NOGG_SELFTEST=1 opts in; see selftest-scope.test.sh).
shipped_tests=$(node -e '
  const m = require(process.argv[1]);
  console.log(m.verbatim.filter((p) => p.endsWith(".test.sh")).sort().join("\n"));
' "$root/bin/lib/manifest.js")
shipped_count=$(grep -c . <<<"$shipped_tests")
recorded_tests=$(grep -o '"[^"]*\.test\.sh"' "$repo/.nogging/installed-manifest.json" | tr -d '"' | sort)
check "init records every shipped self-test in the installed manifest" \
  [ "$shipped_count" -gt 0 -a "$recorded_tests" = "$shipped_tests" ]
consumer_runner_checks() { # <phase> <repo>
  local out
  printf '#!/usr/bin/env bash\necho own-ran\n' > "$2/scripts/own.test.sh"
  local rc=0
  out=$("$2/scripts/test" 2>&1) || rc=$?
  check "$1: consumer scripts/test exits 0" [ "$rc" -eq 0 ]
  check "$1: consumer scripts/test runs the project's own test" grep -q "^PASS - scripts/own.test.sh" <<<"$out"
  check "$1: consumer scripts/test skips every shipped self-test" \
    grep -qF "skipped $shipped_count shipped Nogging self-test(s)" <<<"$out"
  check "$1: nogg.test.sh does not run in a consumer" bash -c '! grep -q "=== scripts/nogg.test.sh" <<<"$0"' "$out"
  rm "$2/scripts/own.test.sh"
}
consumer_runner_checks init "$repo"

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

# --- TASK-DAL-002/004: the Bash-matcher Lead-launch guard is a sibling entry,
# inserted exactly once, leaving the Edit|Write guard entry untouched -------
launch_guard_count=$(node -e "
  const s = require('$merged/.claude/settings.json');
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  let n = 0;
  for (const e of pre) for (const h of (e.hooks||[])) if ((h.command||'').includes('pre-tool-use-lead-launch-guard')) n++;
  process.stdout.write(String(n));
")
check "lead-launch guard hook added exactly once" [ "$launch_guard_count" = "1" ]

launch_guard_matcher=$(node -e "
  const s = require('$merged/.claude/settings.json');
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  const entry = pre.find(e => (e.hooks||[]).some(h => (h.command||'').includes('pre-tool-use-lead-launch-guard')));
  process.stdout.write((entry && entry.matcher) || '');
")
check "lead-launch guard entry matches Bash" [ "$launch_guard_matcher" = "Bash" ]

openspec_guard_matcher=$(node -e "
  const s = require('$merged/.claude/settings.json');
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  const entry = pre.find(e => (e.hooks||[]).some(h => (h.command||'').includes('pre-tool-use-openspec-guard')));
  process.stdout.write((entry && entry.matcher) || '');
")
check "openspec guard entry still matches Edit|Write (untouched)" [ "$openspec_guard_matcher" = "Edit|Write" ]

pre_tool_use_count=$(node -e "
  const s = require('$merged/.claude/settings.json');
  process.stdout.write(String(((s.hooks && s.hooks.PreToolUse) || []).length));
")
check "exactly two PreToolUse entries after a second update run" [ "$pre_tool_use_count" = "2" ]

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
check "CLAUDE.md has one begin marker" [ "$(grep -c 'nogging:begin' "$merged/CLAUDE.md")" = "1" ]
check "CLAUDE.md has one end marker" [ "$(grep -c 'nogging:end' "$merged/CLAUDE.md")" = "1" ]
check "AGENTS.md created with block" grep -q "nogging:begin" "$merged/AGENTS.md"

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
  test -f "$codexrepo/.codex/rules/nogging.rules"

# --- strict idempotency: commit, re-run, expect no tracked diff ----------
idem="$work/idempotent"
mkdir -p "$idem"
git -C "$idem" init -q
git -C "$idem" config user.email t@example.com
git -C "$idem" config user.name test
( cd "$idem" && node "$cli" init --no-beads >/dev/null )
git -C "$idem" add -A
git -C "$idem" -c core.hooksPath=/dev/null commit -q -m "install nogg"
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

lsvc="$repo/systemd/nogg-loops-fresh.service"
ltim="$repo/systemd/nogg-loops-fresh.timer"
check "loop service rendered" test -f "$lsvc"
check "loop service is a oneshot" grep -qx "Type=oneshot" "$lsvc"
check "loop service targets the repo" grep -qx "WorkingDirectory=$repo" "$lsvc"
check "loop service runs one tick" grep -qx "ExecStart=$repo/scripts/nogg loop tick" "$lsvc"
check "loop service leaves its sessions running" grep -qx "KillMode=process" "$lsvc"
check "loop service bounds a wedged tick" grep -qx "TimeoutStartSec=15min" "$lsvc"
check "loop timer rendered" test -f "$ltim"
check "loop timer fires every minute" grep -qx "OnCalendar=minutely" "$ltim"
check "loop timer has no catch-up" grep -qx "Persistent=false" "$ltim"
check "loop timer binds the slugged service" grep -qx "Unit=nogg-loops-fresh.service" "$ltim"
check "loop timer is enable-able" grep -qx "WantedBy=timers.target" "$ltim"

# A repository named after a unit keeps its units' next steps apart.
named="$work/orchestrator"
mkdir -p "$named"; git -C "$named" init -q
named_out=$( cd "$named" && node "$cli" init --no-beads 2>&1 ) || true
check "a repo named orchestrator gets one orchestrator step" \
  test "$(grep -c 'Enable the always-on Orchestration Agent' <<<"$named_out")" -eq 1

# --- --no-systemd -----------------------------------------------------
nos="$work/nosystemd"
mkdir -p "$nos"; git -C "$nos" init -q
( cd "$nos" && node "$cli" init --no-beads --no-systemd >/dev/null )
check "--no-systemd skips the unit" [ ! -d "$nos/systemd" ]
check "--no-systemd still installs the loop prompt" test -f "$nos/.nogging/launch-prompts/loop.md"
check "--no-systemd still installs the loop modules" test -f "$nos/scripts/lib/loop_runner.py"
check "--no-systemd still installs the loop guide" test -f "$nos/docs/nogging/scheduled-loops.md"

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
printf 'stale extension\n' > "$upd/.pi/nogging/extensions/glm-usage/index.ts"
# Record the simulated old release baseline so update exercises clean refreshes.
node - "$upd" "$root" <<'NODE'
const path = require('path');
const target = process.argv[2];
const store = require(path.join(process.argv[3], 'bin/lib/manifest-store'));
const installed = store.readManifest(target);
for (const rel of ['.claude/agents/architect.md', '.claude/commands/plan.md',
                   '.pi/nogging/extensions/glm-usage/index.ts']) {
  installed.files[rel] = store.hashFile(path.join(target, rel));
}
store.writeManifest(target, installed);
NODE
mkdir -p "$upd/openspec/changes/my-change"
printf '# Tasks\n\n- [ ] TASK-X-001 do a thing\n' > "$upd/openspec/changes/my-change/tasks.md"
printf '# My project\n\nCustom purpose.\n' > "$upd/openspec/project.md"
node -e "
  const f='$upd/.nogging/config.json'; const d=require(f);
  d.nogging_version='0.0.1'; d.name='my-custom-name'; d.pi_extensions=['glm-usage'];
  require('fs').writeFileSync(f, JSON.stringify(d,null,2)+'\n');
"
changes_before=$(cd "$upd" && git -C "$upd" hash-object openspec/changes/my-change/tasks.md 2>/dev/null || md5sum "$upd/openspec/changes/my-change/tasks.md")

mkdir -p "$upd/.nogging/loops"
printf '{"schema_version":1,"timezone":"UTC","loops":{}}\n' > "$upd/.nogging/loops.json"
printf 'Keep this prompt.\n' > "$upd/.nogging/loops/night-work.md"
loops_before=$(cat "$upd/.nogging/loops.json" "$upd/.nogging/loops/night-work.md" | sha256sum)

rc=0
( cd "$upd" && node "$cli" update --no-systemd >/dev/null ) || rc=$?
check "update exits 0" [ "$rc" -eq 0 ]
loops_after=$(cat "$upd/.nogging/loops.json" "$upd/.nogging/loops/night-work.md" | sha256sum)
check "update leaves the loop definitions and prompts unchanged" [ "$loops_before" = "$loops_after" ]

changes_after=$(cd "$upd" && git -C "$upd" hash-object openspec/changes/my-change/tasks.md 2>/dev/null || md5sum "$upd/openspec/changes/my-change/tasks.md")
check "update leaves openspec/changes untouched" [ "$changes_before" = "$changes_after" ]
check "update leaves openspec/project.md untouched" grep -q "Custom purpose." "$upd/openspec/project.md"
check "update refreshes a stale Claude agent" cmp -s "$root/.claude/agents/architect.md" "$upd/.claude/agents/architect.md"
check "update refreshes a stale Claude command" cmp -s "$root/.claude/commands/plan.md" "$upd/.claude/commands/plan.md"
check "update refreshes a stale Pi extension" cmp -s "$root/.pi/nogging/extensions/glm-usage/index.ts" "$upd/.pi/nogging/extensions/glm-usage/index.ts"
check "update keeps an enabled pi_extensions list" \
  node -e "process.exit(JSON.stringify(require('$upd/.nogging/config.json').pi_extensions)==='[\"glm-usage\"]' ? 0 : 1)"
consumer_runner_checks update "$upd"

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
    check "packed install ships the pi guard extension" test -f "$packrepo/.pi/extensions/nogging-guard.ts"
    check "packed install ships pi prompt plan.md" test -f "$packrepo/.pi/prompts/plan.md"
    check "packed install ships pi prompt discovery-review.md" test -f "$packrepo/.pi/prompts/discovery-review.md"
    check "packed install ships pi prompt sync-now.md" test -f "$packrepo/.pi/prompts/sync-now.md"
    check "packed install ships the Pi extension home" diff -qr "$root/.pi/nogging" "$packrepo/.pi/nogging"
    check "packed install enables no Pi extension" \
      node -e "const c=require('$packrepo/.nogging/config.json'); process.exit(Array.isArray(c.pi_extensions) && c.pi_extensions.length===0 ? 0 : 1)"
    check "packed install ships launch prompts"     test -f "$packrepo/.nogging/launch-prompts/no-autonomous-claim.md"
    check "packed install ships planning prompt" test -f "$packrepo/.nogging/launch-prompts/planning.md"
    check "packed install ships the Pi guide"       test -f "$packrepo/docs/nogging/using-with-pi.md"
    check "packed install ships the security guide" test -f "$packrepo/docs/nogging/security-model.md"
    check "packed install ships the compatibility guide" test -f "$packrepo/docs/nogging/compatibility.md"
    check "packed install ships the orchestrator profile" test -f "$packrepo/.nogging/launch-profiles/orchestrator.json"
    check "packed install ships the orchestrator prompt"  test -f "$packrepo/.nogging/launch-prompts/orchestrator.md"
    check "packed install ships the orchestrator permissions template" \
      test -f "$packrepo/templates/claude/orchestrator-permissions.example.json"
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
    check "packed install ships the codex rules floor" test -f "$packrepo/.codex/rules/nogging.rules"
    check "packed install ships codex prompt plan.md" test -f "$packrepo/.codex/prompts/plan.md"
    check "packed install ships codex prompt discovery-review.md" test -f "$packrepo/.codex/prompts/discovery-review.md"
    check "packed install ships codex prompt sync-now.md" test -f "$packrepo/.codex/prompts/sync-now.md"
    check "packed install AGENTS.md has Tool notes"  grep -q 'Tool notes' "$packrepo/AGENTS.md"
    check "packed install AGENTS.md labels Pi"       grep -q '.pi/extensions/nogging-guard.ts' "$packrepo/AGENTS.md"

    # --- session wake: dispatch is on in a default packed consumer --------------
    wake="$work/packwake"; wakebin="$work/wakebin"; wakehome="$work/wakehome"
    mkdir -p "$wake" "$wakebin" "$wakehome/.codex"; git -C "$wake" init -q -b develop
    printf '{"hooks": {}}\n' > "$wakehome/.codex/hooks.json"
    printf 'model = "personal"\n' > "$wakehome/.codex/config.toml"
    personal() { cat "$wakehome/.codex/hooks.json" "$wakehome/.codex/config.toml" | sha256sum; }
    personal_before=$(personal)
    in_wake() { ( cd "$wake" && env -i HOME="$wakehome" PATH="$wakebin:$PATH" TMUX_TMPDIR="${TMUX_TMPDIR:-}" \
      NOGG_TEST_ARGS_DIR="$wakebin" NOGGING_ROOT="$wake" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid "$@" ); }
    wake_block() { # <python expression over `block`, a statement>: edit the config's dispatch block
      python3 - "$wake/.nogging/config.json" "$1" <<'PY'
import json, sys
path, change = sys.argv[1:3]
config = json.load(open(path))
block = config["session_dispatch"]
exec(change)
json.dump(config, open(path, "w"), indent=2)
PY
    }
    wake_key() { node -p "JSON.stringify(require('$wake/.nogging/config.json').session_dispatch.$1)"; }
    printf '#!/bin/sh\necho not-found\nexit 1\n' > "$wakebin/systemctl"
    printf '#!/bin/sh\necho "[]"\n' > "$wakebin/gh"
    printf '#!/bin/sh\necho "[{\\"id\\":\\"B1\\",\\"status\\":\\"in_progress\\"}]"\n' > "$wakebin/bd"
    chmod +x "$wakebin/systemctl" "$wakebin/gh" "$wakebin/bd"
    in_wake node "$pkg/bin/cli.js" init --no-beads --no-systemd >/dev/null 2>&1
    for shipped in scripts/lib/session_signals.py scripts/lib/session_dispatch.py scripts/lib/session_pause.py \
                   scripts/lib/session_warm.py .pi/extensions/nogging-lifecycle.ts docs/nogging/session-wake.md; do
      check "packed consumer has $shipped" test -f "$wake/$shipped"
    done
    check "packed consumer: dispatch is on" [ "$(wake_key enabled)" = "true" ]
    check "packed consumer: retire_merged is off" [ "$(wake_key retire_merged)" = "false" ]
    check "packed guide opens on the default" grep -q '^## Dispatch is on by default$' "$wake/docs/nogging/session-wake.md"

    # With no orchestrator and no timer a pass exits 0, says nothing wrong and holds the digest.
    rc=0
    in_wake ./scripts/nogg session dispatch --once >"$work/wake.out" 2>"$work/wake.err" || rc=$?
    check "no orchestrator: a pass exits 0" [ "$rc" -eq 0 ]
    check "no orchestrator: a pass prints no error" [ ! -s "$work/wake.err" ]
    held_queue="$wake/.nogging/state/dispatch/queue.json"
    python3 - "$held_queue" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
old = (datetime.now(timezone.utc) - timedelta(seconds=1000)).isoformat()
json.dump({"items": [{"key": "gone|error|m", "kind": "error", "session": "gone", "sticky": True, "reason": "held",
                      "next": "n", "created_at": old}]}, open(sys.argv[1], "w"))
PY
    in_wake ./scripts/nogg session dispatch --once >/dev/null 2>"$work/wake.err"
    in_wake ./scripts/nogg session dispatch --once >"$work/wake.out" 2>>"$work/wake.err"
    check "no orchestrator: the digest is held" grep -q 'held: orchestrator target-not-running' "$work/wake.out"
    check "no orchestrator: it is no error" [ ! -s "$work/wake.err" ]
    check "no orchestrator: the item stays" grep -q 'gone|error|m' "$held_queue"
    check "no orchestrator: the hold is logged once" \
      test "$(grep -c 'held: orchestrator' "$wake/.nogging/state/dispatch/dispatch.jsonl")" -eq 1
    doctor_out=$(in_wake ./scripts/nogg doctor 2>&1 || true)
    check "doctor: one NOTE for the missing orchestrator" \
      test "$(grep -c '^NOTE  dispatcher: no orchestrator session' <<<"$doctor_out")" -eq 1
    check "doctor: one NOTE for the missing timer" \
      test "$(grep -c '^NOTE  dispatcher: nothing fires a pass' <<<"$doctor_out")" -eq 1
    check "doctor: both name the switch" \
      test "$(grep -c 'session_dispatch.enabled: false. switches dispatch off' <<<"$doctor_out")" -eq 2
    check "doctor: no WARN or FAIL about dispatch" bash -c "! grep -Eiq '^(WARN|FAIL).*dispatch' <<<\"\$1\"" _ "$doctor_out"

    # The same install with a stub orchestrator nudges a Lead and delivers one digest.
    if command -v tmux >/dev/null 2>&1; then
      export TMUX_TMPDIR; TMUX_TMPDIR=$(mktemp -d /tmp/nogg-cli.XXXXXX)
      wake_sock="nogg-cli-$$"
      trap 'tmux -L "$wake_sock" kill-server 2>/dev/null || true; rm -rf "${work:?}" "${TMUX_TMPDIR:?}"' EXIT
      python3 - "$wake/.nogging/config.json" "$wake_sock" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config.update(session_tmux_socket=sys.argv[2], session_backend="tmux")
config["usage_gate"] = {"enabled": False}
json.dump(config, open(sys.argv[1], "w"), indent=2)
PY
      cat > "$wakebin/runtime.py" <<'PY'
import sys
rule = "─" * 80
def paint():
    print(rule + "\n❯ \n" + rule + "\n   ⏵⏵ bypass permissions on", flush=True)
print("stub agent started", flush=True)
paint()
for line in sys.stdin:
    with open(sys.argv[1], "a") as inbox:
        inbox.write(line)
    paint()
PY
      git init -q --bare -b develop "$work/wake-upstream.git"
      printf '.nogging/\n' > "$wake/.gitignore"
      in_wake git add .gitignore; in_wake git commit -qm init --no-verify
      in_wake git remote add origin "$work/wake-upstream.git"; in_wake git push -q --no-verify -u origin develop
      in_wake git worktree add -q -b feat/lead-1 "$work/wake-lead" develop
      in_wake git -C "$work/wake-lead" push -q --no-verify -u origin feat/lead-1
      echo wip > "$work/wake-lead/wip.txt"
      python3 - "$wake" "$work/wake-lead" <<'PY'
import json, pathlib, sys
root, tree = sys.argv[1:3]
sessions = pathlib.Path(root, ".nogging/state/sessions"); sessions.mkdir(parents=True, exist_ok=True)
worktrees = pathlib.Path(root, ".nogging/state/worktrees"); worktrees.mkdir(parents=True, exist_ok=True)
for name, role, bead in (("lead-1", "lead", "B1"), ("nogg-orchestrator-packwake", "orchestrator", None)):
    record = {"name": name, "role": role, "agent": "claude", "state": "running", "working_dir": root,
              "launch_prompt": "autonomous", "kickoff_sent_at": "2026-10-30T00:00:00+00:00",
              "started_at": "2026-10-30T00:00:00+00:00", "log_path": root + "/" + name + ".log"}
    if bead:
        record["bead_id"] = bead
    json.dump(record, (sessions / (name + ".json")).open("w"))
json.dump({"bead_id": "B1", "path": tree}, (worktrees / "implementation--b1.json").open("w"))
PY
      for wake_session in lead-1 nogg-orchestrator-packwake; do
        in_wake tmux -L "$wake_sock" new-session -d -s "$wake_session" -x 100 -y 12 \
          "python3 $wakebin/runtime.py $work/$wake_session.inbox"
        for _ in $(seq 1 50); do
          tmux -L "$wake_sock" capture-pane -p -t "$wake_session" 2>/dev/null | grep -q '❯' && break; sleep 0.1
        done
      done
      in_wake ./scripts/nogg session dispatch --once >/dev/null
      python3 - "$wake/.nogging/state/dispatch/state.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
state = json.load(open(sys.argv[1]))
for session in state["sessions"].values():
    session["since"] = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
json.dump(state, open(sys.argv[1], "w"))
PY
      in_wake ./scripts/nogg session dispatch --once >/dev/null
      for _ in $(seq 1 50); do
        [ -s "$work/lead-1.inbox" ] && [ -s "$work/nogg-orchestrator-packwake.inbox" ] && break; sleep 0.1
      done
      check "stub orchestrator: the Lead is nudged" grep -q 'uncommitted changes' "$work/lead-1.inbox"
      check "stub orchestrator: one digest arrives" \
        test "$(grep -c '^\[nogg wake ' "$work/nogg-orchestrator-packwake.inbox")" -eq 1
      tmux -L "$wake_sock" kill-server 2>/dev/null || true
    else
      echo "ok   - stub orchestrator check skipped (tmux not installed)"
    fi

    # `update` keeps a choice, says so only when there is none, and leaves a pause alone.
    update_wake() { in_wake node "$pkg/bin/cli.js" update --no-systemd 2>&1; }
    wake_block 'block.update(enabled=False); block["wake"]["quiet_hours"] = ["22:00-07:00"]'
    in_wake ./scripts/nogg pause --days 1 >/dev/null
    pause_before=$(sha256sum < "$wake/.nogging/state/pause.json")
    update_out=$(update_wake)
    check "update keeps an explicit false" [ "$(wake_key enabled)" = "false" ]
    check "update keeps quiet hours" [ "$(wake_key wake.quiet_hours)" = '["22:00-07:00"]' ]
    check "update with a choice prints no on-by-default line" bash -c "! grep -q 'Session dispatch is on' <<<\"\$1\"" _ "$update_out"
    check "update leaves a pause alone" [ "$pause_before" = "$(sha256sum < "$wake/.nogging/state/pause.json")" ]
    check "an explicit false: a pass is disabled" \
      bash -c 'grep -q "is disabled" <<<"$1"' _ "$(in_wake ./scripts/nogg session dispatch --once 2>&1)"
    check "doctor: an explicit false has neither NOTE" \
      bash -c '! grep -Eq "no orchestrator session|nothing fires a pass" <<<"$1"' _ "$(in_wake ./scripts/nogg doctor 2>&1 || true)"
    in_wake ./scripts/nogg resume >/dev/null
    wake_block 'block["enabled"] = True'
    update_out=$(update_wake)
    check "update keeps an explicit true" [ "$(wake_key enabled)" = "true" ]
    check "update with true prints no on-by-default line" bash -c "! grep -q 'Session dispatch is on' <<<\"\$1\"" _ "$update_out"
    wake_block 'del block["enabled"]; block["max_nudges"] = 5'
    update_out=$(update_wake)
    check "update of an older repository writes no enabled key" [ "$(wake_key enabled)" = "undefined" ]
    check "update of an older repository keeps its values" [ "$(wake_key max_nudges)" = "5" ]
    check "a new install scaffolds the testing block with empty stages" \
      [ "$(node -p "JSON.stringify(require('$wake/.nogging/config.json').testing.stages)")" = "{}" ]
    check "update with a testing block prints no testing line" \
      bash -c "! grep -q 'nogg test. runs on its defaults' <<<\"\$1\"" _ "$update_out"
    wake_block 'del config["testing"]'
    update_out=$(update_wake)
    check "update of a repository with no testing block says so once" \
      test "$(grep -c 'nogg test. runs on its defaults' <<<"$update_out")" -eq 1
    check "and names where to set stages" grep -q 'testing.stages' <<<"$update_out"
    check "and writes no testing block" \
      [ "$(node -p "typeof require('$wake/.nogging/config.json').testing")" = "undefined" ]
    check "update of an older repository says so once" \
      test "$(grep -c 'Session dispatch is on' <<<"$update_out")" -eq 1
    check "and names the switch" grep -q 'session_dispatch.enabled: false' <<<"$update_out"
    check "and a pass runs" \
      bash -c '! grep -q "is disabled" <<<"$1"' _ "$(in_wake ./scripts/nogg session dispatch --once 2>&1)"
    in_wake ./scripts/nogg pause --days 1 >/dev/null
    in_wake node "$pkg/bin/cli.js" remove >/dev/null 2>&1
    check "remove deletes the guide" test ! -e "$wake/docs/nogging/session-wake.md"
    check "remove leaves the dispatch state" test -d "$wake/.nogging/state/dispatch"
    check "remove leaves the pause" test -f "$wake/.nogging/state/pause.json"
    check "init, update and remove leave personal configuration alone" [ "$personal_before" = "$(personal)" ]

    # --- package "files" list validation (design Decision 6) ---------------
    # Every module the installer requires must be inside the tarball, else the
    # real npx install dies at load time even though the checkout works.
    missing=$(node - "$root" "$pkg" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, pkg] = process.argv.slice(2);
const missing = [];
const dirs = ['bin', 'bin/lib'];
for (const d of dirs) {
  for (const f of fs.readdirSync(path.join(root, d))) {
    if (!f.endsWith('.js')) continue;
    const rel = `${d}/${f}`;
    if (!fs.existsSync(path.join(pkg, rel))) missing.push(rel);
    const src = fs.readFileSync(path.join(root, rel), 'utf8');
    for (const m of src.matchAll(/require\('(\.[^']+)'\)/g)) {
      const base = path.join(path.dirname(path.join(pkg, rel)), m[1]);
      if (![base, `${base}.js`, `${base}.json`].some((p) => fs.existsSync(p) && fs.statSync(p).isFile())) {
        missing.push(`${rel} -> ${m[1]}`);
      }
    }
  }
}
process.stdout.write(missing.join('\n'));
NODE
)
    check "packed bin/ modules and their relative requires are all shipped${missing:+ (missing: $missing)}" \
      [ -z "$missing" ]
    for helper in bin/lib/manifest-store.js bin/lib/baselines.js bin/lib/fsops.js bin/lib/install.js bin/lib/remove.js; do
      check "packed package ships $helper" test -f "$pkg/$helper"
    done
    check "package.json files lists the manifest helpers" \
      node -e "const f=require('$root/package.json').files; process.exit(['bin/lib/manifest-store.js','bin/lib/baselines.js'].every(p=>f.includes(p))?0:1)"

    # --- manifest + preservation workflow from the packed install ----------
    manifest="$packrepo/.nogging/installed-manifest.json"
    check "packed install writes the installed manifest" test -f "$manifest"
    check "packed manifest declares schema 1 and the package version" \
      node -e "const m=require('$manifest'); process.exit(m.manifest_version===1 && m.nogging_version===require('$root/package.json').version ? 0 : 1)"
    check "packed manifest records the codex rules floor" \
      node -e "process.exit(require('$manifest').files['.codex/rules/nogging.rules'] ? 0 : 1)"
    manifest_before=$(cat "$manifest")
    ( cd "$packrepo" && node "$pkg/bin/cli.js" update --no-systemd >/dev/null 2>&1 ) || rc=$?
    check "packed update with no changes leaves the manifest identical" [ "$manifest_before" = "$(cat "$manifest")" ]
    check "packed update with no changes writes no .nogging-new" \
      [ -z "$(find "$packrepo" -name '*.nogging-new' -not -path '*/.git/*' | head -1)" ]

    # A "next release": same package with changed upstream content.
    pkg2="$pack/package-next"; cp -r "$pkg" "$pkg2"
    printf '\n# upstream next release\n' >> "$pkg2/.codex/rules/nogging.rules"
    printf '\n# upstream next release\n' >> "$pkg2/.nogging/launch-prompts/orchestrator.md"
    printf '\n# local customisation\n' >> "$packrepo/.codex/rules/nogging.rules"
    rules_local=$(cat "$packrepo/.codex/rules/nogging.rules")
    rc=0
    upd_out=$( cd "$packrepo" && node "$pkg2/bin/cli.js" update --no-systemd 2>&1 ) || rc=$?
    check "packed update over a modified file exits 0" [ "$rc" -eq 0 ]
    check "locally modified file is left unchanged" \
      [ "$rules_local" = "$(cat "$packrepo/.codex/rules/nogging.rules")" ]
    check "upstream content is written to .nogging-new" \
      cmp -s "$pkg2/.codex/rules/nogging.rules" "$packrepo/.codex/rules/nogging.rules.nogging-new"
    check "update reports the preserved file for review" \
      bash -c "grep -q 'nogging.rules.nogging-new' <<< \"\$0\"" "$upd_out"
    check "unmodified file is refreshed cleanly" \
      cmp -s "$pkg2/.nogging/launch-prompts/orchestrator.md" "$packrepo/.nogging/launch-prompts/orchestrator.md"
    check "refreshed file gets no .nogging-new" \
      test ! -e "$packrepo/.nogging/launch-prompts/orchestrator.md.nogging-new"
    check "manifest baseline still points at the old upstream for the preserved file" \
      node -e "
        const s=require('$root/bin/lib/manifest-store');
        const m=require('$manifest');
        process.exit(m.files['.codex/rules/nogging.rules']===s.hashFile('$pkg/.codex/rules/nogging.rules') ? 0 : 1)"

    # doctor surfaces the pending update without failing on it alone.
    doc_out=$( cd "$packrepo" && ./scripts/nogg doctor 2>&1 ) || true
    check "doctor warns about the pending .nogging-new" \
      bash -c "grep -q 'WARN.*nogging.rules.nogging-new' <<< \"\$0\"" "$doc_out"

    # --force backs the local file up and takes upstream.
    rc=0
    ( cd "$packrepo" && node "$pkg2/bin/cli.js" update --force --no-systemd >/dev/null 2>&1 ) || rc=$?
    check "packed update --force exits 0" [ "$rc" -eq 0 ]
    check "--force backs the local file up to .orig" \
      [ "$rules_local" = "$(cat "$packrepo/.codex/rules/nogging.rules.orig")" ]
    check "--force installs upstream content" \
      cmp -s "$pkg2/.codex/rules/nogging.rules" "$packrepo/.codex/rules/nogging.rules"

    # remove cleans up the manifest and the leftover artifacts.
    mkdir -p "$packrepo/.pi/skills/mine"
    printf 'keep me\n' > "$packrepo/.pi/skills/mine/SKILL.md"
    printf 'keep me too\n' > "$packrepo/.pi/settings.json"
    printf 'x\n' > "$packrepo/.codex/rules/nogging.rules.nogging-new"
    rc=0
    ( cd "$packrepo" && node "$pkg2/bin/cli.js" remove >/dev/null 2>&1 ) || rc=$?
    check "packed remove exits 0" [ "$rc" -eq 0 ]
    check "remove deletes the installed manifest" test ! -e "$manifest"
    # remove deletes files, as for every verbatim tree; empty directories may remain.
    check "remove deletes the Pi extension home" \
      [ -z "$(find "$packrepo/.pi/nogging" -type f 2>/dev/null | head -1)" ]
    check "remove leaves other .pi content" \
      test "$(cat "$packrepo/.pi/skills/mine/SKILL.md" "$packrepo/.pi/settings.json")" = "$(printf 'keep me\nkeep me too')"
    check "remove deletes .nogging-new and .orig leftovers" \
      [ -z "$(find "$packrepo" \( -name '*.nogging-new' -o -name '*.orig' \) -not -path '*/.git/*' | head -1)" ]
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
