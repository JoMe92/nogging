#!/usr/bin/env bash
# Regression checks for session model selection parsing (TASK-SCM-001).
#
# Covered:
#   - Claude `.json` and Codex `.codex.toml` profiles accept an optional
#     `model`; Codex also accepts a supported `model_reasoning_effort`;
#   - `--model` beats the profile model, which beats the runtime default;
#   - legacy profiles (no model keys) launch exactly as before;
#   - wrong types, empty/flag-like model names, unsupported efforts and a
#     non-Codex `model_reasoning_effort` are refused before tmux or any
#     session record exists;
#   - Pi's existing provider/model selection still reaches the wrapper, and
#     `--model` overrides it.
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

n=0
# launch <expect: ok|refuse> <label> <launch args...>
launch() {
  local expect="$1" label="$2"; shift 2
  n=$((n + 1))
  root="$work/r$n"; make_root "$root"
  export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/t$n"
  mkdir -p "$TMUX_STUB_DIR"
  if [[ -n "${PROFILE_BODY:-}" ]]; then
    printf '%s\n' "$PROFILE_BODY" >"$root/.nogging/launch-profiles/$PROFILE_NAME"
    set -- "$@" --profile "$root/.nogging/launch-profiles/$PROFILE_NAME"
  fi
  if "$nogg" session launch --role lead --bead SPEC-mdl "$@" >"$out" 2>&1; then
    [[ "$expect" == ok ]] && ok "$label: launched" || bad "$label: launch should be refused"
  else
    if [[ "$expect" == refuse ]]; then
      ok "$label: refused"
      grep -qE -- "model|--model" "$out" \
        && ok "$label: refusal names the model setting" || bad "$label: refused for another reason"
      [[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null)" ]] \
        && ok "$label: no session record created" || bad "$label: session state left behind"
      ! grep -qF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null \
        && ok "$label: no tmux session created" || bad "$label: tmux new-session reached"
    else
      bad "$label: launch errored"
    fi
  fi
  unset PROFILE_BODY PROFILE_NAME
}
calls() { cat "$TMUX_STUB_DIR/calls.log" 2>/dev/null; }
has() { calls | grep -qF -- "$2" && ok "$1" || { bad "$1 (missing: $2)"; calls; }; }
lacks() { calls | grep -qF -- "$2" && { bad "$1 (present: $2)"; calls; } || ok "$1"; }

# select_session_model precedence, exercised directly (no session at all).
python3 - "$nogg" <<'PY' && ok "precedence: --model > profile model > runtime-default" || { echo "FAIL - precedence"; fail=1; }
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("nogg", sys.argv[1])
spec = importlib.util.spec_from_loader("nogg", loader)
nogg = importlib.util.module_from_spec(spec); sys.modules["nogg"] = nogg
loader.exec_module(nogg)
sel = nogg.select_session_model
assert sel("cli-m", {"model": "prof-m"}) == ("cli-m", "launch")
assert sel(None, {"model": "prof-m"}) == ("prof-m", "profile")
assert sel(None, {}) == (None, "runtime-default")
assert sel(None, None) == (None, "runtime-default")
for badval in ("", "-x", "a b", "a\nb", 3):
    try:
        sel(badval, None)
    except RuntimeError:
        continue
    raise AssertionError(f"--model {badval!r} accepted")
PY

# --- legacy profiles: behavior unchanged -----------------------------------
launch ok "legacy-claude" --full-access
lacks "legacy-claude: no model flag invented" "--model"
launch ok "legacy-codex" --agent codex --full-access
lacks "legacy-codex: no model flag invented" "--model"
launch ok "legacy-pi" --agent pi
lacks "legacy-pi: no model flag invented" "--model"

# --- valid model keys -------------------------------------------------------
PROFILE_NAME=m.json PROFILE_BODY='{"permissions":{"defaultMode":"default","deny":[]},"model":"claude-opus-5-5"}' \
  launch ok "claude-profile-model"
PROFILE_NAME=m.json PROFILE_BODY='{"permissions":{"defaultMode":"default","deny":[]},"model":"claude-opus-5-5"}' \
  launch ok "claude-profile-model+override" --model claude-sonnet-5-5
codex_ok='sandbox = "workspace-write"
ask_for_approval = "on-request"
network_access = false
model = "gpt-6-sol"
model_reasoning_effort = "high"'
PROFILE_NAME=m.codex.toml PROFILE_BODY="$codex_ok" launch ok "codex-model+effort" --agent codex
for e in none minimal low medium high xhigh max ultra; do
  PROFILE_NAME=m.codex.toml PROFILE_BODY="sandbox = \"read-only\"
ask_for_approval = \"untrusted\"
network_access = false
model_reasoning_effort = \"$e\"" launch ok "codex-effort-$e" --agent codex
done

# --- Pi existing selection still valid, and --model overrides it -----------
PROFILE_NAME=m.pi.toml PROFILE_BODY='provider = "anthropic"
model = "claude-x"' launch ok "pi-profile-model" --agent pi
has "pi-profile-model: provider forwarded" "--provider anthropic"
has "pi-profile-model: profile model forwarded" "--model claude-x"
PROFILE_NAME=m.pi.toml PROFILE_BODY='provider = "anthropic"
model = "claude-x"' launch ok "pi-override" --agent pi --model claude-y
has "pi-override: --model wins over the profile" "--model claude-y"
lacks "pi-override: profile model not forwarded" "claude-x"

# --- refusals before any side effect ---------------------------------------
PROFILE_NAME=m.json PROFILE_BODY='{"permissions":{},"model":7}' launch refuse "claude-model-wrong-type"
PROFILE_NAME=m.json PROFILE_BODY='{"permissions":{},"model":""}' launch refuse "claude-model-empty"
PROFILE_NAME=m.json PROFILE_BODY='{"permissions":{},"model_reasoning_effort":"high"}' launch refuse "claude-effort-codex-only"
codex_base='sandbox = "read-only"
ask_for_approval = "untrusted"
network_access = false'
PROFILE_NAME=m.codex.toml PROFILE_BODY="$codex_base
model_reasoning_effort = \"turbo\"" launch refuse "codex-effort-unsupported" --agent codex
PROFILE_NAME=m.codex.toml PROFILE_BODY="$codex_base
model_reasoning_effort = true" launch refuse "codex-effort-wrong-type" --agent codex
PROFILE_NAME=m.codex.toml PROFILE_BODY="$codex_base
model = true" launch refuse "codex-model-wrong-type" --agent codex
PROFILE_NAME=m.codex.toml PROFILE_BODY="$codex_base
model = \"--dangerously-bypass\"" launch refuse "codex-model-flag-like" --agent codex
PROFILE_NAME=m.pi.toml PROFILE_BODY='model_reasoning_effort = "high"' launch refuse "pi-effort-codex-only" --agent pi
launch refuse "cli-model-empty" --model ""
launch refuse "cli-model-flag-like" --agent codex --model=--yolo
launch refuse "cli-model-whitespace" --agent pi --model "a b"

if [[ $fail -ne 0 ]]; then echo "session model checks failed" >&2; exit 1; fi
echo "all session model checks passed"
