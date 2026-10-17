#!/usr/bin/env bash
# Fail-fast agent launch (TASK-LHF-002, issue #195).
#
# Covered:
#   - an agent binary missing from PATH is refused before any record, log,
#     reservation or tmux call, and the message names the binary;
#   - a present binary launches normally and prints the kickoff hint;
#   - a backend session that dies inside the settle window yields a non-zero
#     exit, the startup-log tail in the error, a `failed` record, no kickoff
#     hint and no chained --kickoff delivery.
#
# bd and tmux are PATH-injected stubs; the settle clock and sleep are injected
# through a small driver, so no test waits on a real deadline.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib/test-env.sh"
unset HERDR_SESSION HERDR_ENV TMUX TMUX_TMPDIR
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(NOGGING_|HERDR_)' || true)
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/agents" "$work/sys"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then printf '[{"id":"%s","title":"stub"}]\n' "${2:-}"; exit 0; fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
echo "stub bd: refusing $*" >&2; exit 1
STUB
# tmux stub: a session exists once new-session ran, unless $TMUX_DIE is set
# (the agent "died at once"); every call is logged.
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"
case "$cmd" in
  new-session) : >"$d/started" ;;
  has-session) [[ -e "$d/started" && -z "${TMUX_DIE:-}" ]] || exit 1 ;;
  list-sessions) if [[ -e "$d/started" && -z "${TMUX_DIE:-}" ]]; then echo stub-session; else exit 1; fi ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/agents/claude"
chmod +x "$work/bin/"* "$work/agents/claude"
# A PATH holding only the system tools the launcher needs: no agent binary.
for tool in python3 git bash env sh cat date mkdir rm uname hostname id sed grep head tail tr; do
  p=$(command -v "$tool" 2>/dev/null || true)
  [[ -n "$p" ]] && ln -sf "$p" "$work/sys/$tool"
done

# Driver: run the real CLI with the settle clock/sleep injected.
cat >"$work/drive.py" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("nogg_drive", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
sys.modules[loader.name] = m
loader.exec_module(m)
fake = [0.0]
def sleep(s): fake[0] += s
m._settle_clock = lambda: fake[0]
m._settle_sleep = sleep
sys.argv = ["nogg"] + sys.argv[2:]
try:
    m.main()
except Exception as exc:
    print(f"nogg: {exc}", file=sys.stderr); sys.exit(1)
print(f"settle-slept={fake[0]}")
PY

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/scripts" "$r/openspec"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$r/scripts/"
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
setup() {
  n=$((n + 1))
  root="$work/r$n"; make_root "$root"
  export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/t$n"
  mkdir -p "$TMUX_STUB_DIR"
}
calls() { cat "$TMUX_STUB_DIR/calls.log" 2>/dev/null || true; }
sessions_dir() { echo "$root/.nogging/state/sessions"; }
base_path="$work/bin:$work/sys"

# --- 1. missing binary: refused before any side effect -----------------------
setup
if PATH="$base_path" python3 "$nogg" session launch --role lead --bead SPEC-bin --full-access >"$out" 2>&1; then
  bad "missing binary: launch should be refused"
else
  grep -qF "agent binary 'claude' not found on PATH" "$out" \
    && ok "missing binary: refusal names the binary" || bad "missing binary: message does not name it"
  [[ -z "$(ls -A "$(sessions_dir)" 2>/dev/null)" ]] \
    && ok "missing binary: no record or log created" || bad "missing binary: session state left behind"
  [[ -z "$(calls)" ]] \
    && ok "missing binary: no tmux call made" || { bad "missing binary: tmux reached"; calls; }
fi

# the binary is named per agent
for pair in codex:codex antigravity:agy pi:pi; do
  agent="${pair%%:*}"; binary="${pair##*:}"
  setup
  if PATH="$base_path" python3 "$nogg" session launch --role lead --bead SPEC-bin --agent "$agent" >"$out" 2>&1; then
    bad "missing $binary: launch should be refused"
  else
    grep -qF "agent binary '$binary' not found on PATH" "$out" \
      && ok "missing $binary: refusal names $binary" || bad "missing $binary: message does not name it"
  fi
done

# --- 2. present binary: normal launch, nothing delayed ------------------------
setup
if PATH="$work/agents:$base_path" python3 "$work/drive.py" "$nogg" session launch --role lead --bead SPEC-bin --full-access >"$out" 2>&1; then
  grep -q "^launched sf-lead-spec-bin-" "$out" && ok "present binary: launch summary printed" || bad "present binary: no summary"
  grep -q "kickoff: this session will not act" "$out" \
    && ok "present binary: kickoff hint printed" || bad "present binary: kickoff hint missing"
  grep -q "settle-slept=2.0" "$out" \
    && ok "present binary: waited exactly the 2 s window (injected clock)" || bad "present binary: settle window not the fixed 2 s"
else
  bad "present binary: launch errored"
fi

# the runner-only override can shorten the window but never lengthen it
setup
if NOGG_LAUNCH_SETTLE_SECONDS=0.5 PATH="$work/agents:$base_path" python3 "$work/drive.py" "$nogg" session launch --role lead --bead SPEC-bin --full-access >"$out" 2>&1 \
   && grep -q "settle-slept=0.5" "$out"; then ok "override shortens the window"; else bad "override did not shorten the window"; fi
setup
if NOGG_LAUNCH_SETTLE_SECONDS=60 PATH="$work/agents:$base_path" python3 "$work/drive.py" "$nogg" session launch --role lead --bead SPEC-bin --full-access >"$out" 2>&1 \
   && grep -q "settle-slept=2.0" "$out"; then ok "override cannot lengthen the window past 2 s"; else bad "override lengthened the window"; fi

# --- 3. session dies inside the settle window ---------------------------------
setup
if TMUX_DIE=1 PATH="$work/agents:$base_path" python3 "$work/drive.py" "$nogg" session launch \
     --role lead --bead SPEC-bin --full-access --kickoff >"$out" 2>&1; then
  bad "early death: launch should exit non-zero"
else
  ok "early death: exits non-zero"
  grep -q "agent session ended during startup" "$out" \
    && ok "early death: error says the session ended" || bad "early death: wrong error"
  grep -q "startup log:" "$out" \
    && ok "early death: startup-log tail shown" || bad "early death: no startup-log tail"
  ! grep -q "kickoff: this session will not act" "$out" \
    && ok "early death: no kickoff hint" || bad "early death: kickoff hint printed"
  ! grep -q "^launched " "$out" \
    && ok "early death: no success summary" || bad "early death: success summary printed"
  ! calls | grep -qE "^(send-keys|load-buffer|paste-buffer)" \
    && ok "early death: no chained --kickoff delivery" || { bad "early death: kickoff delivered"; calls; }
  rec=$(ls "$(sessions_dir)"/*.json | grep -v settings | head -1)
  python3 - "$rec" <<'PY' && ok "early death: record is failed with a reason" || bad "early death: record not failed"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["state"] == "failed", r["state"]
assert "ended during startup" in r["exit_reason"], r["exit_reason"]
PY
fi

# --- 4. startup-log tail reaches the error ------------------------------------
setup
python3 - "$nogg" "$work" <<'PY' && ok "log tail: included, redacted, record failed" || { echo "FAIL - log tail"; fail=1; }
import importlib.machinery, importlib.util, json, os, sys, tempfile
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("nogg_tail", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
sys.modules[loader.name] = m; loader.exec_module(m)
d = Path(tempfile.mkdtemp(dir=sys.argv[2]))
log, rec_path = d / "s.log", d / "s.json"
log.write_text("# header\nexec: claude: not found\nTOKEN=hunter2hunter2\n")
record = {"name": "s", "state": "running", "log_path": str(log), "backend_ref": {"name": "s"}}
rec_path.write_text(json.dumps(record))
class Gone:
    def exists(self, ref): return False
m.transition = lambda path, rec, state, **kw: rec.update(state=state, exit_reason=kw["exit_reason"])
try:
    m.settle_launch(Gone(), rec_path, record)
except m.ToolError as exc:
    msg = str(exc)
else:
    raise AssertionError("dead session settled")
assert "exec: claude: not found" in msg, msg
assert "hunter2hunter2" not in msg, msg
assert record["state"] == "failed"
# a live session returns once the injected window elapses, never longer
now = [0.0]
m._settle_clock = lambda: now[0]
def sleep(s): now[0] += s
m._settle_sleep = sleep
class Alive:
    def exists(self, ref): return True
record["state"] = "running"; rec_path.write_text(json.dumps(record))
m.settle_launch(Alive(), rec_path, record)
assert now[0] == m.LAUNCH_SETTLE_SECONDS == 2.0, now[0]
PY

exit $fail
