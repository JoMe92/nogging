#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
doc=docs/public-cutover.md

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

test -f "$doc" || fail "owner cutover checklist is missing"
for phrase in \
  'description to:' \
  'Set topics to:' \
  'default branch' \
  'Issues enabled' \
  'private-phase reporting route' \
  'GitHub Release' \
  'Local remotes' \
  'Legacy repository retirement' \
  'Private Vulnerability Reporting' \
  'Rollback' \
  'Signed-off-by:'
do
  grep -Fq "$phrase" "$doc" || fail "missing checklist item: $phrase"
done

if grep -Eq 'gh repo (edit|archive|delete)|gh api .*-(X|f) (PATCH|PUT|DELETE)|git push .*--mirror|git push .*--force' "$doc"; then
  fail "checklist contains an automated destructive or owner-only mutation"
fi

grep -Fq 'must not change visibility' "$doc" || fail "automation visibility boundary is missing"
grep -Fq 'Signed-off-by:` value is empty' "$doc" || fail "unsigned acceptance gate is missing"
grep -Fq 'Change **only** `JoMe92/nogging` from private to public' "$doc" \
  || fail "successor-only visibility action is missing"
grep -Fq 'Never make the legacy repository public' "$doc" || fail "legacy visibility prohibition is missing"

printf 'owner cutover checklist: ok\n'
