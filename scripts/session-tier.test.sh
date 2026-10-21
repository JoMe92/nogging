#!/usr/bin/env bash
# `session launch --tier` (TASK-MES-002).
#
# Covered, through the real CLI with PATH-injected tmux and bd stubs (no real
# session or runtime is ever started):
#   - each agent and tier hands the table's model (and Codex effort) to the
#     wrapper as separate argv elements: Claude --model, Codex --model plus
#     --reasoning-effort, Antigravity (and its agy alias) --model;
#   - precedence: --model beats the tier model while the tier still supplies
#     the Codex effort, and an explicit Codex --effort beats the tier effort
#     while the tier stays recorded (selection_tier, selection_tier_effort); the tier beats the profile model and profile effort;
#   - a Claude tier forwards model and effort (wrapper --effort, source
#     launch), an explicit --effort beats the tier, the tier beats profile
#     effort, and a stale helper refuses before any side effect;
#   - an unknown tier, a missing or invalid table, and Pi refuse with a remedy
#     before any session record, settings file or tmux session exists;
#   - records store selection_tier (null without --tier); `session list` shows
#     tier=<tier> and keeps the prior display for legacy records;
#   - without --tier the argv is unchanged;
#   - an exact Claude resume keeps its recorded selection even after the table
#     changes, and refuses a different tier or a conversation with no tier.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

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
  copy_host_config "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  python3 - "$r/.nogging/config.json" "$r/.nogging/config.json" <<'PY'
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

# --- each agent x tier reaches the wrapper as separate argv elements --------
while read -r tier claude claude_effort codex codex_effort agy; do
  launch_ok "claude-$tier" --full-access --tier "$tier"
  has "claude-$tier: table model forwarded" "--model $claude"
  has "claude-$tier: tier effort via --effort" "--effort $claude_effort"
  lacks "claude-$tier: no reasoning-effort flag" "--reasoning-effort"
  ! grep -q "NOTE:" "$out" && ok "claude-$tier: no pending NOTE" || bad "claude-$tier: unexpected NOTE"
  expect_record "claude-$tier: record reasoning_effort" reasoning_effort "$claude_effort"
  expect_record "claude-$tier: effort source launch" reasoning_effort_source launch
  expect_record "claude-$tier: record selection_tier" selection_tier "$tier"
  expect_record "claude-$tier: model source launch" model_source launch

  launch_ok "codex-$tier" --agent codex --full-access --tier "$tier"
  has "codex-$tier: model forwarded" "--model $codex"
  has "codex-$tier: effort via --reasoning-effort" "--reasoning-effort $codex_effort"
  expect_record "codex-$tier: record reasoning_effort" reasoning_effort "$codex_effort"
  ! grep -q "NOTE:" "$out" && ok "codex-$tier: no NOTE" || bad "codex-$tier: unexpected NOTE"

  launch_ok "antigravity-$tier" --agent agy --full-access --tier "$tier"
  has "antigravity-$tier: tier model forwarded" "--model $agy"
  lacks "antigravity-$tier: no effort flag" "--reasoning-effort"
  expect_record "antigravity-$tier: record agent" agent antigravity
  expect_record "antigravity-$tier: record selection_tier" selection_tier "$tier"
done < <(python3 - "$repo_root/templates/model-selection.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))["agents"]
for tier in ("routine", "standard", "complex"):
    print(tier, t["claude"][tier]["model"], t["claude"][tier]["effort"],
          t["codex"][tier]["model"], t["codex"][tier]["effort"], t["antigravity"][tier]["model"])
PY
)

# --- precedence -------------------------------------------------------------
launch_ok "claude-effort-over-tier" --full-access --tier standard --effort max
has "claude-effort-over-tier: explicit --effort wins" "--effort max"
expect_record "claude-effort-over-tier: source launch" reasoning_effort_source launch
expect_record "claude-effort-over-tier: tier still recorded" selection_tier standard
new_root
printf '%s\n' '{"permissions":{"defaultMode":"default","deny":[]},"effort":"low"}' >"$root/pe.json"
run_launch --profile "$root/pe.json" --tier complex && ok "claude-tier-over-profile-effort: launched" \
  || bad "claude-tier-over-profile-effort: launch errored"
expect_record "claude-tier-over-profile-effort: tier effort beats profile" reasoning_effort "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["agents"]["claude"]["complex"]["effort"])' "$root/.nogging/model-selection.json")"
expect_record "claude-tier-over-profile-effort: source launch" reasoning_effort_source launch

# --- stale helper refuses rather than dropping the tier effort ---------------
new_root
python3 - "$root/scripts/session-launch" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace(',"claude-effort-forwarding"', ''))
PY
if run_launch --full-access --tier standard; then bad "stale helper: tier launch accepted"; else
  grep -q "Claude effort forwarding" "$out" && ok "stale helper: refused with update remedy" || bad "stale helper: wrong refusal"
  [[ -z "$(ls "$root/.nogging/state/sessions" 2>/dev/null)" ]] && ok "stale helper: no session record" || bad "stale helper: record left"
fi

launch_ok "codex-model-over-tier" --agent codex --full-access --tier standard --model gpt-x
has "codex-model-over-tier: explicit --model wins" "--model gpt-x"
has "codex-model-over-tier: tier still supplies effort" "--reasoning-effort medium"
lacks "codex-model-over-tier: tier model not forwarded" "gpt-6-luna"

codex_profile='sandbox = "workspace-write"
ask_for_approval = "on-request"
network_access = false
model = "profile-model"
model_reasoning_effort = "xhigh"'
new_root; printf '%s\n' "$codex_profile" >"$root/p.codex.toml"
run_launch --agent codex --profile "$root/p.codex.toml" --tier routine \
  && ok "codex-tier-over-profile: launched" || bad "codex-tier-over-profile: launch errored"
has "codex-tier-over-profile: tier model beats profile" "--model gpt-6-luna"
has "codex-tier-over-profile: tier effort beats profile" "--reasoning-effort low"
lacks "codex-tier-over-profile: profile model unused" "profile-model"
new_root; printf '%s\n' "$codex_profile" >"$root/p.codex.toml"
run_launch --agent codex --profile "$root/p.codex.toml" \
  && ok "codex-profile-without-tier: launched" || bad "codex-profile-without-tier"
has "codex-profile-without-tier: profile model kept" "--model profile-model"
has "codex-profile-without-tier: profile effort kept" "--reasoning-effort xhigh"
expect_record "codex-profile-without-tier: selection_tier null" selection_tier None

new_root
printf '%s\n' '{"permissions":{"defaultMode":"default","deny":[]},"model":"claude-profile"}' >"$root/p.json"
run_launch --profile "$root/p.json" --tier complex && ok "claude-tier-over-profile: launched" \
  || bad "claude-tier-over-profile"
has "claude-tier-over-profile: tier model beats profile" "--model claude-opus-5-5"

# --- without --tier the argv is unchanged ----------------------------------
launch_ok "legacy-claude" --full-access
lacks "legacy-claude: no model flag" "--model"
expect_record "legacy-claude: selection_tier null" selection_tier None
launch_ok "legacy-codex" --agent codex --full-access
lacks "legacy-codex: no model flag" "--model"
lacks "legacy-codex: no effort flag" "--reasoning-effort"

# --- refusals before any side effect ---------------------------------------
launch_refused "unknown-tier" "choose one of routine, standard, complex" --full-access --tier trivial
launch_ok "codex-effort-over-tier" --agent codex --full-access --tier complex --effort low
has "codex-effort-over-tier: tier model kept" "--model gpt-6.1-sol"
has "codex-effort-over-tier: explicit --effort wins" "--reasoning-effort low"
lacks "codex-effort-over-tier: tier effort not forwarded" "--reasoning-effort high"
expect_record "codex-effort-over-tier: reasoning_effort" reasoning_effort low
expect_record "codex-effort-over-tier: effort source launch" reasoning_effort_source launch
expect_record "codex-effort-over-tier: selection_tier kept" selection_tier complex
expect_record "codex-effort-over-tier: table effort kept for attribution" selection_tier_effort low

launch_ok "codex-tier-model-effort" --agent codex --full-access --tier complex --model gpt-6-luna --effort medium
has "codex-tier-model-effort: explicit model" "--model gpt-6-luna"
has "codex-tier-model-effort: explicit effort" "--reasoning-effort medium"
lacks "codex-tier-model-effort: tier model not forwarded" "gpt-6.1-sol"
expect_record "codex-tier-model-effort: selection_tier kept" selection_tier complex
expect_record "codex-tier-model-effort: requested_model" requested_model gpt-6-luna
expect_record "codex-tier-model-effort: model source launch" model_source launch
expect_record "codex-tier-model-effort: reasoning_effort" reasoning_effort medium
expect_record "codex-tier-model-effort: effort source launch" reasoning_effort_source launch
"$nogg" session list >"$out" 2>&1
grep -E "SPEC-tier .*gpt-6-luna effort=medium \(launch\) tier=complex" "$out" >/dev/null \
  && ok "codex-tier-model-effort: list shows tier with model and effort" || bad "codex-tier-model-effort: list"

launch_refused "codex-tier-bad-effort" "must be one of none, minimal, low, medium, high, xhigh, max, ultra" \
  --agent codex --full-access --tier complex --effort turbo

launch_refused "pi-tier" "--tier is not supported for agent 'pi'" --agent pi --tier routine
new_root; rm "$root/.nogging/model-selection.json"
KEEP_ROOT=1 launch_refused "missing-table" "is missing" --agent codex --full-access --tier routine
grep -qF "templates/model-selection.json" "$out" && ok "missing-table: remedy given" || bad "missing-table: remedy"
new_root
python3 - "$root/.nogging/model-selection.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["agents"]["antigravity"]["routine"]["effort"] = "low"
json.dump(t, open(sys.argv[1], "w"))
PY
KEEP_ROOT=1 launch_refused "invalid-table" "agents.antigravity.routine: 'effort' is not allowed" \
  --agent agy --full-access --tier standard
new_root
if "$nogg" session launch --role planning --planning-id tier-x --description refuse-me \
     --full-access --tier huge >"$out" 2>&1; then bad "planning-unknown-tier: launch should be refused"
elif grep -qF "choose one of" "$out" && [[ ! -e "$work/r$n-plan-tier-x-refuse-me" ]] \
     && [[ -z "$(ls -A "$root/.nogging/state" | grep -v '^sessions$' || true)" ]]; then
  ok "planning-unknown-tier: refused before allocating a worktree"
else bad "planning-unknown-tier: side effect or wrong refusal"; fi

# --- session list -----------------------------------------------------------
new_root
run_launch --agent codex --full-access --tier complex >/dev/null
cat >"$root/.nogging/state/sessions/legacy.json" <<'LEG'
{"name": "legacy", "bead_id": "SPEC-old", "role": "lead", "state": "ended",
 "started_at": "2026-01-01T00:00:00+00:00", "working_dir": "/x",
 "requested_model": "old-model", "model_source": "profile"}
LEG
legacy_before=$(sha256sum <"$root/.nogging/state/sessions/legacy.json")
"$nogg" session list >"$out" 2>&1
grep -E "SPEC-tier .*gpt-6.1-sol effort=low \(launch\) tier=complex" "$out" >/dev/null \
  && ok "list shows tier=complex alongside the model" || bad "list shows tier"
grep -E "^legacy .*old-model +profile" "$out" >/dev/null && ! grep -E "^legacy .*tier=" "$out" >/dev/null \
  && ok "legacy record keeps the prior display" || bad "legacy display"
[[ "$(sha256sum <"$root/.nogging/state/sessions/legacy.json")" == "$legacy_before" ]] \
  && ok "legacy record not rewritten" || bad "legacy record rewritten"

# --- exact resume keeps its recorded selection -----------------------------
new_root
run_launch --full-access --tier standard || bad "resume: first launch"
sid=$(record claude_session_id)
python3 - "$root/.nogging/model-selection.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["agents"]["claude"]["standard"]["model"] = "claude-changed"
json.dump(t, open(sys.argv[1], "w"))
PY
: >"$TMUX_STUB_DIR/calls.log"
run_launch --full-access --tier standard --resume "$sid" && ok "resume: launched" || bad "resume: launch errored"
has "resume: recorded model kept" "--model claude-sonnet-5-5"
lacks "resume: changed table not re-resolved" "claude-changed"
has "resume: exact conversation" "--resume $sid"
has "resume: recorded tier effort forwarded" "--effort high"
! grep -q "NOTE:" "$out" && ok "resume: no pending NOTE" || bad "resume: unexpected NOTE"
KEEP_ROOT=1 launch_refused "resume-other-tier" "pass --tier standard or drop --tier" \
  --full-access --tier complex --resume "$sid" || true
KEEP_ROOT=1 launch_refused "resume-without-recorded-tier" "no session record carries one" \
  --full-access --tier standard --resume 11111111-1111-4111-8111-111111111111 || true

exit "$fail"
