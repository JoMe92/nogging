#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workflow="$root/.github/workflows/nogging-validate.yml"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -A1 '^permissions:' "$workflow" | grep -Fq 'contents: read' \
  || fail "workflow lacks read-only default permissions"

bad_uses=$(grep -REh '^[[:space:]]*- uses:' "$root/.github/workflows" \
  | grep -Ev '@[0-9a-f]{40}([[:space:]]*#.*)?$' || true)
if [[ -n "$bad_uses" ]]; then
  printf '%s\n' "$bad_uses" >&2
  fail "third-party action is not pinned to a full commit SHA"
fi

for gate in 'Credential pattern scan' 'Markdown relative-link validation' \
  'Clean package-content validation' 'Dependency vulnerability scan'; do
  grep -Fq "$gate" "$workflow" || fail "workflow omits $gate"
done

grep -Fq 'actions/dependency-review-action@' "$workflow" \
  || fail "dependency review action is absent"
grep -Fq 'package-ecosystem: npm' "$root/.github/dependabot.yml" \
  || fail "npm dependency updates are not configured"
grep -Fq 'package-ecosystem: github-actions' "$root/.github/dependabot.yml" \
  || fail "GitHub Actions updates are not configured"

printf 'workflow security policy: ok\n'
