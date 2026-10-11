#!/usr/bin/env bash
# `nogg token-usage` CLI (TASK-TUC-005) through the real CLI with PATH-injected
# tmux and bd stubs (no real runtime is started):
#   - report/status on an absent store answer honestly (store absent,
#     local-only sync) without creating it;
#   - invalid windows, filters and unknown sessions refuse with a remedy;
#   - `collect --session` imports one supervised session; report (day,
#     session, filters), session inspection and status emit versioned JSON
#     with as-of, coverage, pending and sync fields; text output renders;
#   - export -> import into a fresh store reproduces totals, and re-importing
#     or re-collecting adds nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
  printf '[{"id":"%s","title":"stub","labels":["openspec:change:demo-change","openspec:task:TASK-DEMO-001"]}]\n' "${2:-}"
  exit 0
fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
echo "stub bd: refusing $*" >&2; exit 1
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
case "$cmd" in has-session) exit 1 ;; *) : ;; esac
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
export PATH="$work/bin:$PATH" HOME="$work/home"
mkdir -p "$HOME"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }
expect() { [[ "$2" == "$3" ]] && ok "$1" || { echo "  got: $2 want: $3" >"$out"; bad "$1"; }; }

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/scripts/hooks" "$r/openspec"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$repo_root/scripts/nogg" "$r/scripts/"
  cp -r "$repo_root/scripts/lib" "$r/scripts/lib"
  git init -q -b develop "$r"
  git -C "$r" -c user.name=Test -c user.email=test@example.org commit -q --allow-empty -m init
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$r/.nogging/"
  cp "$repo_root/templates/model-selection.json" "$r/.nogging/model-selection.json"
  python3 - "$repo_root/.nogging/config.json" "$r/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None)
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
}
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$out" "$1"; }

root="$work/repo"; make_root "$root"; export NOGGING_ROOT="$root"
usage="$root/.nogging/state/token-usage"

# --- absent store ------------------------------------------------------------
"$nogg" token-usage report --json >"$out" 2>&1 && ok "report on an absent store" || bad "absent report"
expect "absent store is reported" "$(j 'd["store"], d["rows"], d["sync"]["local_only"], d["schema"]')" \
  "('absent', [], True, 'nogg.token-usage.report/v1')"
[[ ! -e "$usage/database" ]] && ok "report did not create the store" || bad "report created a store"
"$nogg" token-usage status --json >"$out" 2>&1 && expect "status on an absent store" "$(j 'd["store"]')" "absent" || bad "absent status"

# --- refusals ------------------------------------------------------------------
refuse() {
  local label="$1" text="$2"; shift 2
  if "$nogg" token-usage "$@" >"$out" 2>&1; then bad "$label should refuse"
  else grep -qF -- "$text" "$out" && ok "$label refused with remedy" || bad "$label refusal text"; fi
}
refuse "naive time" "no UTC offset" report --from 2026-10-11T00:00:00 --to 2026-10-12T00:00:00Z
refuse "inverted window" "earlier than --to" report --from 2026-10-12 --to 2026-10-11
refuse "half window" "both --from and --to" report --from 2026-10-11
refuse "bad complexity" "--complexity must be one of" report --complexity hard
refuse "unknown collect session" "no supervised session named" collect --session nope

# --- collect one supervised session --------------------------------------------
"$nogg" session launch --role lead --bead SPEC-cli --cwd "$root" --full-access --complexity standard >"$out" 2>&1 \
  || bad "launch"
rec=$(ls -t "$root/.nogging/state/sessions"/*.json | grep -v settings | head -1)
name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$rec")
claude_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["claude_session_id"])' "$rec")
started=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["started_at"])' "$rec")
project="$HOME/.claude/projects/$(python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))' "$root")"
mkdir -p "$project"
python3 - "$project/$claude_id.jsonl" "$claude_id" "$started" <<'PY'
import datetime as dt, json, sys
base = dt.datetime.fromisoformat(sys.argv[3])
with open(sys.argv[1], "w") as fh:
    for i, model in enumerate(("claude-a", "claude-b")):
        ts = (base + dt.timedelta(seconds=1 + i)).isoformat()
        fh.write(json.dumps({"type": "assistant", "sessionId": sys.argv[2], "timestamp": ts,
                             "message": {"id": f"msg_{i}", "role": "assistant", "model": model,
                                         "usage": {"input_tokens": 5, "cache_read_input_tokens": 100,
                                                   "cache_creation_input_tokens": 7, "output_tokens": 11}}}) + "\n")
PY
"$nogg" token-usage collect --session "$name" --json >"$out" 2>&1 && ok "collect --session" || bad "collect"
expect "collect imported without error" "$(j 'd["schema"], d["error"], d["spooled_batches"]')" \
  "('nogg.token-usage.collect/v1', None, 0)"

if ! command -v dolt >/dev/null 2>&1; then ok "dolt not installed; store-backed CLI checks skipped"; exit "$fail"; fi
day=$(python3 -c 'import sys; print(sys.argv[1][:10])' "$started")
next=$(python3 -c 'import datetime as d,sys; print(d.date.fromisoformat(sys.argv[1]) + d.timedelta(days=1))' "$day")
"$nogg" token-usage report --from "$day" --to "$next" --json >"$out" 2>&1 && ok "day report" || bad "day report"
expect "day totals and coverage" "$(j 'd["rows"][0]["events"], d["rows"][0]["tokens"]["input_tokens"], d["coverage"]["unknown_model"], d["pending"]["spooled_batches"], "as_of" in d')" \
  "(2, 224, 0, 0, True)"
"$nogg" token-usage report --from "$day" --to "$next" --group-by session --complexity standard --task TASK-DEMO-001 --json >"$out" 2>&1 \
  && expect "session rows keep models, task and complexity" \
       "$(j 'd["rows"][0]["session"], sorted(d["rows"][0]["by_model"]), d["rows"][0]["attribution"][0]["task_id"], d["rows"][0]["attribution"][0]["complexity"]')" \
       "('$name', ['claude-a', 'claude-b'], 'TASK-DEMO-001', 'standard')" || bad "session report"
"$nogg" token-usage report --from "$day" --to "$next" --model claude-b --json >"$out" 2>&1 \
  && expect "model filter" "$(j 'd["rows"][0]["events"], d["rows"][0]["wall_runtime_ms"]')" "(1, None)" || bad "model filter"
"$nogg" token-usage report --from "$day" --to "$next" --complexity routine --json >"$out" 2>&1 \
  && expect "non-matching complexity" "$(j 'd["rows"]')" "[]" || bad "complexity filter"
"$nogg" token-usage report --from "$day" --to "$next" >"$out" 2>&1 && grep -qF "not billed cost" "$out" \
  && ok "text report renders with notes" || bad "text report"
"$nogg" token-usage session "$name" --json >"$out" 2>&1 \
  && expect "session inspection" "$(j 'd["schema"], d["totals"]["events"], d["attribution"][0]["complexity_source"]')" \
       "('nogg.token-usage.session/v1', 2, 'launch')" || bad "session inspect"
"$nogg" token-usage session "$name" >"$out" 2>&1 && grep -qF "model claude-b" "$out" && ok "text session renders" || bad "text session"
"$nogg" token-usage status --json >"$out" 2>&1 \
  && expect "status" "$(j 'd["store"], d["current_facts"]["usage_events"], d["sync"]["state"]')" "('present', 2, 'not_configured')" \
  || bad "status"

# --- export -> recovery ----------------------------------------------------------
"$nogg" token-usage export --from "$day" --to "$next" >"$work/export.jsonl" 2>"$out" && ok "export" || bad "export"
! grep -q '"content"\|"text"' "$work/export.jsonl" && ok "export carries no transcript content" || bad "export content"
other="$work/other"; make_root "$other"
NOGGING_ROOT="$other" "$nogg" token-usage import --file "$work/export.jsonl" --json >"$out" 2>&1 \
  && ok "import into a fresh store" || bad "import"
NOGGING_ROOT="$other" "$nogg" token-usage import --file "$work/export.jsonl" --json >"$out" 2>&1 \
  && expect "re-import adds nothing" "$(j 'd["added"]')" "0" || bad "re-import"
NOGGING_ROOT="$other" "$nogg" token-usage report --from "$day" --to "$next" --json >"$out" 2>&1 \
  && expect "recovered totals match" "$(j 'd["rows"][0]["events"], d["rows"][0]["tokens"]["input_tokens"]')" "(2, 224)" \
  || bad "recovered report"
sed 's/"input_tokens": 112/"input_tokens": 999/' "$work/export.jsonl" >"$work/tampered.jsonl"
NOGGING_ROOT="$other" "$nogg" token-usage import --file "$work/tampered.jsonl" >"$out" 2>&1 \
  && bad "tampered import should refuse" || { grep -qF "does not reproduce" "$out" && ok "tampered import refused" || bad "tamper text"; }
"$nogg" token-usage collect --session "$name" --json >"$out" 2>&1
"$nogg" token-usage report --from "$day" --to "$next" --json >"$out" 2>&1 \
  && expect "re-collection does not double charge" "$(j 'd["rows"][0]["tokens"]["input_tokens"]')" "224" || bad "recollect"

exit "$fail"
