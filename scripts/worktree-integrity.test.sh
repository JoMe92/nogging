#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
scratch=$(mktemp -d)
trap 'rm -r "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
git init --bare "$scratch/origin.git" >/dev/null
git init -b develop "$scratch/seed" >/dev/null
cd "$scratch/seed"
git config user.name Fixture
git config user.email fixture@example.invalid
printf 'base\n' > code.txt
printf 'base\n' > own.txt
mkdir -p openspec/changes/example
printf 'task\n' > openspec/changes/example/tasks.md
git add . && git commit -m seed >/dev/null
git remote add origin "$scratch/origin.git"
git push -u origin develop >/dev/null
git worktree add -b feat/integrity "$scratch/wt" HEAD >/dev/null
printf 'upstream\n' > code.txt
printf 'task upstream\n' > openspec/changes/example/tasks.md
git add . && git commit -m upstream >/dev/null
git push origin develop >/dev/null

# Exercise the real helper against a real linked worktree.
export NOGGING_ROOT="$root"
python3 - "$scratch/wt" <<'PY'
import importlib.machinery, os, pathlib, sys
m = importlib.machinery.SourceFileLoader('nogg_integrity_test',
    str(pathlib.Path(os.environ['NOGGING_ROOT']) / 'scripts/nogg')).load_module()
assert not m._is_legacy_mock(), 'classifier must run on its real Git path'
wt = pathlib.Path(sys.argv[1])
result = m.classify_worktree_integrity(wt)
assert result['state'] == 'clean', result
# Simulate the #241 checkout failure by copying upstream bytes without changing
# HEAD or the index.
(wt / 'code.txt').write_text('upstream\n')
(wt / 'openspec/changes/example/tasks.md').write_text('task upstream\n')
result = m.classify_worktree_integrity(wt)
assert result['state'] == 'half-applied', result
assert result['reproducible'] == ['code.txt', 'openspec/changes/example/tasks.md'], result

# The recovery/doctor readers consume durable implementation records and keep
# the same classification read-only and visible to operators.
import json
m.ROOT = wt.parent
m.STATE = wt.parent / '.nogging/state'
m.WORKTREE_STATE = m.STATE / 'worktrees'
m.WORKTREE_STATE.mkdir(parents=True, exist_ok=True)
(m.WORKTREE_STATE / 'implementation--fixture.json').write_text(json.dumps({
    'kind': 'implementation', 'path': str(wt), 'branch': 'feat/integrity'}))
lines, attention = m.worktree_integrity_diagnostics()
assert any('half-applied' in line for line in lines), lines
assert 'worktree wt half-applied' in attention, attention

(wt / 'own.txt').write_text('my edits\n')
result = m.classify_worktree_integrity(wt)
assert result['state'] == 'mixed', result
assert result['reproducible'] == ['code.txt', 'openspec/changes/example/tasks.md'], result
assert result['other'] == ['own.txt'], result
lines, attention = m.worktree_integrity_diagnostics()
assert any('mixed' in line for line in lines), lines
assert 'worktree wt mixed' in attention, attention

(wt / 'code.txt').write_text('my code edits\n')
(wt / 'openspec/changes/example/tasks.md').write_text('my task edits\n')
(wt / 'own.txt').write_text('base\n')
result = m.classify_worktree_integrity(wt)
assert result['state'] == 'dirty', result
assert not result['reproducible'], result

gd = pathlib.Path(__import__('subprocess').check_output(
    ['git', '-C', str(wt), 'rev-parse', '--git-dir'], text=True).strip())
if not gd.is_absolute(): gd = (wt / gd).resolve()
(gd / 'rebase-merge').mkdir()
result = m.classify_worktree_integrity(wt)
assert result['state'] == 'operation-in-progress', result
print('ok - clean, half-applied, mixed, dirty and operation-in-progress worktree classification')
PY
