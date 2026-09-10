#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

forbidden_tracked=$(
  while IFS= read -r path; do
    test ! -e "$path" || printf '%s\n' "$path"
  done < <(
    git ls-files \
      | grep -E '^(systemd/|docs/source/|docs/acceptance/2026-09-02-raspberrypi\.md$)|(^|/)__pycache__/|\.py[co]$' \
      || true
  )
)
test -z "$forbidden_tracked" || {
  printf '%s\n' "$forbidden_tracked" >&2
  fail "current Git tree contains private/internal operational artifacts"
}

# Product/user surfaces must not expose a maintainer checkout. OpenSpec history
# is immutable execution evidence and is reviewed separately by the release
# audit rather than silently rewritten by an execution task.
public_surfaces=(README.md AGENTS.md CLAUDE.md package.json bin scripts templates docs)
private_paths=$(
  grep -RInE --exclude='public-tree.test.sh' --exclude-dir=source --exclude-dir=acceptance \
    '/home/jome(/|$)|/Users/[^ /]+/' "${public_surfaces[@]}" 2>/dev/null \
    || true
)
test -z "$private_paths" || {
  printf '%s\n' "$private_paths" >&2
  fail "current public surface contains a maintainer-specific path"
}

pack_json=$(mktemp)
trap 'rm -f "$pack_json"' EXIT
npm pack --dry-run --json >"$pack_json"
node - "$pack_json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))[0];
const forbidden = report.files.map(f => f.path).filter(path =>
  path.startsWith('systemd/') ||
  path.startsWith('docs/source/') ||
  path.startsWith('docs/acceptance/') ||
  path.includes('__pycache__/') ||
  /\.py[co]$/.test(path)
);
if (forbidden.length) {
  console.error(forbidden.join('\n'));
  throw new Error('package contains private/internal operational artifacts');
}
NODE

printf 'public tree and package artifact gate: ok\n'
