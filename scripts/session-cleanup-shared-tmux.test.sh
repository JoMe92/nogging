#!/usr/bin/env bash
# TASK-HHB-001: cleanup stops the shared tmux server only when its own listing
# succeeds and is empty, never because this checkout's records are retired.
# Tests MUST comply with Decision 1 rules:
# - No Dolt or bd daemon (bd is stubbed via PATH)
# - No PID-range assumptions
# - Sockets in /tmp/nogg.XXXXXX with path length < 108 bytes
# - Clean environment: unset inherited NOGG_*, HERDR_*, TMUX
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs

# Test fixtures must not inherit the supervised agent's private session context.
while IFS='=' read -r name _; do
  case "$name" in NOGG_*|HERDR_*|TMUX|NOGGING_ROOT) unset "$name" ;; esac
done < <(env)

source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

work="$(mktemp -d /tmp/nogg.XXXXXX)"
trap 'rm -rf "$work"' EXIT

[[ "${#work}" -lt 100 ]] || { echo "work path too long for socket tests: $work" >&2; exit 1; }

bin="$work/bin"
mkdir -p "$bin"

# Stub bd
cat >"$bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "show" ]]; then
  id="${2:-}"
  for k in ${BD_KNOWN:-}; do
    if [[ "$k" == "$id" ]]; then printf '[{"id":"%s","title":"stub bead"}]\n' "$id"; exit 0; fi
  done
  echo '[]'; exit 1
fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then
  printf '%s\n' "${BD_DEP_LIST_JSON:-[]}"
  exit 0
fi
printf 'bd %s\n' "$*" >>"${BD_MUTATION_LOG:-/dev/null}"
echo "stub bd: refusing mutation: $*" >&2
exit 1
STUB
chmod +x "$bin/bd"

# Stateful tmux stub over TMUX_STUB_DIR
cat >"$bin/tmux" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?TMUX_STUB_DIR unset}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"

arg_after() { local flag="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$flag" ]] && { printf '%s' "$2"; return; }; shift; done; }

case "$cmd" in
  new-session)
    name="$(arg_after -s "$@")"
    touch "$d/sess-$name"
    ;;
  has-session)
    name="$(arg_after -t "$@")"
    [[ -f "$d/sess-$name" ]]
    ;;
  list-sessions)
    if [[ -n "${TMUX_STUB_FAIL_LIST:-}" ]]; then
      echo "error connecting to server" >&2
      exit 1
    fi
    for f in "$d"/sess-*; do
      [[ -e "$f" ]] || continue
      echo "${f##*/sess-}"
    done
    ;;
  kill-session)
    name="$(arg_after -t "$@")"
    rm -f "$d/sess-$name"
    ;;
  kill-server)
    echo "kill-server called" >>"$d/server-stopped.log"
    rm -f "$d"/sess-*
    ;;
  display-message)
    # Return fake PID
    echo "12345"
    ;;
  pipe-pane|send-keys|attach)
    :
    ;;
  *)
    :
    ;;
esac
STUB
chmod +x "$bin/tmux"

export PATH="$bin:$PATH"

fail=0
check() { if grep -qF -- "$2" "$1"; then echo "ok   - $3"; else echo "FAIL - $3 (missing: $2)"; cat "$1"; fail=1; fi; }
refute() { if grep -qF -- "$2" "$1"; then echo "FAIL - $3 (present: $2)"; cat "$1"; fail=1; else echo "ok   - $3"; fi; }

# Helper to create a minimal checkout
repo_dir="$work/repo"
mkdir -p "$repo_dir/.nogging/state" "$repo_dir/scripts" "$repo_dir/openspec"
cp "$source_root/scripts/session-launch" "$source_root/scripts/session-log-writer" "$source_root/scripts/openspec-sandbox" "$repo_dir/scripts/"
(cd "$repo_dir" && git init -q && git config user.email "test@example.com" && git config user.name "Test")
copy_host_config "$source_root/.nogging/config.json" "$repo_dir/.nogging/config.json"
python3 - "$repo_dir/.nogging/config.json" "$repo_dir/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None)
cfg.pop("session_launch_prompt", None)
cfg["session_stop_grace_seconds"] = 0.1
cfg["session_backend"] = "tmux"
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
cp -r "$source_root/.nogging/launch-profiles" "$repo_dir/.nogging/"
cp -r "$source_root/.nogging/launch-prompts" "$repo_dir/.nogging/"

nogg="$source_root/scripts/nogg"
out="$work/out.log"
tmux_stub="$work/tmux-stub"
mkdir -p "$tmux_stub"
export TMUX_STUB_DIR="$tmux_stub"
export NOGGING_ROOT="$repo_dir"

# ---------------------------------------------------------------------------
# Test 1: Foreign orchestrator session present on shared server while local records are retired.
# Expected: Server is NOT stopped (no kill-server issued, stop message not printed).
# ---------------------------------------------------------------------------
export BD_KNOWN="SPEC-test1"
"$nogg" session launch --role lead --bead SPEC-test1 >"$out" 2>&1 || { echo "FAIL - session launch failed:"; cat "$out"; exit 1; }
name="$(ls "$repo_dir/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
"$nogg" session stop "$name" >/dev/null 2>&1

# Add foreign orchestrator session to the shared tmux server
touch "$tmux_stub/sess-nogg-orchestrator-shared"

"$nogg" session cleanup >"$out" 2>&1 || { echo "FAIL - Test 1 cleanup errored"; cat "$out"; fail=1; }
check "$out" "retired $name" "Test 1: local stopped record is retired"
refute "$out" "Nogging tmux server stopped" "Test 1: cleanup keeps server when foreign orchestrator is active"
if [[ -f "$tmux_stub/server-stopped.log" ]] && grep -qF "kill-server" "$tmux_stub/server-stopped.log"; then
  echo "FAIL - Test 1: kill-server was issued despite foreign orchestrator session"
  fail=1
else
  echo "ok   - Test 1: no kill-server logged when foreign orchestrator session present"
fi
if [[ -f "$tmux_stub/sess-nogg-orchestrator-shared" ]]; then
  echo "ok   - Test 1: foreign orchestrator session preserved on server"
else
  echo "FAIL - Test 1: foreign orchestrator session was killed"
  fail=1
fi

# ---------------------------------------------------------------------------
# Test 2: Server empty (list-sessions succeeds with no sessions).
# Expected: Server stopped and "no active sessions remain; Nogging tmux server stopped" printed.
# ---------------------------------------------------------------------------
rm -f "$tmux_stub/sess-nogg-orchestrator-shared"
rm -f "$tmux_stub/server-stopped.log"
export BD_KNOWN="SPEC-test2"
"$nogg" session launch --role lead --bead SPEC-test2 >"$out" 2>&1 || { echo "FAIL - session launch 2 failed:"; cat "$out"; exit 1; }
name2="$(ls "$repo_dir/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | grep 'test2' | sed 's/\.json$//')"
"$nogg" session stop "$name2" >/dev/null 2>&1

"$nogg" session cleanup >"$out" 2>&1 || { echo "FAIL - Test 2 cleanup errored"; cat "$out"; fail=1; }
check "$out" "retired $name2" "Test 2: local stopped record is retired"
check "$out" "no active sessions remain; Nogging tmux server stopped" "Test 2: stop message printed on empty server"
if [[ -f "$tmux_stub/server-stopped.log" ]] && grep -qF "kill-server" "$tmux_stub/server-stopped.log"; then
  echo "ok   - Test 2: kill-server issued when server empty"
else
  echo "FAIL - Test 2: kill-server was not issued when server empty"
  fail=1
fi

# ---------------------------------------------------------------------------
# Test 3: Failed listing (list-sessions exits non-zero).
# Expected: Server is NOT stopped (failed listing counts as not empty).
# ---------------------------------------------------------------------------
rm -f "$tmux_stub/server-stopped.log"
export TMUX_STUB_FAIL_LIST=1

"$nogg" session cleanup >"$out" 2>&1 || { echo "FAIL - Test 3 cleanup errored"; cat "$out"; fail=1; }
refute "$out" "Nogging tmux server stopped" "Test 3: stop message not printed on failed listing"
if [[ -f "$tmux_stub/server-stopped.log" ]] && grep -qF "kill-server" "$tmux_stub/server-stopped.log"; then
  echo "FAIL - Test 3: kill-server was issued on failed listing"
  fail=1
else
  echo "ok   - Test 3: no kill-server issued on failed listing"
fi

if [[ $fail -ne 0 ]]; then
  echo "session-cleanup-shared-tmux tests failed" >&2
  exit 1
fi
echo "all session-cleanup-shared-tmux tests passed"
