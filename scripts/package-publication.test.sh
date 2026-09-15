#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

node <<'NODE' || exit 1
const pkg = require('./package.json');
const expected = {
  name: 'nogg',
  private: true,
  homepage: 'https://github.com/JoMe92/nogging#readme',
  author: 'Jonas Meier',
};
for (const [key, value] of Object.entries(expected)) {
  if (pkg[key] !== value) throw new Error(`${key} must be ${JSON.stringify(value)}`);
}
if (pkg.repository?.url !== 'git+https://github.com/JoMe92/nogging.git') {
  throw new Error('repository metadata is missing or incorrect');
}
if (pkg.bugs?.url !== 'https://github.com/JoMe92/nogging/issues') {
  throw new Error('bugs metadata is missing or incorrect');
}
if (!Array.isArray(pkg.keywords) || pkg.keywords.length < 5) {
  throw new Error('public discovery keywords are incomplete');
}
if (!String(pkg.scripts?.prepublishOnly).includes('process.exit(1)')) {
  throw new Error('prepublishOnly must fail closed');
}
NODE

publish_log=$(mktemp)
trap 'rm -f "$publish_log"' EXIT
if npm publish --dry-run >"$publish_log" 2>&1; then
  cat "$publish_log" >&2
  fail "npm publish --dry-run unexpectedly succeeded"
fi
grep -q 'distributed from tagged GitHub releases' "$publish_log" \
  || fail "publish refusal does not explain the GitHub-only route"

grep -q 'unscoped npm name' README.md || fail "README does not document the npm name collision"
grep -q 'github:JoMe92/nogging#v2.0.0' README.md || fail "README does not use a pinned GitHub tag"

printf 'GitHub-only package publication policy: ok\n'
