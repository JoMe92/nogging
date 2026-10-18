#!/usr/bin/env bash
# Asserts that docs/using-with-herdr.md quotes the real advisory format string
# from scripts/nogg (TASK-HSS-006, design Decision 7).
set -euo pipefail

# Clean environment: unset inherited NOGG_*, HERDR_*, TMUX, TMUX_TMPDIR
unset NOGGING_ROOT NOGG_SESSION_NAME NOGG_SESSION_ROOT NOGG_SESSION_ROLE
unset NOGG_SESSION_AGENT NOGG_TASK_DONE_SOCKET NOGG_OPENSPEC_FENCED NOGG_OPENSPEC_FENCE
unset HERDR_CONFIG_PATH HERDR_SOCKET TMUX TMUX_TMPDIR

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
docs="$root/docs/using-with-herdr.md"
nogg="$root/scripts/nogg"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test -f "$docs" || fail "documentation file not found: $docs"
test -f "$nogg" || fail "nogg script not found: $nogg"

# Extract the format string pattern from scripts/nogg:
# e.g., print(f"NOTE: {foreign_count} foreign herdr pane(s) left untouched")
# Converts to: NOTE: <N> foreign herdr pane(s) left untouched
format_line=$(grep -E 'print\(f"NOTE: \{.*\} foreign herdr pane\(s\) left untouched"\)' "$nogg" || true)
if [[ -z "$format_line" ]]; then
  fail "Could not find herdr foreign pane advisory format string in scripts/nogg"
fi

expected_quote=$(echo "$format_line" | sed -E 's/.*print\(f"(NOTE: )\{[^}]+\}( foreign herdr pane\(s\) left untouched)"\).*/\1<N>\2/')

if [[ "$expected_quote" != "NOTE: <N> foreign herdr pane(s) left untouched" ]]; then
  fail "Extracted unexpected advisory pattern: $expected_quote"
fi

# Assert that docs/using-with-herdr.md quotes the exact expected advisory string
grep -F -q "$expected_quote" "$docs" || fail "docs/using-with-herdr.md does not quote '$expected_quote'"

# Assert that the old incorrect wording is not present
if grep -F -q "foreign Nogging pane(s) active on herdr server" "$docs"; then
  fail "docs/using-with-herdr.md still contains old advisory wording"
fi

printf 'docs-herdr-foreign-note: ok\n'
