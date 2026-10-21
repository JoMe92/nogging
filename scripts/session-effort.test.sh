#!/usr/bin/env bash
# Regression checks for Claude effort selection and validation (TASK-CRE-001).
#
# Covered:
#   - Claude profiles accept optional `effort` (low, medium, high, xhigh, max);
#   - `session launch --effort <level>` overrides profile effort;
#   - Precedence: --effort > profile effort > runtime default;
#   - Omission preserves runtime default and sets reasoning_effort null;
#   - Invalid inputs (null, wrong type, empty, whitespace, case variants, unsupported)
#     are refused before worktree/settings/record/tmux side effects, even when overridden;
#   - Cross-agent rejections:
#       * --effort refused for Pi and Antigravity (Claude and Codex only),
#         including implicit configured agent selection;
#       * `effort` refused in non-Claude profiles (Codex, Pi, Antigravity);
#       * `model_reasoning_effort` refused in Claude, Pi, and Antigravity profiles;
#   - Codex model_reasoning_effort behavior is preserved for all 8 values;
#   - `--effort` for Codex (TASK-CEF-001): all 8 levels validated and forwarded
#     as `--reasoning-effort`, over `--tier` and the profile, recorded with
#     source `launch`; unsupported levels refuse before side effects;
#   - Effective Claude settings JSON copy strips the `effort` key while leaving
#     the source profile untouched.
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

run_launch() { "$nogg" session launch --role lead --bead SPEC-cre --cwd "$root" "$@" >"$out" 2>&1; }

launch_ok() {
  local label="$1"; shift; new_root
  if [[ -n "${PROFILE_BODY:-}" ]]; then
    printf '%s\n' "$PROFILE_BODY" >"$root/.nogging/launch-profiles/$PROFILE_NAME"
    set -- "$@" --profile "$root/.nogging/launch-profiles/$PROFILE_NAME"
  fi
  if run_launch "$@"; then
    ok "$label: launched"
  else
    bad "$label: launch errored"
  fi
  unset PROFILE_BODY PROFILE_NAME
}

launch_refused() {
  local label="$1" expect="$2"; shift 2
  new_root
  local sessions_before tmux_before
  sessions_before=$(ls -A "$root/.nogging/state/sessions" 2>/dev/null || true)
  tmux_before=$(grep -cF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null || true)
  if [[ -n "${PROFILE_BODY:-}" ]]; then
    printf '%s\n' "$PROFILE_BODY" >"$root/.nogging/launch-profiles/$PROFILE_NAME"
    set -- "$@" --profile "$root/.nogging/launch-profiles/$PROFILE_NAME"
  fi
  if run_launch "$@"; then
    bad "$label: launch should be refused"
    unset PROFILE_BODY PROFILE_NAME
    return
  fi
  grep -qF -- "$expect" "$out" && ok "$label: refused naming '$expect'" || bad "$label: wrong refusal"
  [[ "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null || true)" == "$sessions_before" ]] \
    && ok "$label: no session record or settings file" || bad "$label: session state left behind"
  [[ "$(grep -cF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null || true)" == "$tmux_before" ]] \
    && ok "$label: no tmux session" || bad "$label: tmux new-session reached"
  [[ -z "$(ls "$work" | grep -E -- "-plan-" || true)" ]] || bad "$label: worktree allocated"
  unset PROFILE_BODY PROFILE_NAME
}

# --- Python unit checks: select_session_effort and validate_claude_effort ---
python3 - "$nogg" <<'PY' && ok "precedence: --effort > profile effort > runtime-default" || { echo "FAIL - python unit checks"; fail=1; }
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("nogg", sys.argv[1])
spec = importlib.util.spec_from_loader("nogg", loader)
nogg = importlib.util.module_from_spec(spec); sys.modules["nogg"] = nogg
loader.exec_module(nogg)

sel = nogg.select_session_effort
assert sel("low", {"effort": "high"}, "claude") == ("low", "launch")
assert sel(None, {"effort": "high"}, "claude") == ("high", "profile")
assert sel(None, {}, "claude") == (None, "runtime-default")
assert sel(None, None, "claude") == (None, "runtime-default")

# Non-claude agent ignores profile effort in select_session_effort
assert sel(None, {"effort": "high"}, "codex") == (None, "runtime-default")

# All five valid levels
for lvl in ("low", "medium", "high", "xhigh", "max"):
    assert sel(lvl, {}, "claude") == (lvl, "launch")
    assert sel(None, {"effort": lvl}, "claude") == (lvl, "profile")

# Invalid inputs raise
for bad in ("", "auto", "ultra", "none", "minimal", "HIGH", "low ", 1, True, None):
    if bad is not None:
        try:
            sel(bad, {}, "claude")
            raise AssertionError(f"--effort {bad!r} should have raised")
        except RuntimeError:
            pass

val = nogg.validate_claude_effort
for bad in ("", "auto", "ultra", "none", "minimal", "HIGH", "low ", 1, True, None, [], {}):
    try:
        val(bad, "test")
        raise AssertionError(f"validate_claude_effort({bad!r}) should have raised")
    except RuntimeError:
        pass
PY

session_rec() {
  local f
  f=$(find "$root/.nogging/state/sessions" -maxdepth 1 -name "*.json" ! -name "*.settings.json" | head -n1)
  cat "$f"
}

# --- Claude profile effort: all 5 levels accepted ---
for lvl in low medium high xhigh max; do
  PROFILE_NAME=e-$lvl.json PROFILE_BODY="{\"permissions\":{\"defaultMode\":\"default\",\"deny\":[]},\"effort\":\"$lvl\"}" \
    launch_ok "claude-profile-effort-$lvl"
  rec=$(session_rec)
  python3 -c "import json, sys; r = json.loads(sys.argv[1]); assert r['reasoning_effort'] == '$lvl', r" "$rec" \
    && ok "claude-profile-effort-$lvl: record has reasoning_effort $lvl" \
    || { bad "claude-profile-effort-$lvl: wrong reasoning_effort in record"; }
done

# --- Claude CLI --effort: all 5 levels accepted and override profile ---
for lvl in low medium high xhigh max; do
  PROFILE_NAME=p-high.json PROFILE_BODY='{"permissions":{"defaultMode":"default","deny":[]},"effort":"high"}' \
    launch_ok "claude-cli-effort-$lvl" --effort "$lvl"
  rec=$(session_rec)
  python3 -c "import json, sys; r = json.loads(sys.argv[1]); assert r['reasoning_effort'] == '$lvl', r" "$rec" \
    && ok "claude-cli-effort-$lvl: record has override reasoning_effort $lvl" \
    || { bad "claude-cli-effort-$lvl: wrong reasoning_effort in record"; }
done

# --- Source profile byte preservation and settings stripping ---
PROFILE_NAME=p-source.json PROFILE_BODY='{"permissions":{"defaultMode":"default","deny":[]},"effort":"high"}' \
  launch_ok "claude-settings-strip"
orig_content='{"permissions":{"defaultMode":"default","deny":[]},"effort":"high"}'
source_content=$(cat "$root/.nogging/launch-profiles/p-source.json")
[[ "$orig_content" == "$source_content" ]] \
  && ok "claude-settings-strip: source profile untouched byte-for-byte" \
  || bad "claude-settings-strip: source profile changed"
settings_file=$(ls "$root/.nogging/state/sessions/"*.settings.json)
python3 -c "import json, sys; s = json.load(open(sys.argv[1])); assert 'effort' not in s, s" "$settings_file" \
  && ok "claude-settings-strip: generated settings file omits effort key" \
  || bad "claude-settings-strip: generated settings leaked effort key"

# --- Omission preserves native default ---
launch_ok "claude-omission" --full-access
rec=$(session_rec)
python3 -c "import json, sys; r = json.loads(sys.argv[1]); assert r['reasoning_effort'] is None, r" "$rec" \
  && ok "claude-omission: reasoning_effort is null" \
  || bad "claude-omission: reasoning_effort is not null"

# --- Invalid profile effort refuses even when overridden by valid CLI --effort ---
PROFILE_NAME=bad-prof.json PROFILE_BODY='{"permissions":{},"effort":"ultra"}' \
  launch_refused "invalid-profile-overridden" "must be one of low, medium, high, xhigh, max" --effort low

# --- Invalid profile effort variants refuse before side effects ---
for badval in 'null' 'true' '42' '""' '"   "' '"HIGH"' '"Low"' '"auto"' '"ultra"' '"none"' '"minimal"'; do
  label="prof-bad-$(echo "$badval" | tr -d ' "')"
  PROFILE_NAME=bad.json PROFILE_BODY="{\"permissions\":{},\"effort\":$badval}" \
    launch_refused "claude-$label" "must be one of low, medium, high, xhigh, max"
done

# --- Invalid CLI --effort variants refuse before side effects ---
launch_refused "cli-effort-empty" "must be one of low, medium, high, xhigh, max" --effort ""
launch_refused "cli-effort-whitespace" "must be one of low, medium, high, xhigh, max" --effort " high "
launch_refused "cli-effort-case" "must be one of low, medium, high, xhigh, max" --effort "HIGH"
launch_refused "cli-effort-auto" "must be one of low, medium, high, xhigh, max" --effort "auto"
launch_refused "cli-effort-ultra" "must be one of low, medium, high, xhigh, max" --effort "ultra"
launch_refused "cli-effort-none" "must be one of low, medium, high, xhigh, max" --effort "none"
launch_refused "cli-effort-minimal" "must be one of low, medium, high, xhigh, max" --effort "minimal"
launch_refused "cli-effort-flag" "must be one of low, medium, high, xhigh, max" --effort=--low

# --- Cross-agent refusal: --effort for non-Claude agents ---
launch_refused "pi-cli-effort" "--effort is Claude- and Codex-only" --agent pi --effort low
launch_refused "antigravity-cli-effort" "--effort is Claude- and Codex-only" --agent antigravity --effort low
launch_refused "agy-alias-cli-effort" "--effort is Claude- and Codex-only" --agent agy --effort low

# --- Cross-agent refusal: configured agent resolution in config.json ---
new_root
python3 - "$root/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["session_agent"] = "codex"
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
run_launch --effort low >"$out" 2>&1 && ok "config-agent-codex: configured Codex accepts --effort" \
  || bad "config-agent-codex: launch errored"

new_root
python3 - "$root/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["session_agent"] = "pi"
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
run_launch --effort low >"$out" 2>&1 && bad "config-agent-pi: launch should refuse" || {
  grep -qF -- "--effort is Claude- and Codex-only" "$out" && ok "config-agent-pi: refused naming Claude and Codex" \
    || bad "config-agent-pi: wrong refusal text"
}

new_root
python3 - "$root/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["session_agent"] = "antigravity"
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
run_launch --effort low >"$out" 2>&1 && bad "config-agent-agy: launch should refuse" || {
  grep -qF -- "--effort is Claude- and Codex-only" "$out" && ok "config-agent-agy: refused naming Claude and Codex" \
    || bad "config-agent-agy: wrong refusal text"
}

# --- Cross-agent refusal: profiles with wrong effort keys ---
codex_effort_bad='sandbox = "read-only"
ask_for_approval = "on-request"
network_access = false
effort = "high"'
PROFILE_NAME=bad.codex.toml PROFILE_BODY="$codex_effort_bad" \
  launch_refused "codex-profile-effort-refused" "effort is Claude-only" --agent codex

pi_effort_bad='effort = "high"'
PROFILE_NAME=bad.pi.toml PROFILE_BODY="$pi_effort_bad" \
  launch_refused "pi-profile-effort-refused" "effort is Claude-only" --agent pi

agy_effort_bad='mode = "accept-edits"
approval = "ask"
sandbox = "false"
effort = "high"'
PROFILE_NAME=bad.agy.toml PROFILE_BODY="$agy_effort_bad" \
  launch_refused "antigravity-profile-effort-refused" "effort is Claude-only" --agent antigravity

PROFILE_NAME=bad-claude-mre.json PROFILE_BODY='{"permissions":{},"model_reasoning_effort":"high"}' \
  launch_refused "claude-profile-mre-refused" "model_reasoning_effort is Codex-only"

pi_mre_bad='model_reasoning_effort = "high"'
PROFILE_NAME=bad-mre.pi.toml PROFILE_BODY="$pi_mre_bad" \
  launch_refused "pi-profile-mre-refused" "model_reasoning_effort is Codex-only" --agent pi

agy_mre_bad='mode = "accept-edits"
approval = "ask"
sandbox = "false"
model_reasoning_effort = "high"'
PROFILE_NAME=bad-mre.agy.toml PROFILE_BODY="$agy_mre_bad" \
  launch_refused "antigravity-profile-mre-refused" "model_reasoning_effort is Codex-only" --agent antigravity

# --- Preserve Codex: all 8 model_reasoning_effort levels still launch ok ---
for e in none minimal low medium high xhigh max ultra; do
  codex_body="sandbox = \"read-only\"
ask_for_approval = \"on-request\"
network_access = false
model_reasoning_effort = \"$e\""
  PROFILE_NAME="codex-$e.codex.toml" PROFILE_BODY="$codex_body" \
    launch_ok "codex-preserved-$e" --agent codex
  rec=$(cat "$root/.nogging/state/sessions/"*.json)
  python3 -c "import json, sys; r = json.loads(sys.argv[1]); assert r['reasoning_effort'] == '$e', r" "$rec" \
    && ok "codex-preserved-$e: record has reasoning_effort $e" \
    || { bad "codex-preserved-$e: wrong reasoning_effort in record"; }
done

src_check() { # label expr (python over record r)
  python3 -c "import json, sys; r = json.loads(sys.argv[1]); assert $2, r" "$(session_rec)" \
    && ok "$1" || bad "$1"
}
list_has() { "$nogg" session list >"$out" 2>&1; grep -qE -- "$2" "$out" && ok "$1" || bad "$1: missing /$2/"; }

# --- Codex --effort (TASK-CEF-001): validated, forwarded, over tier and profile ---
codex_argv() { grep -F "new-session" "$TMUX_STUB_DIR/calls.log" | tail -1; }
codex_has() { codex_argv | grep -qF -- "$2" && ok "$1" || { bad "$1 (missing: $2)"; codex_argv; }; }
codex_lacks() { codex_argv | grep -qF -- "$2" && { bad "$1 (present: $2)"; codex_argv; } || ok "$1"; }
codex_xhigh='sandbox = "read-only"
ask_for_approval = "on-request"
network_access = false
model_reasoning_effort = "xhigh"'

for e in none minimal low medium high xhigh max ultra; do
  launch_ok "codex-cli-effort-$e" --agent codex --full-access --effort "$e"
  codex_has "codex-cli-effort-$e: forwarded as --reasoning-effort" "--reasoning-effort $e"
  src_check "codex-cli-effort-$e: record effort with source launch" \
    "r['reasoning_effort']=='$e' and r['reasoning_effort_source']=='launch' and r['selection_tier'] is None"
done
list_has "codex-cli-effort: list shows effort=ultra (launch)" "effort=ultra \(launch\)"

PROFILE_NAME=cli-over-profile.codex.toml PROFILE_BODY="$codex_xhigh" \
  launch_ok "codex-effort-over-profile" --agent codex --effort low
codex_has "codex-effort-over-profile: launch effort forwarded" "--reasoning-effort low"
codex_lacks "codex-effort-over-profile: profile effort not forwarded" "xhigh"
src_check "codex-effort-over-profile: source launch" "r['reasoning_effort']=='low' and r['reasoning_effort_source']=='launch'"
[[ "$(cat "$root/.nogging/launch-profiles/cli-over-profile.codex.toml")" == "$codex_xhigh" ]] \
  && ok "codex-effort-over-profile: source profile unchanged" || bad "codex-effort-over-profile: profile changed"

launch_ok "codex-effort-over-tier" --agent codex --full-access --tier complex --effort low
codex_has "codex-effort-over-tier: tier model kept" "--model gpt-6.1-sol"
codex_has "codex-effort-over-tier: launch effort wins" "--reasoning-effort low"
codex_lacks "codex-effort-over-tier: tier effort not forwarded" "--reasoning-effort high"
src_check "codex-effort-over-tier: tier attribution kept" \
  "r['selection_tier']=='complex' and r['selection_tier_effort']=='low' and r['reasoning_effort']=='low' and r['reasoning_effort_source']=='launch'"

launch_ok "codex-tier-model-effort" --agent codex --full-access --tier complex --model gpt-6-luna --effort medium
codex_has "codex-tier-model-effort: model forwarded" "--model gpt-6-luna"
codex_has "codex-tier-model-effort: effort forwarded" "--reasoning-effort medium"
src_check "codex-tier-model-effort: record keeps tier with launch model and effort" \
  "r['selection_tier']=='complex' and r['requested_model']=='gpt-6-luna' and r['model_source']=='launch' and r['reasoning_effort']=='medium' and r['reasoning_effort_source']=='launch'"
list_has "codex-tier-model-effort: list shows tier alongside" "gpt-6-luna effort=medium \(launch\) tier=complex"

# Unsupported levels refuse before side effects, even when a tier or profile
# would supply a valid effort.
allowed="none, minimal, low, medium, high, xhigh, max, ultra"
launch_refused "codex-effort-turbo" "$allowed" --agent codex --full-access --effort turbo
launch_refused "codex-effort-upper" "$allowed" --agent codex --full-access --effort LOW
launch_refused "codex-effort-empty" "$allowed" --agent codex --full-access --effort ""
launch_refused "codex-effort-over-valid-tier" "$allowed" --agent codex --full-access --tier complex --effort turbo
PROFILE_NAME=bad-over-profile.codex.toml PROFILE_BODY="$codex_xhigh" \
  launch_refused "codex-effort-over-valid-profile" "$allowed" --agent codex --effort turbo

# Exact resume: effort travels like --model (a `-c` override the resume path
# already requires), so a resume carries it.
# The resume path inspects `codex resume --help`; answer it from the shared
# fixture (no real Codex), then restore the inert stub.
cat >"$work/bin/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == resume && "${2:-}" == --help ]]; then cat "$RESUME_HELP"; exit 0; fi
if [[ "${1:-}" == --help ]]; then
  printf 'Usage: codex [OPTIONS]\n  --cd <DIR>\n  --sandbox <MODE>\n  --ask-for-approval <POLICY>\n  --add-dir <DIR>\n  --model <MODEL>\n  -c, --config <key=value>\n'
  exit 0
fi
exit 0
STUB
chmod +x "$work/bin/codex"
export RESUME_HELP="$here/fixtures/codex/codex-resume-help.txt"
launch_ok "codex-resume-effort" --agent codex --full-access --effort low \
  --resume 019f0000-0000-7000-8000-000000000001
codex_has "codex-resume-effort: resumes the exact thread" "--resume 019f0000-0000-7000-8000-000000000001"
codex_has "codex-resume-effort: effort forwarded" "--reasoning-effort low"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/codex"

# --- Provenance (TASK-CRE-003): reasoning_effort_source record + list rendering ---
PROFILE_NAME=pv.json PROFILE_BODY='{"permissions":{"defaultMode":"default","deny":[]},"effort":"high"}' \
  launch_ok "prov-claude-profile"
src_check "prov-claude-profile: source profile" "r['reasoning_effort']=='high' and r['reasoning_effort_source']=='profile'"
list_has "prov-claude-profile: list shows effort=high (profile)" "effort=high \(profile\)"

PROFILE_NAME=pv.json PROFILE_BODY='{"permissions":{"defaultMode":"default","deny":[]},"effort":"high"}' \
  launch_ok "prov-claude-launch" --effort low
src_check "prov-claude-launch: source launch" "r['reasoning_effort']=='low' and r['reasoning_effort_source']=='launch'"
list_has "prov-claude-launch: list shows effort=low (launch)" "effort=low \(launch\)"

launch_ok "prov-claude-default" --full-access
src_check "prov-claude-default: null effort, runtime-default" "r['reasoning_effort'] is None and r['reasoning_effort_source']=='runtime-default'"
list_has "prov-claude-default: list shows effort=runtime-default" "effort=runtime-default"

PROFILE_NAME=pv.codex.toml PROFILE_BODY='sandbox = "read-only"
ask_for_approval = "on-request"
network_access = false
model_reasoning_effort = "high"' launch_ok "prov-codex-profile" --agent codex
src_check "prov-codex-profile: source profile" "r['reasoning_effort']=='high' and r['reasoning_effort_source']=='profile'"
list_has "prov-codex-profile: list shows effort=high (profile)" "effort=high \(profile\)"

launch_ok "prov-codex-default" --agent codex --full-access
src_check "prov-codex-default: runtime-default" "r['reasoning_effort'] is None and r['reasoning_effort_source']=='runtime-default'"

launch_ok "prov-pi" --agent pi
list_has "prov-pi: other agents show no effort" "SPEC-cre .*pi "
! grep -q "effort=" "$out" && ok "prov-pi: no effort text for pi" || bad "prov-pi: pi row shows effort"

# Legacy records: effort present shows (unknown); absent keeps prior display; not rewritten.
new_root
mkdir -p "$root/.nogging/state/sessions"
cat >"$root/.nogging/state/sessions/legacy-e.json" <<'LEG'
{"name": "legacy-e", "bead_id": "SPEC-old", "role": "lead", "state": "ended", "agent": "codex",
 "started_at": "2026-01-01T00:00:00+00:00", "working_dir": "/x",
 "requested_model": "old-model", "model_source": "profile", "reasoning_effort": "high"}
LEG
cat >"$root/.nogging/state/sessions/legacy-n.json" <<'LEG'
{"name": "legacy-n", "bead_id": "SPEC-old2", "role": "lead", "state": "ended",
 "started_at": "2026-01-01T00:00:00+00:00", "working_dir": "/x",
 "requested_model": "old-model", "model_source": "profile", "reasoning_effort": null}
LEG
before=$(sha256sum "$root/.nogging/state/sessions/"legacy-*.json)
"$nogg" session list >"$out" 2>&1 || bad "legacy list failed"
grep -E "^legacy-e .*old-model effort=high \(unknown\)" "$out" >/dev/null \
  && ok "legacy-effort: shows (unknown) provenance" || bad "legacy-effort display"
grep -E "^legacy-n .*old-model +profile" "$out" >/dev/null && ! grep -E "^legacy-n .*effort=" "$out" >/dev/null \
  && ok "legacy-no-effort: prior display preserved" || bad "legacy-no-effort display"
[[ "$before" == "$(sha256sum "$root/.nogging/state/sessions/"legacy-*.json)" ]] \
  && ok "legacy records not rewritten" || bad "legacy records rewritten"

if [[ $fail -ne 0 ]]; then echo "session effort checks failed" >&2; exit 1; fi
echo "all session effort checks passed"
