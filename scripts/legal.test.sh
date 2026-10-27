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
grep -q 'Copyright (c) 2026 Jonas (JoMe92)' LICENSE || fail "copyright identity is missing"

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

# Each distributed MIT component carries its upstream copyright line followed
# by the MIT permission text, and links its current upstream repository.
mit_permission='Permission is hereby granted, free of charge, to any person obtaining a copy'
for copyright in 'Copyright (c) 2024 OpenSpec Contributors' 'Copyright (c) 2025 Beads Contributors'; do
  grep -qxF "$copyright" THIRD_PARTY_NOTICES.md || fail "third-party notices lack the copyright line: $copyright"
  grep -A3 -xF "$copyright" THIRD_PARTY_NOTICES.md | grep -qxF "$mit_permission" \
    || fail "third-party notices lack the MIT permission text after: $copyright"
done
grep -qxF 'The above copyright notice and this permission notice shall be included in all' THIRD_PARTY_NOTICES.md \
  || fail "third-party notices lack the MIT notice condition"
for upstream in 'https://github.com/Fission-AI/OpenSpec' 'https://github.com/gastownhall/beads'; do
  grep -qF "($upstream)" THIRD_PARTY_NOTICES.md || fail "third-party notices do not link $upstream"
done
if grep -qiF 'github.com/steveyegge/beads' THIRD_PARTY_NOTICES.md; then
  fail "third-party notices link the old Beads home github.com/steveyegge/beads"
fi

pack_json=$(npm pack --dry-run --json 2>/dev/null)
node -e '
  const entries = JSON.parse(process.argv[1]);
  const files = new Set(entries[0].files.map((entry) => entry.path));
  for (const required of ["LICENSE", "THIRD_PARTY_NOTICES.md"]) {
    if (!files.has(required)) throw new Error(`${required} is absent from npm package`);
  }
' "$pack_json" || fail "legal files are not included in the package"

printf 'legal metadata and package notices: ok\n'
