#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test -f LICENSE || fail "root LICENSE is missing"
grep -qx 'ISC License' LICENSE || fail "LICENSE is not the canonical ISC text"
grep -q 'Copyright (c) 2026 Jonas Meier' LICENSE || fail "copyright identity is missing"

node -e '
  const pkg = require("./package.json");
  if (pkg.license !== "ISC") {
    throw new Error(`package license is ${pkg.license}, expected ISC`);
  }
' || fail "package metadata does not declare ISC"

test -f THIRD_PARTY_NOTICES.md || fail "third-party notices are missing"
grep -q 'OpenSpec' THIRD_PARTY_NOTICES.md || fail "OpenSpec attribution is missing"
grep -q 'Beads' THIRD_PARTY_NOTICES.md || fail "Beads attribution is missing"
grep -q 'not affiliated with' THIRD_PARTY_NOTICES.md || fail "non-affiliation statement is missing"

pack_json=$(npm pack --dry-run --json 2>/dev/null)
node -e '
  const entries = JSON.parse(process.argv[1]);
  const files = new Set(entries[0].files.map((entry) => entry.path));
  for (const required of ["LICENSE", "THIRD_PARTY_NOTICES.md"]) {
    if (!files.has(required)) throw new Error(`${required} is absent from npm package`);
  }
' "$pack_json" || fail "legal files are not included in the package"

printf 'legal metadata and package notices: ok\n'
