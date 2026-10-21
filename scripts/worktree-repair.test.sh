#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/test-env.sh"
source "$repo_root/scripts/lib/test-agents.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
stub_agent_binaries "$scratch/agents"
PATH="$scratch/agents:$PATH"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

root="$scratch/repo"
remote="$scratch/origin.git"
tree="$root/lead"
mkdir -p "$root/.nogging/state/worktrees" "$root/.nogging/state/sessions" \
  "$root/openspec/changes/demo"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
git init -q --bare "$remote"
git init -q -b develop "$root"
git -C "$root" config user.name Fixture
git -C "$root" config user.email fixture@example.invalid
printf 'old code\n' >"$root/code.txt"
printf 'old task\n' >"$root/openspec/changes/demo/tasks.md"
printf 'base\n' >"$root/own.txt"
git -C "$root" add -A
git -C "$root" commit -q -m seed
git -C "$root" remote add origin "$remote"
git -C "$root" push -q -u origin develop
git -C "$root" worktree add -q -b perf/demo "$tree" origin/develop
git -C "$root" config user.name Fixture
git -C "$root" config user.email fixture@example.invalid
printf 'new code\n' >"$root/code.txt"
printf 'new task\n' >"$root/openspec/changes/demo/tasks.md"
git -C "$root" add code.txt openspec/changes/demo/tasks.md
git -C "$root" commit -q -m upstream
git -C "$root" push -q origin develop
printf 'new code\n' >"$tree/code.txt"
printf 'new task\n' >"$tree/openspec/changes/demo/tasks.md"
printf 'lead edit\n' >"$tree/own.txt"
printf 'untracked bytes\n' >"$tree/untracked.txt"
printf 'staged bytes\n' >"$tree/staged.txt"
git -C "$tree" add staged.txt
printf 'staged and modified\n' >"$tree/staged.txt"
printf '{"path":"%s","branch":"perf/demo","kind":"implementation","state":"allocated"}\n' \
  "$tree" >"$root/.nogging/state/worktrees/implementation--demo.json"

run_repair() {
  NOGGING_ROOT="$root" "$repo_root/scripts/nogg" worktree repair implementation--demo.json "$@"
}

# Dry-run describes the exact reproducible paths and leaves the full byte state alone.
before=$(git -C "$tree" status --porcelain=v1 -z | sha256sum)
staged_before=$(git -C "$tree" diff --cached --binary | sha256sum)
run_repair >"$scratch/dry-run.out"
grep -q 'code.txt' "$scratch/dry-run.out"
grep -q 'openspec/changes/demo/tasks.md' "$scratch/dry-run.out"
grep -q 'own.txt' "$scratch/dry-run.out"
[[ "$before" == "$(git -C "$tree" status --porcelain=v1 -z | sha256sum)" ]]
[[ "$(cat "$tree/own.txt")" == 'lead edit' ]]

# Apply snapshots staged, unstaged and untracked content, then restores only paths
# whose bytes exactly match origin/develop. The Lead's own edits remain byte-for-byte.
run_repair --apply >"$scratch/apply.out"
backup_ref=$(sed -n 's/^backup ref: //p' "$scratch/apply.out")
[[ "$backup_ref" == refs/nogg/repair-backup/perf/demo/* ]]
backup_commit=$(git -C "$tree" rev-parse "$backup_ref^{commit}")
[[ "$(git -C "$tree" show "$backup_commit:own.txt")" == 'lead edit' ]]
[[ "$(git -C "$tree" show "$backup_commit:untracked.txt")" == 'untracked bytes' ]]
[[ "$(git -C "$tree" show "$backup_commit:staged.txt")" == 'staged and modified' ]]
staged_backup=$(git -C "$tree" rev-parse "$backup_commit^2")
[[ "$(git -C "$tree" show "$staged_backup:staged.txt")" == 'staged bytes' ]]
[[ "$(cat "$tree/code.txt")" == 'old code' ]]
[[ "$(cat "$tree/openspec/changes/demo/tasks.md")" == 'old task' ]]
[[ "$(cat "$tree/own.txt")" == 'lead edit' ]]
[[ "$(cat "$tree/untracked.txt")" == 'untracked bytes' ]]
[[ "$(cat "$tree/staged.txt")" == 'staged and modified' ]]
[[ "$staged_before" == "$(git -C "$tree" diff --cached --binary | sha256sum)" ]]

# Operation state and a live foreign session refuse before creating a backup ref.
gitdir=$(git -C "$tree" rev-parse --absolute-git-dir)
mkdir "$gitdir/rebase-merge"
if run_repair --apply >"$scratch/operation.out" 2>&1; then
  echo 'operation-in-progress repair unexpectedly succeeded' >&2; exit 1
fi
grep -q 'operation is in progress' "$scratch/operation.out"
rmdir "$gitdir/rebase-merge"

printf 'new code\n' >"$tree/code.txt"
printf 'new task\n' >"$tree/openspec/changes/demo/tasks.md"
printf '{"name":"other-lead","state":"running","working_dir":"%s"}\n' "$tree" \
  >"$root/.nogging/state/sessions/other.json"
if run_repair --apply >"$scratch/in-use.out" 2>&1; then
  echo 'worktree with a live foreign session unexpectedly repaired' >&2; exit 1
fi
grep -q 'active session other-lead' "$scratch/in-use.out"
rm "$root/.nogging/state/sessions/other.json"

# A fenced apply refuses any reproducible OpenSpec path before snapshot or restore.
if NOGG_OPENSPEC_FENCED=1 run_repair --apply >"$scratch/fenced.out" 2>&1; then
  echo 'fenced OpenSpec repair unexpectedly succeeded' >&2; exit 1
fi
grep -q 'openspec/changes/demo/tasks.md' "$scratch/fenced.out"
[[ -e "$tree/openspec/changes/demo/tasks.md" ]]

echo 'worktree repair safety and real git fixtures: ok'
