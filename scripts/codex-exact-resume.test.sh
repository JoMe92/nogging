#!/usr/bin/env bash
# Codex exact resume contract and argv regression coverage (TASK-HHB-010).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d /tmp/nogg.XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == show ]]; then printf '[{"id":"%s","title":"stub"}]\n' "${2:-}"; exit 0; fi
if [[ "${1:-}" == dep && "${2:-}" == list ]]; then echo '[]'; exit 0; fi
echo "unexpected bd call: $*" >&2; exit 1
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:1] == ["-L"]: args = args[2:]
def live_file(): return os.environ["TMUX_ARGV"] + ".live-" + args[args.index("-t" if args[0] == "has-session" else "-s") + 1]
if args[:1] == ["has-session"]: sys.exit(0 if os.path.exists(live_file()) else 1)
if args[:1] == ["list-sessions"]: sys.exit(1)
if args[:1] == ["new-session"]:
    open(live_file(), "w").close()
    with open(os.environ["TMUX_ARGV"], "w") as f:
        json.dump(args[args.index("--") + 1:], f)
    sys.exit(0)
sys.exit(0)
STUB
cat >"$work/bin/codex" <<'STUB'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if args[:2] == ["resume", "--help"]:
    fixture = pathlib.Path(os.environ["RESUME_HELP"])
    sys.stdout.write(fixture.read_text())
    sys.exit(0)
if args == ["--help"]:
    print("Usage: codex [OPTIONS]\n  --cd <DIR>\n  --sandbox <MODE>\n  --ask-for-approval <POLICY>\n  --add-dir <DIR>\n  --model <MODEL>\n  -c, --config <key=value>")
    sys.exit(0)
with open(os.environ["RUNTIME_ARGV"], "w") as f:
    json.dump(args, f)
STUB
chmod +x "$work/bin/"*
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep -E '^(NOGG_|HERDR_|TMUX$)')
export PATH="$work/bin:$PATH" RESUME_HELP="$here/fixtures/codex/codex-resume-help.txt"
export TMUX_ARGV="$work/tmux.json" RUNTIME_ARGV="$work/runtime.json"
export XDG_CACHE_HOME="$work/cache"

fail=0
ok() { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

python3 - "$here/nogg" "$here/session-launch" <<'PY'
import importlib.machinery, importlib.util, json, subprocess, sys
loader = importlib.machinery.SourceFileLoader("nogg_resume_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); sys.modules[loader.name] = m; loader.exec_module(m)
contract = json.loads(subprocess.check_output([sys.argv[2], "--contract"], text=True))
assert "codex-resume" in contract["features"]
argv = ["wrapper", "--agent", "codex", "--resume", "00000000-0000-4000-8000-000000000001"]
m.validate_launch_contract(contract, argv, "codex")
stale = dict(contract, features=[f for f in contract["features"] if f != "codex-resume"])
try: m.validate_launch_contract(stale, argv, "codex")
except RuntimeError as e: assert "Codex exact resume" in str(e)
else: raise AssertionError("stale resume contract accepted")
for bad in ("latest", "00000000-0000-4000-8000-00000000000A", "00000000000040008000000000000001"):
    try: m.validate_codex_resume_id(bad)
    except RuntimeError: pass
    else: raise AssertionError(f"invalid UUID accepted: {bad}")
m.validate_codex_resume_id("00000000-0000-4000-8000-000000000001")
help_text = "codex resume --help --cd --sandbox --ask-for-approval --add-dir --config --model"
m.validate_codex_resume_options(help_text)
try: m.validate_codex_resume_options(help_text.replace("--add-dir", ""), add_dir=True)
except RuntimeError as e: assert "--add-dir" in str(e)
else: raise AssertionError("missing authority option accepted")
PY
if [[ $? -eq 0 ]]; then ok "UUID and Codex resume contract validate"; else bad "UUID/contract validation"; fi

make_root() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/.nogging" "$root/.codex/rules" "$root/openspec"
  cp "$here/nogg" "$here/nogg_usage.py" "$here/session-launch" "$here/session-log-writer" "$here/openspec-sandbox" "$root/scripts/"
  cp -r "$here/lib" "$root/scripts/lib"
  mkdir -p "$root/.pi/extensions"
  cp "$here/../.pi/extensions/nogging-guard.ts" "$root/.pi/extensions/"
  : >"$root/.codex/rules/nogging.rules"
  cp -r "$here/../.nogging/launch-profiles" "$here/../.nogging/launch-prompts" "$root/.nogging/"
  cp "$here/../.nogging/config.json" "$root/.nogging/config.json"
  git init -q "$root"
}

root="$work/repo"
make_root "$root"
id=00000000-0000-4000-8000-000000000001
launch() {
  python3 - "$TMUX_ARGV" "$RUNTIME_ARGV" <<'CLEAR'
from pathlib import Path
import sys
for name in sys.argv[1:]: Path(name).unlink(missing_ok=True)
CLEAR
  if ! "$root/scripts/nogg" session launch --role lead --bead SPEC-rsm --agent codex --cwd "$root" --full-access "$@" >"$work/launch.log" 2>&1; then
    cat "$work/launch.log" >&2; return 1
  fi
  python3 - "$TMUX_ARGV" >"$work/wrapper.argv" <<'ARGS'
import json, sys
sys.stdout.buffer.write(b"\0".join(x.encode() for x in json.load(open(sys.argv[1]))) + b"\0")
ARGS
  local -a wrapper=()
  mapfile -d '' wrapper <"$work/wrapper.argv"
  "${wrapper[@]}" >"$work/wrapper.out" 2>"$work/wrapper.err" || {
    cat "$work/wrapper.err" >&2; return 1
  }
}

launch --resume "$id" --model test-model || bad "exact resume launch was refused"
if python3 - "$work/runtime.json" "$id" "$root" <<'PY'
import glob, json, pathlib, sys
argv = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert argv[0:2] == ["resume", sys.argv[2]], argv
assert not any("Startup only" in item or "Wait for" in item for item in argv), argv
for flag in ("--cd", "--sandbox", "--ask-for-approval", "--add-dir", "-c", "--model"):
    assert flag in argv, (flag, argv)
records = [json.loads(pathlib.Path(p).read_text()) for p in glob.glob(sys.argv[3]+"/.nogging/state/sessions/*.json")]
assert len(records) == 1 and records[0]["codex_thread_id"] == sys.argv[2], records
PY
then ok "resume passes authority flags without a prompt and records the thread ID"; else bad "resume argv and record"; fi

bad_root="$work/invalid"
make_root "$bad_root"
python3 - "$TMUX_ARGV" "$RUNTIME_ARGV" <<'CLEAR'
from pathlib import Path
import sys
for name in sys.argv[1:]: Path(name).unlink(missing_ok=True)
CLEAR
if "$bad_root/scripts/nogg" session launch --role lead --bead SPEC-bad --agent codex --cwd "$bad_root" --full-access --resume latest >"$work/invalid.log" 2>&1; then bad "invalid UUID launched"; else
  [[ ! -e "$work/tmux.json" && ! -d "$bad_root/.nogging/state/sessions" ]] && ok "invalid UUID refused before launch side effects" || bad "invalid UUID caused side effects"
fi

short_help="$work/short-help"
sed '/--add-dir/d' "$here/fixtures/codex/codex-resume-help.txt" >"$short_help"
unsupported="$work/unsupported"
make_root "$unsupported"
python3 - "$TMUX_ARGV" "$RUNTIME_ARGV" <<'CLEAR'
from pathlib import Path
import sys
for name in sys.argv[1:]: Path(name).unlink(missing_ok=True)
CLEAR
RESUME_HELP="$short_help"; export RESUME_HELP
if "$unsupported/scripts/nogg" session launch --role lead --bead SPEC-noopt --agent codex --cwd "$unsupported" --full-access --resume "$id" >"$work/unsupported.log" 2>&1; then bad "missing Codex flag accepted"; else
  [[ ! -e "$work/tmux.json" && ! -d "$unsupported/.nogging/state/sessions" ]] && ok "missing Codex flag refused before launch side effects" || bad "missing Codex flag caused side effects"
fi

(( fail == 0 )) || exit 1
