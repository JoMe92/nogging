#!/usr/bin/env bash
# Regression checks for session model forwarding (TASK-SCM-002).
#
# Covered:
#   - the wrapper contract advertises `model-forwarding` and
#     `--reasoning-effort`, and the launcher refuses a wrapper that predates it
#     instead of silently dropping the model;
#   - `nogg session launch` hands the selected model (and Codex reasoning
#     effort) to the wrapper as separate argv elements, and the wrapper hands
#     them on to stub Claude / Codex / Pi binaries as exact flags;
#   - a model value carrying shell metacharacters reaches the runtime
#     verbatim as ONE argv element and is never interpolated;
#   - adding a model or effort changes nothing else in the runtime argv (no
#     authority change), and a legacy launch emits no model flag;
#   - direct wrapper calls fail closed on a flag-like model, an unsupported
#     effort, or an effort for a non-Codex agent.
#
# tmux, bd, claude, codex and pi are PATH-injected stubs; no real session or
# runtime is ever started.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then printf '[{"id":"%s","title":"stub"}]\n' "${2:-}"; exit 0; fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
echo "stub bd: refusing $*" >&2; exit 1
STUB
# tmux records the exact argv of `new-session` (the wrapper call follows `--`).
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:1] == ["-L"]: args = args[2:]
if args[:1] == ["has-session"]: sys.exit(1)
if args[:1] == ["new-session"]:
    with open(os.environ["TMUX_ARGV"], "w") as f:
        json.dump(args[args.index("--") + 1:], f)
STUB
# Each runtime stub records its exact argv and touches nothing else.
for rt in claude codex pi; do
  cat >"$work/bin/$rt" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
with open(os.environ["RUNTIME_ARGV"], "w") as f:
    json.dump({"bin": os.path.basename(sys.argv[0]), "argv": sys.argv[1:]}, f)
STUB
done
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" RUNTIME_ARGV="$work/runtime.json" TMUX_ARGV="$work/tmux.json"
unset NOGG_OPENSPEC_FENCE NOGG_STARTUP_LOG

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/scripts" "$r/openspec" "$r/.pi/extensions" "$r/.codex/rules"
  cp "$repo_root/scripts/nogg" "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$r/scripts/"
  cp "$repo_root/.pi/extensions/nogging-guard.ts" "$r/.pi/extensions/"
  : >"$r/.codex/rules/nogging.rules"
  git init -q "$r"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$r/.nogging/"
  python3 - "$repo_root/.nogging/config.json" "$r/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None)
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
}

# --- the wrapper contract ---------------------------------------------------
python3 - "$here/session-launch" <<'PY' && ok "contract advertises model-forwarding and --reasoning-effort" || bad "contract"
import json, subprocess, sys
c = json.loads(subprocess.check_output([sys.argv[1], "--contract"]))
assert "model-forwarding" in c["features"], c
assert c["options"]["--model"] == 1 and c["options"]["--reasoning-effort"] == 1, c
PY
python3 - "$nogg" <<'PY' && ok "a wrapper without model-forwarding is refused when a model is requested" || bad "stale wrapper accepted"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("nogg", sys.argv[1])
spec = importlib.util.spec_from_loader("nogg", loader)
nogg = importlib.util.module_from_spec(spec); sys.modules["nogg"] = nogg
loader.exec_module(nogg)
stale = {"features": ["startup-stderr"], "agents": ["claude", "codex"],
         "options": {"--model": 1, "--reasoning-effort": 1, "--cwd": 1}}
nogg.validate_launch_contract(stale, ["w", "--cwd", "x"], "claude")  # legacy launch still fine
for argv in (["w", "--model", "m"], ["w", "--reasoning-effort", "high"]):
    try:
        nogg.validate_launch_contract(stale, argv, "codex")
    except RuntimeError as exc:
        assert "model forwarding" in str(exc)
        continue
    raise AssertionError(f"stale wrapper accepted {argv}")
PY

# --- end to end: launch -> wrapper argv -> runtime argv ---------------------
# A model value full of shell metacharacters but no whitespace: if anything
# along the way interpolated it, the runtime would not see it verbatim (and
# $work/pwned would appear).
evil='m;$(touch${IFS}'"$work"'/pwned)`id`|&>x"'"'"
n=0
# e2e <agent> <expected runtime binary> <launch args...>: runs the wrapper argv
# tmux was given, with the runtime stubbed, leaving $RUNTIME_ARGV behind.
e2e() {
  local agent="$1"; shift
  n=$((n + 1)); root="$work/r$n"; make_root "$root"
  rm -f "$TMUX_ARGV" "$RUNTIME_ARGV"
  NOGGING_ROOT="$root" "$root/scripts/nogg" session launch --role lead --bead SPEC-mdl \
    --cwd "$root" --agent "$agent" "$@" >"$work/out" 2>&1 \
    || { bad "$agent launch $*"; cat "$work/out"; return 1; }
  python3 - "$TMUX_ARGV" >"$work/inner" <<'PY'
import json, sys
print("\0".join(json.load(open(sys.argv[1]))), end="")
PY
  local -a inner=()
  mapfile -d '' inner <"$work/inner"
  "${inner[@]}" >/dev/null 2>"$work/err" || { bad "$agent wrapper run"; cat "$work/err"; return 1; }
}
# expect_pair <label> <flag> <value>: the runtime argv holds <flag> immediately
# followed by exactly <value> as its own element, exactly once (and, for
# --model, no second --model anywhere).
expect_pair() {
  python3 - "$RUNTIME_ARGV" "$2" "$3" <<'PY' && ok "$1" || { bad "$1"; cat "$RUNTIME_ARGV"; echo; }
import json, sys
argv = json.load(open(sys.argv[1]))["argv"]
flag, value = sys.argv[2], sys.argv[3]
assert sum(1 for i, a in enumerate(argv) if a == flag and argv[i + 1:i + 2] == [value]) == 1, argv
if flag == "--model":
    assert argv.count(flag) == 1, argv
PY
}
expect_absent() {
  python3 - "$RUNTIME_ARGV" "$2" <<'PY' && ok "$1" || { bad "$1"; cat "$RUNTIME_ARGV"; echo; }
import json, sys
argv = json.load(open(sys.argv[1]))["argv"]
assert not any(a == sys.argv[2] or a.startswith(sys.argv[2] + "=") for a in argv), argv
PY
}

e2e claude --full-access --model "$evil" && expect_pair "claude: --model reaches the runtime verbatim" --model "$evil"
e2e claude --full-access && expect_absent "claude legacy: no --model invented" --model

PROFILE="$work/m.codex.toml"
printf '%s\n' 'sandbox = "workspace-write"' 'ask_for_approval = "on-request"' 'network_access = false' \
  'model = "gpt-6-sol"' 'model_reasoning_effort = "xhigh"' >"$PROFILE"
if e2e codex --profile "$PROFILE"; then
  expect_pair "codex: profile model reaches the runtime" --model gpt-6-sol
  expect_pair "codex: reasoning effort is one -c element" -c 'model_reasoning_effort="xhigh"'
fi
e2e codex --profile "$PROFILE" --model "$evil" && expect_pair "codex: --model override reaches the runtime verbatim" --model "$evil"
e2e codex --full-access && { expect_absent "codex legacy: no --model invented" --model
  python3 - "$RUNTIME_ARGV" <<'PY' && ok "codex legacy: no reasoning effort invented" || bad "codex legacy effort"
import json, sys
assert not any("model_reasoning_effort" in a for a in json.load(open(sys.argv[1]))["argv"])
PY
}
e2e pi --model "$evil" && expect_pair "pi: --model reaches the runtime verbatim" --model "$evil"
[[ ! -e "$work/pwned" ]] && ok "no model value was ever shell-interpolated" || bad "model value was interpolated"

# --- no authority change: only the model elements differ --------------------
# Direct wrapper calls with fixed arguments, with and without the model.
wroot="$work/w"; make_root "$wroot"
prompt="$wroot/.nogging/launch-prompts/autonomous.md"
[[ -f "$prompt" ]] || prompt="$(ls "$wroot"/.nogging/launch-prompts/*.md | head -1)"
runtime_argv() { "$wroot/scripts/session-launch" "$@" >/dev/null 2>&1 && cat "$RUNTIME_ARGV"; }
same_but() {  # same_but <label> <removed [flag,value] pairs JSON> <base args> -- <extra args>
  local label="$1" removed="$2"; shift 2
  local -a base=() extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do base+=("$1"); shift; done; shift
  extra=("$@")
  local a b
  a=$(runtime_argv "${base[@]}") || { bad "$label: base run"; return; }
  b=$(runtime_argv "${base[@]}" "${extra[@]}") || { bad "$label: model run"; return; }
  python3 - "$a" "$b" "$removed" <<'PY' && ok "$label" || bad "$label"
import json, sys
a, b = json.loads(sys.argv[1])["argv"], json.loads(sys.argv[2])["argv"]
for flag, value in json.loads(sys.argv[3]):  # remove each adjacent pair
    i = next(i for i in range(len(b) - 1) if b[i] == flag and b[i + 1] == value)
    del b[i:i + 2]
assert a == b, (a, b)
PY
}
common=(--cwd "$wroot" --prompt "$prompt" --bead SPEC-mdl)
same_but "claude: model adds only --model <name>" '[["--model","claude-x"]]' \
  "${common[@]}" --settings "$wroot/s.json" --session-id 00000000-0000-4000-8000-000000000000 -- --model claude-x
same_but "claude read-only: plan mode kept with a model" '[["--model","claude-x"]]' \
  "${common[@]}" --settings "$wroot/s.json" --read-only -- --model claude-x
same_but "codex: model+effort add only their own elements" '[["--model","gpt-x"],["-c","model_reasoning_effort=\"low\""]]' \
  --agent codex --sandbox read-only --approval untrusted --network off "${common[@]}" -- \
  --model gpt-x --reasoning-effort low
same_but "pi: model adds only --model <name>" '[["--model","pi-x"]]' \
  --agent pi --provider anthropic "${common[@]}" -- --model pi-x

# --- direct wrapper calls fail closed ---------------------------------------
refuse() {
  local label="$1"; shift; rm -f "$RUNTIME_ARGV"
  if "$wroot/scripts/session-launch" --cwd "$wroot" "$@" >/dev/null 2>&1 || [[ -e "$RUNTIME_ARGV" ]]; then
    bad "wrapper accepted: $label"
  else
    ok "wrapper refuses $label"
  fi
}
refuse "a flag-like model" --model --dangerously-skip-permissions
refuse "a model with whitespace" --agent codex --model "a b"
refuse "an unsupported reasoning effort" --agent codex --reasoning-effort turbo
refuse "an injected reasoning effort" --agent codex --reasoning-effort 'high" -c x="y'
refuse "reasoning effort for Claude" --reasoning-effort high
refuse "reasoning effort for Pi" --agent pi --reasoning-effort high

if [[ $fail -ne 0 ]]; then echo "session model forwarding checks failed" >&2; exit 1; fi
echo "all session model forwarding checks passed"
