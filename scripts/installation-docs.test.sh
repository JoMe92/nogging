#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
docs="$root/docs/installation.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

help=$(node "$root/bin/cli.js" --help)
for flag in --dry-run --no-beads --no-hooks --no-systemd; do
  grep -q -- "$flag" <<<"$help" || fail "CLI help omits $flag"
  grep -q -- "$flag" "$docs" || fail "installation guide omits $flag"
done

grep -q 'github:JoMe92/nogging#v2.0.0 init' "$docs" || fail "install command is not pinned"
grep -q 'runs `bd init` automatically' "$docs" || fail "default Beads initialization is undocumented"
grep -q '### Without systemd' "$docs" || fail "non-systemd operation is undocumented"
grep -q 'Updating and rolling back' "$docs" || fail "rollback is undocumented"
grep -q 'Removing the installed payload' "$docs" || fail "removal is undocumented"
grep -q 'core.hooksPath' "$docs" || fail "hook collision is undocumented"
grep -q 'Claude Code path' "$docs" || fail "Claude payload prerequisite is undocumented"
grep -q 'Codex agent path' "$docs" || fail "Codex payload prerequisite is undocumented"
grep -q 'Pi agent path' "$docs" || fail "Pi payload prerequisite is undocumented"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git -C "$scratch" init -q
( cd "$scratch" && node "$root/bin/cli.js" init --no-beads >/dev/null )
slug=$(basename "$scratch" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')

for path in \
  scripts/nogg \
  .claude/agents/architect.md \
  .claude/commands/plan.md \
  .codex/rules/nogging.rules \
  .codex/prompts/plan.md \
  .pi/extensions/nogging-guard.ts \
  .pi/prompts/plan.md \
  openspec/config.yaml \
  openspec/project.md \
  systemd/nogg-sync-"$slug".timer \
  systemd/nogg-orchestrator-"$slug".service; do
  test -e "$scratch/$path" || fail "fresh install omitted $path"
done

without_systemd="$scratch/no-systemd"
mkdir -p "$without_systemd"
git -C "$without_systemd" init -q
( cd "$without_systemd" && node "$root/bin/cli.js" init --no-beads --no-systemd >/dev/null )
test ! -d "$without_systemd/systemd" || fail "--no-systemd rendered units"

printf 'installation documentation contract: ok\n'
