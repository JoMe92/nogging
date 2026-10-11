#!/usr/bin/env bash
# Doctor model-selection drift NOTEs (TASK-MES-003).
#
# Covered, with a fixture Codex catalog (CODEX_HOME) and a PATH-injected `agy`
# stub (the host's real tools are kept off PATH):
#   - present sources listing every table model: no drift NOTE;
#   - a Codex or Antigravity table model absent from its source: a NOTE naming
#     agent, tier and model;
#   - unavailable sources (catalog absent or malformed, agy not installed,
#     non-zero, timed out, empty) are reported as unavailable, never as drift;
#   - an installed table older than the packaged one, and an invalid table,
#     each yield a NOTE; the packaged version constant matches the template;
#   - a full `doctor` run prints the NOTEs and exits exactly as it does
#     without drift.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
template="$repo_root/templates/model-selection.json"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

mkdir -p "$work/bin" "$work/noagy"
cat >"$work/bin/agy" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "models" ]] || exit 2
case "${AGY_STUB_MODE:-ok}" in
  fail) echo "agy: not signed in" >&2; exit 3 ;;
  hang) sleep 5 ;;
  empty) echo "Fetching available models..." ;;
  *) echo "Fetching available models..."; cat "${AGY_STUB_LIST:?}" ;;
esac
STUB
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in list) echo '[]' ;; *) echo '[]' ;; esac
STUB
cat >"$work/bin/dolt" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$work/bin/"*
for tool in bd dolt; do ln -s "$work/bin/$tool" "$work/noagy/$tool"; done
# Only individual tools join PATH, never their directories: a host agy often
# shares a directory (e.g. ~/.local/bin) with them.
mkdir -p "$work/tools"; base_path="$work/tools:/usr/local/bin:/usr/bin:/bin"
for tool in node npm tmux; do
  p=$(command -v "$tool" 2>/dev/null || true); [[ -n "$p" ]] && ln -s "$p" "$work/tools/$tool"
done
if [[ -x /usr/local/bin/agy || -x /usr/bin/agy || -x /bin/agy ]]; then
  echo "SKIP: a system-wide agy cannot be hidden from the drift fixtures"; exit 0
fi
with_agy="$work/bin:$base_path"; without_agy="$work/noagy:$base_path"

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/.nogging/locks" "$r/openspec/changes"
  cp "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  python3 - "$r/.nogging/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["doctor_agy_models_timeout_seconds"] = 1
json.dump(c, open(sys.argv[1], "w"), indent=2)
PY
  cp "$template" "$r/.nogging/model-selection.json"
  git -C "$r" init -q
}
# Fixture sources that list every table model plus unrelated ones.
mkdir -p "$work/codex-home"
python3 - "$template" "$work/codex-home/models_cache.json" "$work/agy-list" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))["agents"]
codex = sorted({e["model"] for e in t["codex"].values()} | {"gpt-other"})
json.dump({"fetched_at": "x", "models": [{"slug": s, "display_name": s} for s in codex]},
          open(sys.argv[2], "w"))
agy = sorted({e["model"] for e in t["antigravity"].values()} | {"gemini-other-low"})
open(sys.argv[3], "w").write("".join(f"{m}\t{m} display\n" for m in agy))
PY
export CODEX_HOME="$work/codex-home" AGY_STUB_LIST="$work/agy-list"

# notes <root> <PATH>: print model_selection_notes(), one per line.
notes() {
  NOGGING_ROOT="$1" PATH="$2" python3 - "$nogg" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg_drift", sys.argv[1]).load_module()
for note in m.model_selection_notes():
    print(note)
PY
}
expect() {  # expect <label> <present|absent> <text>
  if grep -qF -- "$3" "$out"; then [[ "$2" == present ]] && ok "$1" || bad "$1"
  else [[ "$2" == absent ]] && ok "$1" || bad "$1"; fi
}

r="$work/present"; make_root "$r"
notes "$r" "$with_agy" >"$out"
[[ ! -s "$out" ]] && ok "present sources listing every model: no NOTE" || bad "present sources: unexpected NOTE"

# Absent models.
grep -v '^gemini-3.8-flash-high' "$work/agy-list" >"$work/agy-short"
AGY_STUB_LIST="$work/agy-short" notes "$r" "$with_agy" >"$out"
expect "agy-absent: NOTE names the Antigravity complex model" present \
  "antigravity complex model gemini-3.8-flash-high is not listed by \`agy models\`"
expect "agy-absent: other tiers not flagged" absent "antigravity routine"
mkdir -p "$work/codex-short"
python3 - "$work/codex-home/models_cache.json" "$work/codex-short/models_cache.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["models"] = [m for m in d["models"] if m["slug"] != "gpt-6-luna"]
json.dump(d, open(sys.argv[2], "w"))
PY
CODEX_HOME="$work/codex-short" notes "$r" "$with_agy" >"$out"
expect "codex-absent: NOTE names routine" present "codex routine model gpt-6-luna is not listed by the local Codex model catalog"
expect "codex-absent: NOTE names standard" present "codex standard model gpt-6-luna"
expect "codex-absent: complex present" absent "codex complex"

# Unavailable sources are not drift.
CODEX_HOME="$work/nowhere" notes "$r" "$with_agy" >"$out"
expect "codex catalog absent: unavailable" present "codex drift not checked: the local Codex model catalog unavailable"
expect "codex catalog absent: no drift claim" absent "is not listed"
mkdir -p "$work/codex-bad"; printf '{not json' >"$work/codex-bad/models_cache.json"
CODEX_HOME="$work/codex-bad" notes "$r" "$with_agy" >"$out"
expect "codex catalog malformed: unavailable" present "is unreadable"
notes "$r" "$without_agy" >"$out"
expect "agy not installed: unavailable" present "antigravity drift not checked: \`agy models\` unavailable (agy is not installed)"
expect "agy not installed: no drift claim" absent "is not listed"
AGY_STUB_MODE=fail notes "$r" "$with_agy" >"$out"
expect "agy non-zero: unavailable" present "\`agy models\` exited 3"
start=$(date +%s); AGY_STUB_MODE=hang notes "$r" "$with_agy" >"$out"; took=$(( $(date +%s) - start ))
expect "agy hang: bounded and unavailable" present "timed out after 1 s"
(( took < 5 )) && ok "agy probe is bounded (${took}s)" || bad "agy probe not bounded (${took}s)"
AGY_STUB_MODE=empty notes "$r" "$with_agy" >"$out"
expect "agy empty: unavailable" present "listed no models"

# Installed table older than packaged; invalid table.
r="$work/old"; make_root "$r"
python3 - "$r/.nogging/model-selection.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["table_version"] = "2025-01-01"
json.dump(t, open(sys.argv[1], "w"))
PY
notes "$r" "$with_agy" >"$out"
expect "old table: NOTE" present "installed table_version 2025-01-01 is older than the packaged"
r="$work/invalid"; make_root "$r"
python3 - "$r/.nogging/model-selection.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); del t["agents"]["codex"]["complex"]
json.dump(t, open(sys.argv[1], "w"))
PY
notes "$r" "$with_agy" >"$out"
expect "invalid table: NOTE" present "model-selection: model-selection table"
expect "invalid table: launch consequence named" present "session launch --tier\` refuses"

if python3 - "$nogg" "$template" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
const = re.search(r'^PACKAGED_MODEL_SELECTION_TABLE_VERSION = "([^"]+)"', src, re.M).group(1)
assert const == json.load(open(sys.argv[2]))["table_version"], const
PY
then ok "packaged version constant matches templates/model-selection.json"
else bad "packaged version constant matches the template"; fi

# Full doctor: NOTEs are printed and the exit status is unchanged.
r="$work/doctor"; make_root "$r"
clean=0; drift=0
NOGGING_ROOT="$r" PATH="$with_agy" "$nogg" doctor >"$out.clean" 2>&1 || rc=$?; clean=${rc:-0}; unset rc
AGY_STUB_LIST="$work/agy-short" CODEX_HOME="$work/nowhere" NOGGING_ROOT="$r" PATH="$with_agy" \
  "$nogg" doctor >"$out" 2>&1 || rc=$?; drift=${rc:-0}; unset rc
expect "doctor prints the Antigravity drift NOTE" present "NOTE  model-selection: antigravity complex model gemini-3.8-flash-high"
expect "doctor prints the unavailable Codex source" present "NOTE  model-selection: codex drift not checked"
! grep -q "model-selection" "$out.clean" && ok "doctor without drift prints no model-selection NOTE" \
  || { cp "$out.clean" "$out"; bad "doctor without drift"; }
[[ "$clean" == "$drift" ]] && ok "doctor exit status unchanged by drift ($clean)" \
  || { echo "clean=$clean drift=$drift" >"$out"; bad "doctor exit status changed"; }
rm -f "$out.clean"

exit "$fail"
