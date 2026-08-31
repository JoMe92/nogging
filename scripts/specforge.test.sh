#!/usr/bin/env bash
# Focused checks for `scripts/specforge discoveries` (TASK-BOUNDARY-002).
# Covers: no discoveries, blocked-first ordering, ID/status/title/note surfaced,
# missing note tolerated, and that the `discovery` label alone selects issues
# (no JSON discovery schema is parsed).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
specforge="$here/specforge"
work=$(mktemp -d)
trap 'rm -f "$out"; rm -rf "$work"' EXIT
out=$(mktemp)

# A `bd` stub: `list --label discovery --json` and `show <id> --json` read
# fixture files from $BD_STUB_DIR; everything else is an error.
mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "list" ]]; then
  cat "$BD_STUB_DIR/discoveries.json"
  exit 0
fi
if [[ "${1:-}" == "show" ]]; then
  f="$BD_STUB_DIR/show-$2.json"
  if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi
  exit 0
fi
echo "unexpected bd call: $*" >&2
exit 1
STUB
chmod +x "$work/bin/bd"
export PATH="$work/bin:$PATH"

fail=0
check() { # check <description> <expected-substring>
  if grep -qF -- "$2" "$out"; then echo "ok   - $1"; else
    echo "FAIL - $1 (missing: $2)"; cat "$out"; fail=1; fi
}
refute() { # refute <description> <substring-that-must-be-absent>
  if grep -qF -- "$2" "$out"; then echo "FAIL - $1 (present: $2)"; fail=1; else
    echo "ok   - $1"; fi
}

# --- Scenario: no pending discoveries ---------------------------------------
export BD_STUB_DIR="$work/none"; mkdir -p "$BD_STUB_DIR"
printf '[]\n' >"$BD_STUB_DIR/discoveries.json"
"$specforge" discoveries >"$out" 2>&1
check "no discoveries: friendly line" "no pending discoveries"

# --- Scenario: mixed discoveries, blocked first, note surfaced --------------
export BD_STUB_DIR="$work/mixed"; mkdir -p "$BD_STUB_DIR"
cat >"$BD_STUB_DIR/discoveries.json" <<'JSON'
[
  {"id": "SPEC-aaa", "status": "open", "title": "Non-blocking finding",
   "labels": ["openspec:task:TASK-X", "discovery"]},
  {"id": "SPEC-bbb", "status": "blocked", "title": "Blocking finding",
   "labels": ["discovery"]},
  {"id": "SPEC-ccc", "status": "in_progress", "title": "No note here",
   "labels": ["discovery"]}
]
JSON
printf '[{"id":"SPEC-aaa","notes":"Config drift found; see logs. Suggest a follow-up task."}]\n' >"$BD_STUB_DIR/show-SPEC-aaa.json"
printf '[{"id":"SPEC-bbb","notes":"Upstream API renamed; task cannot finish as specified."}]\n' >"$BD_STUB_DIR/show-SPEC-bbb.json"
printf '[{"id":"SPEC-ccc","notes":""}]\n' >"$BD_STUB_DIR/show-SPEC-ccc.json"
"$specforge" discoveries >"$out" 2>&1

check "mixed: count and blocking summary" "3 pending discoveries (1 blocking)"
check "mixed: blocked issue id + status + title" "[blocked] SPEC-bbb  Blocking finding"
check "mixed: open issue rendered" "[open] SPEC-aaa  Non-blocking finding"
check "mixed: human-readable note surfaced" "Upstream API renamed; task cannot finish as specified."
check "mixed: missing note tolerated" "(no human-readable note recorded)"

# blocked line must appear before the open line
blocked_ln=$(grep -n "SPEC-bbb  Blocking finding" "$out" | head -1 | cut -d: -f1)
open_ln=$(grep -n "SPEC-aaa  Non-blocking finding" "$out" | head -1 | cut -d: -f1)
if [[ "$blocked_ln" -lt "$open_ln" ]]; then echo "ok   - mixed: blocked listed before non-blocking"; else
  echo "FAIL - mixed: blocked not prioritised ($blocked_ln vs $open_ln)"; fail=1; fi

# --- Scenario: label is the only selector ----------------------------------
export BD_STUB_DIR="$work/labelonly"; mkdir -p "$BD_STUB_DIR"
cat >"$BD_STUB_DIR/discoveries.json" <<'JSON'
[
  {"id": "SPEC-ddd", "status": "open", "title": "Labelled", "labels": ["discovery"]},
  {"id": "SPEC-eee", "status": "open", "title": "Not labelled", "labels": ["other"]}
]
JSON
printf '[{"id":"SPEC-ddd","notes":"prose"}]\n' >"$BD_STUB_DIR/show-SPEC-ddd.json"
"$specforge" discoveries >"$out" 2>&1
check "label-only: labelled issue shown" "SPEC-ddd  Labelled"
refute "label-only: unlabelled issue skipped" "SPEC-eee"

if [[ $fail -ne 0 ]]; then echo "specforge discoveries checks failed" >&2; exit 1; fi
echo "all specforge discoveries checks passed"
