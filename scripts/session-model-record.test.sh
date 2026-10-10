#!/usr/bin/env bash
# Regression checks for recording and displaying session model selection
# (TASK-SCM-003).
#
# Covered:
#   - the session record carries `requested_model`, `model_source` and
#     `reasoning_effort` for `--model` (launch), a profile model (profile)
#     and a legacy profile (runtime-default, null model — never an invented
#     effective model);
#   - `session list` shows MODEL / MODEL_SOURCE, `runtime-default` for a
#     legacy launch, and `-` for a record written before these keys existed;
#   - a per-launch `--model` override leaves the profile file, the user-global
#     Claude/Codex/Pi settings and the Claude effective-settings copy untouched
#     (the model is an argv element, never a settings write).
#
# tmux and bd are PATH-injected stubs; no real session is ever started.
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
if [[ "${1:-}" == "show" ]]; then printf '[{"id":"%s","title":"stub"}]\n' "${2:-}"; exit 0; fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
echo "stub bd: refusing $*" >&2; exit 1
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"
case "$cmd" in
  has-session) exit 1 ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
export PATH="$work/bin:$PATH"

# A fake user-global runtime configuration that a launch must never touch.
export HOME="$work/home"
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.pi/agent"
echo '{"model":"global-claude-model"}' >"$HOME/.claude/settings.json"
printf 'model = "global-codex-model"\nmodel_reasoning_effort = "low"\n' >"$HOME/.codex/config.toml"
echo '{"defaultModel":"global-pi-model"}' >"$HOME/.pi/agent/settings.json"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/scripts" "$r/openspec" "$r/.pi/extensions"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$r/scripts/"
  cp "$repo_root/.pi/extensions/nogging-guard.ts" "$r/.pi/extensions/"
  git init -q "$r"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$r/.nogging/"
  python3 - "$repo_root/.nogging/config.json" "$r/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None)
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
}

snapshot() {  # snapshot <root> -> hashes of every file a launch must not mutate
  (cd "$1" && find .nogging/launch-profiles -type f -print0 | sort -z | xargs -0 sha256sum)
  find "$HOME" -type f -print0 | sort -z | xargs -0 sha256sum
}

n=0
# launch <label> <launch args...>: one launch in a fresh root; sets $root.
launch() {
  local label="$1"; shift
  n=$((n + 1))
  root="$work/r$n"; make_root "$root"
  export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/t$n"
  mkdir -p "$TMUX_STUB_DIR"
  if [[ -n "${PROFILE_BODY:-}" ]]; then
    printf '%s\n' "$PROFILE_BODY" >"$root/.nogging/launch-profiles/$PROFILE_NAME"
    set -- "$@" --profile "$root/.nogging/launch-profiles/$PROFILE_NAME"
  fi
  unset PROFILE_BODY PROFILE_NAME
  snapshot "$root" >"$work/before"
  if "$nogg" session launch --role lead --bead SPEC-mdl "$@" >"$out" 2>&1; then
    ok "$label: launched"
  else
    bad "$label: launch errored"; return 0
  fi
  snapshot "$root" >"$work/after"
  if diff -q "$work/before" "$work/after" >/dev/null; then
    ok "$label: profiles and user-global runtime settings unchanged"
  else
    bad "$label: launch mutated a profile or global setting"; diff "$work/before" "$work/after" || true
  fi
}
# record <label> <python expression over `r`, the single session record>
record() {
  python3 - "$root/.nogging/state/sessions" "$2" <<'PY' && ok "$1" || { echo "FAIL - $1"; fail=1; }
import json, pathlib, sys
recs = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")
        if not p.name.endswith(".settings.json")]
assert len(recs) == 1, recs
r = recs[0]
assert eval(sys.argv[2]), {k: r.get(k) for k in ("requested_model", "model_source", "reasoning_effort")}
PY
}
listing() {  # listing <label> <regex expected on the session's row>
  NOGGING_ROOT="$root" "$nogg" session list >"$out" 2>&1 || { bad "$1: session list errored"; return 0; }
  grep -qE -- "$2" "$out" && ok "$1" || bad "$1 (expected /$2/)"
}

claude_model='{"permissions":{"defaultMode":"default","deny":[]},"model":"claude-opus-5-5"}'

# --- launch override beats the profile model --------------------------------
PROFILE_NAME=m.json PROFILE_BODY="$claude_model" launch "claude-override" --model claude-sonnet-5-5
record "claude-override: record has the override with source launch" \
  'r["requested_model"] == "claude-sonnet-5-5" and r["model_source"] == "launch" and r["reasoning_effort"] is None'
listing "claude-override: list shows the model and source launch" "claude-sonnet-5-5 +launch "
grep -qF '"model":"claude-opus-5-5"' "$root/.nogging/launch-profiles/m.json" \
  && ok "claude-override: profile still names its own model" || bad "claude-override: profile model changed"
python3 - "$root/.nogging/state/sessions" <<'PY' && ok "claude-override: effective settings carry no model key" || { echo "FAIL - claude-override: model written into settings"; fail=1; }
import json, pathlib, sys
files = list(pathlib.Path(sys.argv[1]).glob("*.settings.json"))
assert files and all("model" not in json.loads(f.read_text()) for f in files)
PY

# --- profile model --------------------------------------------------------------
PROFILE_NAME=m.json PROFILE_BODY="$claude_model" launch "claude-profile"
record "claude-profile: record has the profile model with source profile" \
  'r["requested_model"] == "claude-opus-5-5" and r["model_source"] == "profile"'
listing "claude-profile: list shows source profile" "claude-opus-5-5 +profile "

codex_body='sandbox = "workspace-write"
ask_for_approval = "on-request"
network_access = false
model = "gpt-6-sol"
model_reasoning_effort = "high"'
PROFILE_NAME=m.codex.toml PROFILE_BODY="$codex_body" launch "codex-override" --agent codex --model gpt-6-luna
record "codex-override: record has override and effort" \
  'r["requested_model"] == "gpt-6-luna" and r["model_source"] == "launch" and r["reasoning_effort"] == "high"'
listing "codex-override: list shows model, effort and source" "gpt-6-luna effort=high +launch "

launch "pi-override" --agent pi --model pi-model-x
record "pi-override: record has the override" \
  'r["requested_model"] == "pi-model-x" and r["model_source"] == "launch"'

# --- legacy profiles: runtime default, nothing invented ---------------------
launch "legacy-claude" --full-access
record "legacy-claude: record has null model and source runtime-default" \
  'r["requested_model"] is None and r["model_source"] == "runtime-default" and r["reasoning_effort"] is None'
listing "legacy-claude: list honestly shows runtime-default" "runtime-default +runtime-default "
launch "legacy-codex" --agent codex
record "legacy-codex: record has source runtime-default" \
  'r["requested_model"] is None and r["model_source"] == "runtime-default"'

# --- a record from before model selection was recorded ----------------------
listing "list has MODEL and MODEL_SOURCE columns" "MODEL +MODEL_SOURCE +WORKING_DIR"
python3 - "$root/.nogging/state/sessions" <<'PY'
import json, pathlib, sys
for p in pathlib.Path(sys.argv[1]).glob("*.json"):
    if p.name.endswith(".settings.json"): continue
    r = json.loads(p.read_text())
    for k in ("requested_model", "model_source", "reasoning_effort"): r.pop(k, None)
    p.write_text(json.dumps(r))
PY
NOGGING_ROOT="$root" "$nogg" session list >"$out" 2>&1
grep "sf-\|nogg-" "$out" | grep -qE -- " codex +[^ ]+ +- +- +/" \
  && ok "pre-existing record: list shows - for model and source" || bad "pre-existing record display"

exit "$fail"
