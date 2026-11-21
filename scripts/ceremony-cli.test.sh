#!/usr/bin/env bash
# `nogg ceremony` and `nogg triage` (TASK-CER-001, change adaptive-ceremony): the
# `ceremony` block of .nogging/config.json read with its defaults, a bad value
# as a WARN in `doctor` that never changes the exit code, and triage printing
# the mode, the rules' lane, the effective lane and every fired rule, as text,
# as JSON and as one line on a Bead's note. Offline: a throwaway repository and
# a stub `bd` on PATH that records its argv.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/test-env.sh
source "$here/lib/test-env.sh"
nogg="$here/nogg"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# doctor walks CODEX_HOME: never the operator's real one.
mkdir -p "$work/codex-home"
export CODEX_HOME="$work/codex-home"

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
is() { [[ "$1" == "$2" ]]; }

# The stub records one line per call, its arguments separated by a unit separator.
bd_log="$work/bd.log"
mkdir -p "$work/bin"
cat > "$work/bin/bd" <<STUB
#!/usr/bin/env bash
[[ \${1:-} == list ]] && { echo "[]"; exit 0; }
[[ \${1:-} == update && -e "$work/bd-fails" ]] && { echo "no such issue" >&2; exit 1; }
( IFS=\$'\\x1f'; printf '%s\\n' "\$*" ) >> "$bd_log"
exit 0
STUB
chmod +x "$work/bin/bd"
export PATH="$work/bin:$PATH"

repo="$work/repo"
mkdir -p "$repo/.nogging" "$repo/openspec/changes"
git -C "$repo" init -q
write_config() { # <ceremony JSON or empty>
  local extra=""
  [[ -n "$1" ]] && extra=", \"ceremony\": $1"
  printf '{"name": "fixture", "beads_command": "bd", "planning_lock_ttl_seconds": 7200, "sync_lock_ttl_seconds": 120%s}\n' \
    "$extra" > "$repo/.nogging/config.json"
}
run() { NOGGING_ROOT="$repo" "$nogg" "$@" 2>&1; }
doctor() { local rc=0; run doctor >"$work/doctor.out" || rc=$?; echo "$rc"; }

# --- nogg ceremony: an unset and a configured block -----------------------------
write_config ""
out=$(run ceremony)
check "an unset block is always-full, the default" has "$out" "mode: always-full (default)"
check "an unset block prints the default file limit" has "$out" "fast_lane.max_files: 2 (default)"
check "an unset block prints the default line limit" has "$out" "fast_lane.max_lines: 200 (default)"
check "an unset block prints the default lite score" has "$out" "lite.min_score: 6 (default)"
check "an unset block warns of nothing" lacks "$out" "WARN"
base_rc=$(doctor)
check "doctor is quiet about an unset block" lacks "$(cat "$work/doctor.out")" "ceremony"

write_config '{"mode": "adaptive", "fast_lane": {"max_lines": 120}}'
out=$(run ceremony)
check "a configured mode is printed as configured" has "$out" "mode: adaptive (configured)"
check "a configured limit is printed as configured" has "$out" "fast_lane.max_lines: 120 (configured)"
check "an unset limit keeps its default" has "$out" "fast_lane.max_files: 2 (default)"

# --- An unknown mode falls back, and doctor warns naming the key ---------------
write_config '{"mode": "sometimes", "fast_lane": {"max_files": 0}}'
out=$(run ceremony)
check "an unknown mode falls back to always-full" has "$out" "mode: always-full (default)"
check "a non-positive limit falls back to its default" has "$out" "fast_lane.max_files: 2 (default)"
rc=$(doctor)
out=$(cat "$work/doctor.out")
check "doctor warns naming ceremony.mode" has "$out" "WARN  ceremony.mode in .nogging/config.json"
check "doctor warns naming the bad limit" has "$out" "WARN  ceremony.fast_lane.max_files in .nogging/config.json"
check "the warning does not change doctor's exit code" is "$rc" "$base_rc"
out=$(run triage "Off-by-one in the page counter" --kind bug --files 2)
check "triage under an unknown mode runs as always-full" has "$out" "mode: always-full (default)"

# --- nogg triage: text output per mode -----------------------------------------
write_config ""
out=$(run triage "Off-by-one in the page counter" --kind bug --files 2)
check "the default names the rules' lane as fast" has "$out" "rules' lane: fast"
check "the default keeps the full spec" has "$out" "effective lane: full"
check "the fired rule is printed" has "$out" "fired: rule 3 (fast): kind is bug, 2 files"

write_config '{"mode": "adaptive"}'
out=$(run triage "Off-by-one in the page counter" --kind bug --files 2)
check "adaptive names the mode as configured" has "$out" "mode: adaptive (configured)"
check "adaptive lets the rules' lane take effect" has "$out" "effective lane: fast"
out=$(run triage "Rotate the API token on expiry" --kind bug --files 1 --security)
check "a security word forces the full spec" has "$out" "effective lane: full"
check "the reason names the trigger word" has "$out" "fired: rule 1 (full): the description holds the trigger word 'token'"
check "every fired rule is printed" has "$out" "fired: rule 1 (full): security is stated"
out=$(run triage "Tidy the help text")
check "missing facts give the lite lane" has "$out" "effective lane: lite"
check "the reason names the missing facts" has "$out" "no kind stated; no file estimate stated"

write_config '{"mode": "always-fast"}'
out=$(run triage "Rotate the API token on expiry" --kind feature --files 9)
check "always-fast still reports the rules' lane" has "$out" "rules' lane: full"
check "always-fast makes every description fast" has "$out" "effective lane: fast"

rc=0; out=$(run triage "Tidy the help text" --files 0) || rc=$?
check "a non-positive file estimate is a usage error" is "$rc" 2
rc=0; out=$(run triage "Tidy the help text" --kind chore) || rc=$?
check "an unknown kind is a usage error" is "$rc" 2

# --- --json: the same as an object, and the same output twice ------------------
write_config '{"mode": "adaptive"}'
out=$(run triage "Off-by-one in the page counter" --kind bug --files 2 --json)
check "--json prints mode, lanes and reasons" python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d == {"description": "Off-by-one in the page counter", "mode": "adaptive",
             "mode_source": "configured", "rules_lane": "fast", "effective_lane": "fast",
             "reasons": ["rule 3 (fast): kind is bug, 2 files"]}, d' "$out"
check "the same input gives the same output" is "$out" \
  "$(run triage "Off-by-one in the page counter" --kind bug --files 2 --json)"
check "triage without --bead never calls bd" test ! -e "$bd_log"

# --- --bead: the reasons land on the Bead ---------------------------------------
out=$(run triage "Off-by-one in the page counter" --kind bug --files 2 --bead SPEC-ab12)
check "--bead confirms the Bead" has "$out" "recorded on SPEC-ab12"
want=$'update\x1fSPEC-ab12\x1f--append-notes\x1ftriage: fast (mode adaptive; rules: fast): rule 3 (fast): kind is bug, 2 files'
check "the Bead's note gains exactly one triage line" is "$(cat "$bd_log")" "$want"
out=$(run triage "Tidy the help text" --bead SPEC-ab12 --json)
check "--bead with --json names the Bead in the object" has "$out" '"bead": "SPEC-ab12"'

rm -f "$bd_log"
rc=0; out=$(run triage "Tidy the help text" --bead=--force) || rc=$?
check "an option-like Bead ID is refused" is "$rc" 1
check "a refused Bead ID never reaches bd" test ! -e "$bd_log"
touch "$work/bd-fails"
rc=0; out=$(run triage "Tidy the help text" --bead SPEC-zz99) || rc=$?
check "a failed note append fails triage" is "$rc" 1
check "a failed note append prints no lane" lacks "$out" "effective lane"

# --- shipped surface -------------------------------------------------------------
repo_root="$(dirname "$here")"
if [[ -f "$repo_root/bin/lib/manifest.js" ]]; then
  check "manifest.js ships scripts/lib/ceremony.py" grep -q "'scripts/lib/ceremony.py'" "$repo_root/bin/lib/manifest.js"
  check "package files list ships scripts/lib/ceremony.py" grep -q '"scripts/lib/ceremony.py"' "$repo_root/package.json"
  check "templates/nogging-config.json leaves the key out" lacks "$(cat "$repo_root/templates/nogging-config.json")" "ceremony"
else
  echo "ok   - shipped-surface checks skipped (installed consumer copy)"
fi

if [[ $fail -ne 0 ]]; then echo "ceremony-cli: FAILED"; exit 1; fi
echo "ceremony-cli: ok"
