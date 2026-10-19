#!/usr/bin/env bash
# `session launch --tier` honours `.nogging/config.json` tier_overrides (TASK-TEO-002).
#
# Covered, through the real CLI with PATH-injected tmux and bd stubs and the
# shared agent stubs (no real session, runtime or network):
#   - an override replaces only the effort of exactly the (tier, agent) it names,
#     for Claude (wrapper --effort) and Codex (--reasoning-effort), never the model;
#   - precedence: explicit --effort > override > table > profile;
#   - the record stores reasoning_effort_source project, selection_tier_effort
#     as the effective effort and selection_tier_effort_source project/table
#     (null for Antigravity); an explicit --effort stays launch;
#   - `session list` shows `effort=<level> (project) tier=<tier>`;
#   - an exact Claude resume keeps the recorded override effort and never re-reads
#     tier_overrides; a Codex resume re-resolves, so it follows the current block;
#   - a malformed block refuses --tier launches before any side effect, and a
#     launch without --tier never looks at it;
#   - legacy records without selection_tier_effort_source read as table.
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
if [[ "$cmd" == new-session ]]; then a=("$@"); for i in "${!a[@]}"; do [[ "${a[i]}" == -s ]] && : >"$d/live-${a[i+1]}"; done; fi
case "$cmd" in
  has-session) [[ -e "$d/live-${2:-}" ]] || exit 1 ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; stub_agent_binaries "$work/bin"
export PATH="$work/bin:$PATH"
export HOME="$work/home"
mkdir -p "$HOME/.gemini/antigravity-cli"
printf '{"toolPermission":"request-review"}\n' >"$HOME/.gemini/antigravity-cli/settings.json"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/scripts/hooks" "$r/openspec" "$r/.pi/extensions" "$r/.agents"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$repo_root/scripts/nogg" "$r/scripts/"
  cp "$repo_root/scripts/hooks/agy-guard" "$r/scripts/hooks/"
  cp "$repo_root/templates/antigravity/hooks.json" "$r/.agents/hooks.json"
  cp "$repo_root/.pi/extensions/nogging-guard.ts" "$r/.pi/extensions/"
  git init -q "$r"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$r/.nogging/"
  cp "$repo_root/templates/model-selection.json" "$r/.nogging/model-selection.json"
  python3 - "$repo_root/.nogging/config.json" "$r/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None)
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
}

n=0
new_root() {
  n=$((n + 1)); root="$work/r$n"; make_root "$root"
  export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/t$n"; mkdir -p "$TMUX_STUB_DIR"
}
run_launch() { "$nogg" session launch --role lead --bead SPEC-tier --cwd "$root" "$@" >"$out" 2>&1; }
# launch_ok <label> <args...>: fresh root, launch must succeed.
launch_ok() {
  local label="$1"; shift; new_root
  if run_launch "$@"; then ok "$label: launched"; else bad "$label: launch errored"; fi
}
# launch_refused <label> <expected text> <args...>: refusal before side effects.
launch_refused() {
  local label="$1" expect="$2"; shift 2
  [[ -n "${root:-}" && "${KEEP_ROOT:-}" == 1 ]] || new_root
  local sessions_before tmux_before
  sessions_before=$(ls -A "$root/.nogging/state/sessions" 2>/dev/null || true)
  tmux_before=$(grep -cF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null || true)
  if run_launch "$@"; then bad "$label: launch should be refused"; return; fi
  grep -qF -- "$expect" "$out" && ok "$label: refused naming '$expect'" || bad "$label: wrong refusal"
  [[ "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null || true)" == "$sessions_before" ]] \
    && ok "$label: no session record or settings file" || bad "$label: session state left behind"
  [[ "$(grep -cF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null || true)" == "$tmux_before" ]] \
    && ok "$label: no tmux session" || bad "$label: tmux new-session reached"
  [[ -z "$(ls "$work" | grep -E -- "-plan-" || true)" ]] || bad "$label: worktree allocated"
}
argv() { grep -F "new-session" "$TMUX_STUB_DIR/calls.log" | tail -1; }
has() { argv | grep -qF -- "$2" && ok "$1" || { bad "$1 (missing: $2)"; argv; }; }
lacks() { argv | grep -qF -- "$2" && { bad "$1 (present: $2)"; argv; } || ok "$1"; }
record() { python3 -c 'import json,sys,glob; print(json.load(open(sorted(p for p in glob.glob(sys.argv[1]+"/.nogging/state/sessions/*.json") if not p.endswith(".settings.json"))[-1])).get(sys.argv[2]))' "$root" "$1"; }
expect_record() { [[ "$(record "$2")" == "$3" ]] && ok "$1" || { echo "  got: $(record "$2")" >"$out"; bad "$1"; }; }


set_overrides() {  # set_overrides <json>: write tier_overrides into the root's config
  python3 - "$root/.nogging/config.json" "$1" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1])); cfg["tier_overrides"] = json.loads(sys.argv[2])
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
}
override_root() { new_root; set_overrides "$1"; }
override_ok() { local label="$1" json="$2"; shift 2; override_root "$json"
  if run_launch "$@"; then ok "$label: launched"; else bad "$label: launch errored"; fi; }

complex_json='{"complex":{"claude":{"effort":"medium"},"codex":{"effort":"low"}}}'

# --- override replaces the table effort, never the model ---------------------
override_ok "claude-override" "$complex_json" --full-access --tier complex
has "claude-override: table model kept" "--model claude-opus-5-5"
has "claude-override: override effort forwarded" "--effort medium"
expect_record "claude-override: reasoning_effort" reasoning_effort medium
expect_record "claude-override: effort source project" reasoning_effort_source project
expect_record "claude-override: selection_tier_effort effective" selection_tier_effort medium
expect_record "claude-override: tier effort source project" selection_tier_effort_source project
expect_record "claude-override: selection_tier" selection_tier complex

override_ok "codex-override" "$complex_json" --agent codex --full-access --tier complex
has "codex-override: table model kept" "--model gpt-6.1-sol"
has "codex-override: override effort forwarded" "--reasoning-effort low"
lacks "codex-override: table effort not forwarded" "--reasoning-effort high"
expect_record "codex-override: reasoning_effort" reasoning_effort low
expect_record "codex-override: effort source project" reasoning_effort_source project
expect_record "codex-override: selection_tier_effort effective" selection_tier_effort low
expect_record "codex-override: tier effort source project" selection_tier_effort_source project
"$nogg" session list >"$out" 2>&1
grep -E "SPEC-tier .*gpt-6.1-sol effort=low \(project\) tier=complex" "$out" >/dev/null \
  && ok "codex-override: list shows (project)" || bad "codex-override: list"

# --- only the named (tier, agent) is affected --------------------------------
override_ok "other-agent" '{"complex":{"codex":{"effort":"low"}}}' --full-access --tier complex
has "other-agent: claude keeps table effort" "--effort xhigh"
expect_record "other-agent: effort source launch (table)" reasoning_effort_source launch
expect_record "other-agent: tier effort source table" selection_tier_effort_source table
override_ok "other-tier" '{"complex":{"claude":{"effort":"medium"}}}' --full-access --tier standard
has "other-tier: standard keeps table effort" "--effort high"
expect_record "other-tier: tier effort source table" selection_tier_effort_source table
override_ok "antigravity-untouched" "$complex_json" --agent agy --full-access --tier complex
expect_record "antigravity: tier effort source null" selection_tier_effort_source None
lacks "antigravity: no effort flag" "--reasoning-effort"

# --- precedence: explicit --effort > override > table > profile -------------
override_ok "claude-explicit-over-override" "$complex_json" --full-access --tier complex --effort max
has "claude-explicit-over-override: explicit wins" "--effort max"
expect_record "claude-explicit-over-override: source launch" reasoning_effort_source launch
expect_record "claude-explicit-over-override: tier effort still the override" selection_tier_effort medium
expect_record "claude-explicit-over-override: tier effort source project" selection_tier_effort_source project
override_ok "claude-explicit-equal-override" "$complex_json" --full-access --tier complex --effort medium
expect_record "claude-explicit-equal-override: stays launch" reasoning_effort_source launch
override_ok "codex-explicit-over-override" "$complex_json" --agent codex --full-access --tier complex --effort high
has "codex-explicit-over-override: explicit wins" "--reasoning-effort high"
expect_record "codex-explicit-over-override: source launch" reasoning_effort_source launch
override_ok "codex-model-keeps-override" "$complex_json" --agent codex --full-access --tier complex --model gpt-6-luna
has "codex-model-keeps-override: explicit model" "--model gpt-6-luna"
has "codex-model-keeps-override: override effort kept" "--reasoning-effort low"
expect_record "codex-model-keeps-override: source project" reasoning_effort_source project

override_root "$complex_json"
printf '%s\n' '{"permissions":{"defaultMode":"default","deny":[]},"effort":"low"}' >"$root/pe.json"
run_launch --profile "$root/pe.json" --tier complex && ok "claude-override-over-profile: launched" \
  || bad "claude-override-over-profile: launch errored"
expect_record "claude-override-over-profile: override beats profile" reasoning_effort medium
expect_record "claude-override-over-profile: source project" reasoning_effort_source project

# --- without --tier the block is never consulted -----------------------------
override_ok "no-tier" "$complex_json" --full-access
lacks "no-tier: no effort flag" "--effort"
expect_record "no-tier: source runtime-default" reasoning_effort_source runtime-default
expect_record "no-tier: tier effort source null" selection_tier_effort_source None
override_root '{"complex":{"codex":{"effort":"turbo"}}}'
run_launch --full-access && ok "no-tier-malformed: launch ignores block" || bad "no-tier-malformed: launch refused"

# --- a malformed block refuses --tier launches before any side effect -------
override_root '{"complex":{"codex":{"effort":"turbo"}}}'
KEEP_ROOT=1 launch_refused "malformed-claude" "tier_overrides.complex.codex.effort" --full-access --tier standard
grep -qF "models check" "$out" && ok "malformed-claude: remedy given" || bad "malformed-claude: remedy"
override_root '{"complex":{"codex":{"model":"x"}}}'
KEEP_ROOT=1 launch_refused "malformed-codex" "tier_overrides.complex.codex" --agent codex --full-access --tier complex
override_root '{"complex":{"pi":{"effort":"low"}}}'
KEEP_ROOT=1 launch_refused "malformed-agy" "unknown agent 'pi'" --agent agy --full-access --tier routine

# --- exact resume ------------------------------------------------------------
override_root "$complex_json"
run_launch --full-access --tier complex || bad "resume: first launch"
sid=$(record claude_session_id)
set_overrides '{"complex":{"claude":{"effort":"low"}}}'
: >"$TMUX_STUB_DIR/calls.log"
run_launch --full-access --tier complex --resume "$sid" && ok "resume: launched" || bad "resume: launch errored"
has "resume: recorded override effort kept" "--effort medium"
lacks "resume: changed block not re-read" "--effort low"
set_overrides '{"complex":{"claude":{"effort":"turbo"}}}'
run_launch --full-access --tier complex --resume "$sid" && ok "resume: malformed block not re-read" \
  || bad "resume: malformed block consulted"

# Codex resume re-resolves --tier against the current table and block (the
# existing path has no recorded-selection branch for Codex), so it follows the block.
cat >"$work/bin/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == resume && "${2:-}" == --help ]]; then cat "$RESUME_HELP"; exit 0; fi
if [[ "${1:-}" == --help ]]; then
  printf 'Usage: codex [OPTIONS]\n  --cd <DIR>\n  --sandbox <MODE>\n  --ask-for-approval <POLICY>\n  --add-dir <DIR>\n  --model <MODEL>\n  -c, --config <key=value>\n'
  exit 0
fi
exit 0
STUB
export RESUME_HELP="$here/fixtures/codex/codex-resume-help.txt"
override_root "$complex_json"
run_launch --agent codex --full-access --tier complex --resume 019f0000-0000-7000-8000-000000000001 \
  && ok "codex-resume: launched" || bad "codex-resume: launch errored"
has "codex-resume: resumes the exact thread" "--resume 019f0000-0000-7000-8000-000000000001"
has "codex-resume: current override applied" "--reasoning-effort low"
expect_record "codex-resume: source project" reasoning_effort_source project

# --- legacy records read as table, never rewritten ---------------------------
new_root; mkdir -p "$root/.nogging/state/sessions"
cat >"$root/.nogging/state/sessions/legacy.json" <<'LEG'
{"name": "legacy", "bead_id": "SPEC-old", "role": "lead", "state": "ended",
 "started_at": "2026-01-01T00:00:00+00:00", "working_dir": "/x", "agent": "claude",
 "claude_session_id": "22222222-2222-4222-8222-222222222222",
 "requested_model": "old-model", "model_source": "launch", "reasoning_effort": "high",
 "reasoning_effort_source": "launch", "selection_tier": "standard", "selection_tier_effort": "high"}
LEG
before=$(sha256sum <"$root/.nogging/state/sessions/legacy.json")
"$nogg" session list >"$out" 2>&1
grep -E "^legacy .*old-model effort=high \(launch\) tier=standard" "$out" >/dev/null \
  && ok "legacy: list unchanged" || bad "legacy: list"
run_launch --full-access --tier standard --resume 22222222-2222-4222-8222-222222222222 \
  && ok "legacy-resume: launched" || bad "legacy-resume: errored"
has "legacy-resume: recorded effort kept" "--effort high"
expect_record "legacy-resume: source read as table" selection_tier_effort_source table
[[ "$(sha256sum <"$root/.nogging/state/sessions/legacy.json")" == "$before" ]] \
  && ok "legacy: record not rewritten" || bad "legacy: record rewritten"

exit "$fail"
