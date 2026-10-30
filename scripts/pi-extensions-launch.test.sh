#!/usr/bin/env bash
# Regression checks for the `pi_extensions` config key (TASK-PXG-004).
#
# Covered:
#   - the wrapper contract advertises `pi-extensions` and `--pi-extension`, and
#     the launcher refuses a wrapper that predates it;
#   - `session launch --agent pi` with `["glm-usage"]` hands `pi` one
#     `--extension <workdir>/.pi/nogging/extensions/glm-usage/index.ts` after
#     the guard, stores the names in the record and prints `pi-extensions=`;
#   - an unknown, duplicate, non-kebab-case or non-array value refuses the launch,
#     names the key and the value, and leaves no record, tmux session or runtime
#     call behind;
#   - an absent or empty list leaves the runtime argv, the record and the output
#     byte-identical to a launch without the key;
#   - another agent ignores the key;
#   - `validate` and `doctor` report the same defects as FAIL.
#
# tmux, bd and pi are PATH-injected stubs; no real session or runtime starts.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:1] == ["-L"]: args = args[2:]
if args[:1] == ["-N"]: args = args[1:]
def live_file(): return os.environ["TMUX_ARGV"] + ".live-" + args[args.index("-t" if args[0] == "has-session" else "-s") + 1]
if args[:1] == ["has-session"]: sys.exit(0 if os.path.exists(live_file()) else 1)
if args[:1] == ["new-session"]:
    open(live_file(), "w").close()
    with open(os.environ["TMUX_ARGV"], "w") as f:
        json.dump(args[args.index("--") + 1:], f)
STUB
for rt in claude pi; do
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

# make_root <dir> <pi_extensions JSON | ABSENT> [extra extension names to create]
make_root() {
  local r="$1" value="$2"; shift 2
  mkdir -p "$r/.nogging/state" "$r/scripts" "$r/openspec" "$r/.pi/extensions" "$r/.codex/rules"
  cp "$repo_root/scripts/nogg" "$repo_root/scripts/nogg_usage.py" "$repo_root/scripts/nogg_usage_zai.py" "$repo_root/scripts/session-launch" \
     "$repo_root/scripts/session-log-writer" "$repo_root/scripts/openspec-sandbox" "$r/scripts/"
  cp -r "$repo_root/scripts/lib" "$r/scripts/lib"
  cp "$repo_root/.pi/extensions/nogging-guard.ts" "$r/.pi/extensions/"
  local name
  for name in glm-usage "$@"; do
    mkdir -p "$r/.pi/nogging/extensions/$name"
    : >"$r/.pi/nogging/extensions/$name/index.ts"
  done
  : >"$r/.codex/rules/nogging.rules"
  git init -q "$r"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$r/.nogging/"
  copy_host_config "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  python3 - "$r/.nogging/config.json" "$value" <<'PY'
import json, sys
path, value = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None)
cfg.pop("pi_extensions", None)
if value != "ABSENT":
    cfg["pi_extensions"] = json.loads(value)
json.dump(cfg, open(path, "w"), indent=2)
PY
}

n=0; absent=""; empty=""
# launch <agent> <pi_extensions JSON | ABSENT>: leaves $root, $work/out, and on
# success the runtime argv in $RUNTIME_ARGV; returns the launch's exit status.
launch() {
  local agent="$1" value="$2" status=0
  n=$((n + 1)); root="$work/r$n"; make_root "$root" "$value"
  rm -f "$TMUX_ARGV" "$RUNTIME_ARGV"
  NOGGING_ROOT="$root" "$root/scripts/nogg" session launch --role lead --bead SPEC-pxg \
    --cwd "$root" --agent "$agent" --full-access >"$work/out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || return "$status"
  python3 - "$TMUX_ARGV" >"$work/inner" <<'PY'
import json, sys
print("\0".join(json.load(open(sys.argv[1]))), end="")
PY
  local -a inner=()
  mapfile -d '' inner <"$work/inner"
  "${inner[@]}" >/dev/null 2>"$work/err" || { bad "$agent wrapper run"; cat "$work/err"; return 1; }
}

records() { find "$1/.nogging/state/sessions" -name '*.json' 2>/dev/null | sort; }

# --- the wrapper contract ---------------------------------------------------
python3 - "$here/session-launch" <<'PY' && ok "contract advertises pi-extensions and --pi-extension" || bad "contract"
import json, subprocess, sys
c = json.loads(subprocess.check_output([sys.argv[1], "--contract"]))
assert "pi-extensions" in c["features"], c
assert c["options"]["--pi-extension"] == 1, c
PY
python3 - "$here/nogg" <<'PY' && ok "a wrapper without pi-extensions is refused when one is requested" || bad "stale wrapper accepted"
import runpy, sys
m = runpy.run_path(sys.argv[1])
stale = {"features": ["startup-stderr"], "agents": ["pi"], "options": {"--cwd": 1, "--pi-extension": 1}}
m["validate_launch_contract"](stale, ["w", "--cwd", "x"], "pi")
try:
    m["validate_launch_contract"](stale, ["w", "--pi-extension", "glm-usage"], "pi")
except RuntimeError as exc:
    assert "pi-extensions" in str(exc) and "update" in str(exc), exc
else:
    raise AssertionError("stale wrapper accepted --pi-extension")
assert all(success for _, success in m["session_helper_diagnostics"]())
PY

# --- an enabled extension loads ---------------------------------------------
if launch pi '["glm-usage"]'; then
  python3 - "$RUNTIME_ARGV" "$root" <<'PY' && ok "pi receives --extension for glm-usage after the guard" || bad "enabled argv"
import json, os, sys
argv = [a for a in json.load(open(sys.argv[1]))["argv"] if len(a) < 400]
root = os.path.realpath(sys.argv[2])
guard = f"{root}/.pi/extensions/nogging-guard.ts"
ext = f"{root}/.pi/nogging/extensions/glm-usage/index.ts"
pairs = [(argv[i], argv[i + 1]) for i in range(len(argv) - 1) if argv[i] == "--extension"]
assert pairs[0] == ("--extension", guard), argv
assert ("--extension", ext) in pairs and pairs.index(("--extension", ext)) > 0, argv
assert argv.count(ext) == 1, argv
PY
  python3 - "$(records "$root" | head -1)" <<'PY' && ok "the record lists glm-usage" || bad "record pi_extensions"
import json, sys
assert json.load(open(sys.argv[1]))["pi_extensions"] == ["glm-usage"]
PY
  grep -q '^  pi-extensions=glm-usage$' "$work/out" && ok "launch output prints pi-extensions=glm-usage" \
    || { bad "launch output line"; cat "$work/out"; }
else
  bad "enabled launch"; cat "$work/out"
fi

# --- a bad value refuses before any side effect ------------------------------
refuse() {
  local label="$1" value="$2" want_value="$3" status=0
  launch pi "$value" || status=$?
  if [ "$status" -ne 0 ] \
     && grep -q 'pi_extensions' "$work/out" && grep -qF -- "$want_value" "$work/out" \
     && grep -qE 'nogg update|remove|array|kebab|duplicate' "$work/out" \
     && [ -z "$(records "$root")" ] && [ ! -e "$TMUX_ARGV" ] && [ ! -e "$RUNTIME_ARGV" ] \
     && [ "$(git -C "$root" worktree list --porcelain | grep -c '^worktree')" -le 1 ]; then
    ok "$label refuses before any side effect"
  else
    bad "$label refuses before any side effect (status $status)"; cat "$work/out"
  fi
}
refuse "unknown name" '["no-such-ext"]' 'no-such-ext'
refuse "duplicate name" '["glm-usage","glm-usage"]' 'glm-usage'
refuse "non-kebab-case name" '["Glm_Usage"]' 'Glm_Usage'
refuse "non-array value" '"glm-usage"' 'glm-usage'
refuse "non-string entry" '[7]' '7'

# --- nothing enabled is unchanged -------------------------------------------
shape() {
  python3 - "$RUNTIME_ARGV" "$root" "$(records "$root" | head -1)" "$work/out" <<'PY'
import json, os, re, sys
argv = [a for a in json.load(open(sys.argv[1]))["argv"] if len(a) < 400]
root = os.path.realpath(sys.argv[2])
rec = json.load(open(sys.argv[3]))
out = open(sys.argv[4]).read()
for key in ("pi_extensions",):
    assert key not in rec, rec
assert "pi-extensions" not in out, out
norm = lambda s: s.replace(root, "<root>")
print(json.dumps([norm(a) for a in argv]))
PY
}
launch pi ABSENT && absent=$(shape) || { bad "absent launch"; cat "$work/out"; }
launch pi '[]' && empty=$(shape) || { bad "empty launch"; cat "$work/out"; }
if [ -n "${absent:-}" ] && [ "${absent:-}" = "${empty:-x}" ]; then
  ok "absent and empty lists launch byte-identically, with no key, field or output line"
else
  bad "absent vs empty"; echo "$absent"; echo "${empty:-}"
fi

# --- other agents ignore the key --------------------------------------------
if launch claude '["no-such-ext"]'; then
  ok "a Claude launch ignores a bad pi_extensions"
else
  bad "claude ignores pi_extensions"; cat "$work/out"
fi

# --- validate and doctor ----------------------------------------------------
n=$((n + 1)); root="$work/r$n"; make_root "$root" '["glm-usage","glm-usage","gone"]'
diag=$(NOGGING_ROOT="$root" python3 - "$root/scripts/nogg" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1])
for message, success in m["pi_extensions_diagnostics"]():
    print(("OK   " if success else "FAIL ") + message)
PY
) || true
if grep -q '^FAIL .*pi_extensions.*glm-usage' <<<"$diag" && grep -q '^FAIL .*pi_extensions.*gone' <<<"$diag"; then
  ok "doctor diagnostics FAIL on a duplicate and an unknown name"
else
  bad "doctor diagnostics"; echo "$diag"
fi
n=$((n + 1)); root="$work/r$n"; make_root "$root" '["glm-usage"]'
diag=$(NOGGING_ROOT="$root" python3 - "$root/scripts/nogg" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1])
print(m["pi_extensions_diagnostics"]())
PY
) || true
[ "$diag" = "[]" ] && ok "a valid list prints no diagnostic" || { bad "valid list diagnostics"; echo "$diag"; }

[ "$fail" -eq 0 ] && echo "all pi-extensions-launch checks passed"
exit "$fail"
