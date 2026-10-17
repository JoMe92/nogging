#!/usr/bin/env bash
# Structure guard for CHANGELOG.md (release-readme-installer, Decision 7):
#   - exactly one `## [Unreleased]`, and it is the first section;
#   - every other section is `## [X.Y.Z(-rc.N)] - YYYY-MM-DD`, strictly descending;
#   - only Keep a Changelog subsection names;
#   - a released section that marks a change **BREAKING** has a higher major
#     than the next older released section;
#   - every **BREAKING** entry in Unreleased or in a 3.x+ section names a
#     **Migration:** step.
# The real file is checked first; the same checker then runs against bad
# fixtures to prove each rule fails. Offline: bash and coreutils only.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
tmp=$(mktemp -d)
cleanup() { case "$tmp" in /tmp/tmp.*) rm -rf -- "$tmp" ;; esac; }
trap cleanup EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
fail_() { printf 'FAIL - %s\n' "$1" >&2; fail=1; }

# check_changelog <file>: prints one problem per line, nothing when valid.
check_changelog() {
  python3 -I - "$1" <<'PY'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
problems = []
KAC = {"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}
SEMVER = re.compile(
    r"^## \[(\d+)\.(\d+)\.(\d+)(?:-rc\.(\d+))?\] - \d{4}-\d{2}-\d{2}$")

def key(m):
    # An rc sorts before its final release: 3.0.0-rc.1 < 3.0.0.
    major, minor, patch = (int(m.group(i)) for i in (1, 2, 3))
    rc = m.group(4)
    return (major, minor, patch, 1 if rc is None else 0, int(rc or 0))

sections = []  # (heading, line_no, body_lines)
for no, line in enumerate(lines, 1):
    if line.startswith("## "):
        sections.append([line, no, []])
    elif sections:
        sections[-1][2].append((no, line))

unreleased = [s for s in sections if s[0] == "## [Unreleased]"]
if len(unreleased) != 1:
    problems.append(f"expected exactly one '## [Unreleased]', found {len(unreleased)}")
elif sections[0][0] != "## [Unreleased]":
    problems.append("'## [Unreleased]' is not the first section")

released = []
for heading, no, body in sections:
    if heading == "## [Unreleased]":
        continue
    m = SEMVER.match(heading)
    if not m:
        problems.append(f"line {no}: malformed section heading: {heading}")
        continue
    released.append((heading, key(m), body))

for (h1, k1, _), (h2, k2, _) in zip(released, released[1:]):
    if not k1 > k2:
        problems.append(f"{h1} must have a higher version than the next section {h2}")

for heading, no, body in sections:
    for bno, line in body:
        if line.startswith("### ") and line[4:].strip() not in KAC:
            problems.append(f"line {bno}: not a Keep a Changelog subsection: {line}")

def breaking(body):
    return [l for _, l in body if "**BREAKING**" in l]

for i, (heading, k, body) in enumerate(released):
    if breaking(body) and i + 1 < len(released):
        older = released[i + 1]
        if not k[0] > older[1][0]:
            problems.append(
                f"{heading} has a **BREAKING** entry but does not raise the major "
                f"version above {older[0]}")

for heading, no, body in sections:
    m = SEMVER.match(heading)
    if heading != "## [Unreleased]" and not (m and int(m.group(1)) >= 3):
        continue
    for entry in breaking(body):
        if "**Migration:**" not in entry:
            problems.append(f"{heading}: **BREAKING** entry names no **Migration:** step: {entry[:70]}")

print("\n".join(problems))
PY
}

out=$(check_changelog "$root/CHANGELOG.md")
if [[ -z "$out" ]]; then pass "CHANGELOG.md is structurally valid"; else fail_ "CHANGELOG.md: $out"; fi

# The backfilled Unreleased section carries the three documented breaking
# changes and an upgrade-notes paragraph, and no version heading yet.
unrel=$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$root/CHANGELOG.md")
n=$(grep -c '^- \*\*BREAKING\*\*' <<<"$unrel" || true)
if [[ "$n" == 3 ]]; then pass "Unreleased lists three BREAKING bullets"; else fail_ "Unreleased lists $n BREAKING bullets, expected 3"; fi
grep -q '^Upgrade notes:' <<<"$unrel" && pass "Unreleased has an Upgrade notes paragraph" || fail_ "Unreleased lacks an Upgrade notes paragraph"
for needle in '--force' '--profile trusted' '--full-access' 'KeyError' 'release every reservation'; do
  grep -qF -- "$needle" <<<"$unrel" && pass "Unreleased names migration detail: $needle" || fail_ "Unreleased lacks: $needle"
done
if grep -n '^## \[[0-9]' <<<"$unrel" >/dev/null; then fail_ "Unreleased contains a version heading"; else pass "Unreleased contains no version heading"; fi

# Negative fixtures: each rule must trip.
expect_fail() { # <name> <needle> <body>
  printf '%s\n' "$3" >"$tmp/bad.md"
  local got; got=$(check_changelog "$tmp/bad.md")
  if [[ "$got" == *"$2"* ]]; then pass "rejects: $1"; else fail_ "does not reject: $1 (got: ${got:-nothing})"; fi
}

good=$'# Changelog\n\n## [Unreleased]\n\n## [1.1.0] - 2026-01-02\n\n### Added\n\n- x\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- y'
printf '%s\n' "$good" >"$tmp/good.md"
[[ -z "$(check_changelog "$tmp/good.md")" ]] && pass "accepts a minimal valid changelog" || fail_ "rejects a minimal valid changelog"

expect_fail "missing Unreleased" "exactly one" $'# C\n\n## [1.0.0] - 2026-01-01'
expect_fail "duplicate Unreleased" "exactly one" $'# C\n\n## [Unreleased]\n\n## [Unreleased]'
expect_fail "Unreleased not first" "not the first" $'# C\n\n## [1.0.0] - 2026-01-01\n\n## [Unreleased]'
expect_fail "undated release heading" "malformed section heading" $'# C\n\n## [Unreleased]\n\n## [1.0.0]'
expect_fail "non-descending versions" "higher version" $'# C\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n## [1.1.0] - 2026-01-02'
expect_fail "rc after its final release" "higher version" $'# C\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-02\n\n## [1.0.0-rc.1] - 2026-01-01\n\n## [1.0.0-rc.2] - 2026-01-01'
expect_fail "unknown subsection" "Keep a Changelog" $'# C\n\n## [Unreleased]\n\n### Misc\n\n- x'
expect_fail "BREAKING in a minor release" "does not raise the major" $'# C\n\n## [Unreleased]\n\n## [1.1.0] - 2026-01-02\n\n### Changed\n\n- **BREAKING**: x\n\n## [1.0.0] - 2026-01-01'
expect_fail "BREAKING without a migration" "Migration" $'# C\n\n## [Unreleased]\n\n### Changed\n\n- **BREAKING**: x'
printf '%s\n' $'# C\n\n## [Unreleased]\n\n## [2.0.0] - 2026-01-02\n\n### Changed\n\n- **BREAKING**: x **Migration:** y\n\n## [1.0.0] - 2026-01-01' >"$tmp/major.md"
[[ -z "$(check_changelog "$tmp/major.md")" ]] && pass "accepts BREAKING in a major release" || fail_ "rejects BREAKING in a major release"

exit "$fail"
