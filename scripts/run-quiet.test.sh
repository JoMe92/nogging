#!/usr/bin/env bash
# `nogg run-quiet [--log PATH] [--tail N] -- <command>`: run one long command as
# ONE blocking call whose whole output is one summary line, plus the last N log
# lines on failure, so an agent never polls a running command and never re-reads
# a passing suite's output. The command's merged stdout+stderr stays in the log
# (stdin is /dev/null); the exit code is the command's own (128+N for a death by
# signal N, 127 for a command not found); SIGINT/SIGTERM reach the command; a
# missing `--` or command is a usage error (exit 2). It needs no Git, Beads,
# Dolt or more than a minimal config. Independent cases run in parallel so the
# file stays fast despite the bridge's start-up cost.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/test-env.sh
source "$here/lib/test-env.sh"
nogg="$here/nogg"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A consumer-like root: a minimal config, and no Git, Beads or Dolt at all.
fixture="$work/consumer"
mkdir -p "$fixture/.nogging" "$work/tmp"
printf '{"name": "fixture"}\n' > "$fixture/.nogging/config.json"
export TMPDIR="$work/tmp"
printf 'from-stdin\n' > "$work/stdin.txt"

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}
has() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
line() { sed -n "$2p" <<<"$1"; }               # <text> <n>: the n-th line
count() { if [[ -z "$1" ]]; then echo 0; else wc -l <<<"$1" | tr -d ' '; fi; }
logged() { sed -E 's/.*; log (.*)\)$/\1/' <<<"$(line "$1" 1)"; }   # log path of a summary

quiet() { # <case> <run-quiet args...>: run from outside any checkout, in the background
  local name="$1"; shift
  ( rc=0
    cd "$work"
    NOGGING_ROOT="$fixture" "$nogg" run-quiet "$@" \
      >"$work/$name.out" 2>"$work/$name.err" <"$work/stdin.txt" || rc=$?
    echo "$rc" >"$work/$name.rc" ) &
}
out() { cat "$work/$1.out"; }
err() { cat "$work/$1.err"; }
rc() { cat "$work/$1.rc"; }

hundred='for i in $(seq 1 100); do echo "line-$i"; done; exit 3'
printf 'stale-content\n' > "$work/fail.log"

mkdir -p "$work/tmp-ok"
TMPDIR="$work/tmp-ok" quiet ok -- true
quiet chatty --log "$work/new/dir/chatty.log" -- bash -c \
  'cat; for i in $(seq 1 500); do echo "chatty-$i"; done; echo to-stderr >&2; echo "args:$*"' _ --tail 3 -- x
quiet fail --log "$work/fail.log" -- bash -c "$hundred"
quiet tail5 --tail 5 -- bash -c "$hundred"
quiet tail0 --tail 0 -- false
quiet missing -- nogg-run-quiet-no-such-command
quiet killed -- bash -c 'kill -TERM $$'
quiet nodash touch "$work/nodash-ran"
quiet nocmd --
quiet noargs
quiet badtail --tail -1 -- true
mkdir -p "$work/floor-target"
quiet floor -- rm -rf "$work/floor-target"
quiet floorpath -- /usr/bin/sudo true
quiet floorglob -- mkfs.ext4 /dev/null
quiet floorok -- rm -f "$work/floor-other"
quiet floorenv -- env FOO=1 sudo true
quiet floortimeout -- timeout 5 sudo true
quiet floorfind -- find "$work/floor-target" -maxdepth 0 -exec rm -rf {} ';'
quiet floorscript -- bash -c "true && rm -rf '$work/floor-target'"
quiet floornested -- bash -lc "bash -c 'sudo true'"
quiet floorunparsable -- bash -c "echo 'unbalanced"
quiet floorscriptok -- bash -c 'echo fine && exit 0'
quiet masked -- env GH_TOKEN=ghp_examplevalue123 API_KEY=plain false

# Signal forwarding: signal the bridge itself once the command runs. The exec
# shim restores a default SIGINT, which a non-interactive shell's `&` ignores.
# The command gives up (exit 9) after ~10 s, so a lost signal fails, never hangs.
signalled() { # <case> <INT|TERM>: start a command that traps the signal
  local name="$1" sig="$2"
  NOGGING_ROOT="$fixture" python3 -c \
    'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
    "$nogg" run-quiet --log "$work/$name.log" -- \
    bash -c "trap 'echo got-$sig; exit 7' $sig; echo ready; for _ in \$(seq 1 200); do sleep 0.05; done; exit 9" \
    >"$work/$name.out" 2>"$work/$name.err" </dev/null &
  echo "$!" >"$work/$name.pid"
}
deliver() { # <case> <INT|TERM>: once the command is ready, signal the bridge; record its exit code
  local name="$1" sig="$2" pid rc=0
  pid=$(cat "$work/$name.pid")
  for _ in $(seq 1 200); do
    grep -qx ready "$work/$name.log" 2>/dev/null && break
    sleep 0.05
  done
  kill "-$sig" "$pid"
  wait "$pid" || rc=$?
  echo "$rc" >"$work/$name.rc"
}
signalled term TERM
signalled int INT
deliver term TERM
deliver int INT
wait

# --- success: one line, exit 0, the output in the log ------------------------
o=$(out ok)
check "success exits 0" test "$(rc ok)" = 0
check "success prints exactly one line" test "$(count "$o")" = 1
check "success prints the ok summary" bash -c '[[ $0 =~ ^ok:\ true\ \([0-9]+\.[0-9]\ s\)$ ]]' "$o"
check "success writes nothing to stderr" test -z "$(err ok)"
check "a passing run removes its default log" test -z "$(ls -A "$work/tmp-ok")"
log=$(logged "$(out tail5)")
check "a failing run keeps a new nogg-run-quiet.*.log in TMPDIR" \
  bash -c '[[ $0 == "$1"/nogg-run-quiet.*.log && -f $0 ]]' "$log" "$TMPDIR"
check "the default log is private (0600)" test "$(ls -l "$log" | cut -c1-10)" = "-rw-------"

o=$(out chatty)
log="$work/new/dir/chatty.log"
check "a chatty success still prints one line" test "$(count "$o")" = 1
check "a chatty success keeps its output out of stdout" lacks "$o" "chatty-1"
check "a chatty success writes nothing to stderr" test -z "$(err chatty)"
check "--log names the log in the summary" has "$o" "; log $log)"
check "--log creates the log's parent directories" test -f "$log"
check "the log keeps all of stdout" test "$(grep -c '^chatty-' "$log")" = 500
check "the log merges stderr" grep -qx to-stderr "$log"
check "the command reads /dev/null, not the caller's stdin" bash -c '! grep -q from-stdin "$0"' "$log"
check "options and -- after the first -- belong to the command" grep -qx -- "args:--tail 3 -- x" "$log"

# --- failure: the FAIL line, the log tail, the command's exit code ---------------
o=$(out fail)
check "a failure propagates the exit code" test "$(rc fail)" = 3
check "a failure prints the FAIL line with the quoted command" \
  has "$(line "$o" 1)" "FAIL (exit 3): bash -c 'for i in \$(seq 1 100);"
check "the FAIL line names the log" has "$(line "$o" 1)" "; log $work/fail.log)"
check "a failure prints the last 40 lines by default" test "$(count "$o")" = 41
check "the tail starts 40 lines from the end" test "$(line "$o" 2)" = line-61
check "the tail ends with the last line" test "$(line "$o" 41)" = line-100
check "a failure writes nothing to stderr" test -z "$(err fail)"
check "--log truncates an existing file" bash -c '! grep -q stale-content "$0"' "$work/fail.log"
check "the log is never truncated to the tail" test "$(grep -c '^line-' "$work/fail.log")" = 100

o=$(out tail5)
check "--tail 5 prints the FAIL line and five lines" test "$(count "$o")" = 6
check "--tail 5 starts at the fifth line from the end" test "$(line "$o" 2)" = line-96
check "--tail 5 ends with the last line" test "$(line "$o" 6)" = line-100
o=$(out tail0)
check "--tail 0 prints only the FAIL line" test "$(count "$o")" = 1
check "--tail 0 still propagates the exit code" test "$(rc tail0)" = 1
check "--tail 0 prints the FAIL line" has "$o" "FAIL (exit 1): false ("

o=$(out missing)
check "a command not found exits 127" test "$(rc missing)" = 127
check "a command not found prints one clear FAIL line" test "$(count "$o")" = 1
check "the not-found FAIL line names the command" \
  has "$o" "FAIL (exit 127): nogg-run-quiet-no-such-command (cannot start: command not found; log "
check "a death by signal exits 128+signal" test "$(rc killed)" = 143
check "a death by signal prints the FAIL line" has "$(out killed)" "FAIL (exit 143): bash -c "

# --- signals are forwarded and the summary still printed -----------------------
for sig in term int; do
  upper=$(tr '[:lower:]' '[:upper:]' <<<"$sig")
  check "SIG$upper reaches the command" grep -qx "got-$upper" "$work/$sig.log"
  check "SIG$upper: the command's exit code is propagated" test "$(rc "$sig")" = 7
  check "SIG$upper: the summary is still printed" has "$(line "$(out "$sig")" 1)" "FAIL (exit 7): bash -c "
done

# --- usage errors: exit 2, nothing run -----------------------------------------
check "a command without -- is a usage error" test "$(rc nodash)" = 2
check "a command without -- is not run" test ! -e "$work/nodash-ran"
check "a command without -- names the fix" has "$(err nodash)" "separate the command with --"
check "-- without a command is a usage error" test "$(rc nocmd)" = 2
check "-- without a command says so" has "$(err nocmd)" "a command is required after --"
check "run-quiet without arguments is a usage error" test "$(rc noargs)" = 2
check "a negative --tail is a usage error" test "$(rc badtail)" = 2
check "a usage error prints nothing on stdout" test -z "$(out nodash)$(out nocmd)$(out noargs)"

# --- the command floor applies to the wrapped command --------------------------
check "a floor command is refused with exit 2" test "$(rc floor)" = 2
check "a floor command is never run" test -d "$work/floor-target"
check "the refusal names the denied rule" has "$(err floor)" "the wrapped command could run Bash(rm -rf:*)"
check "a floor command named by path is refused" test "$(rc floorpath)" = 2
check "a floor glob entry (mkfs.*) is refused" test "$(rc floorglob)" = 2
check "a command outside the floor still runs" test "$(rc floorok)" = 0
check "a floor command behind env is refused" test "$(rc floorenv)" = 2
check "a floor command behind timeout is refused" test "$(rc floortimeout)" = 2
check "a floor command in find -exec is refused" test "$(rc floorfind)" = 2
check "a floor command inside bash -c is refused" test "$(rc floorscript)" = 2
check "a floor command in a nested shell script is refused" test "$(rc floornested)" = 2
check "an unparsable shell script is refused" test "$(rc floorunparsable)" = 2
check "a refused script is never run" test -d "$work/floor-target"
check "a shell script without a denied command runs" test "$(rc floorscriptok)" = 0

# A supervised session's own deny rules (e.g. a restricted profile's git push)
# apply to the wrapped command too; the floor applies everywhere.
printf '{"permissions": {"deny": ["Bash(git push:*)", "Bash(bd dolt push:*)", "Edit(openspec/**)"]}}\n' \
  > "$work/session.settings.json"
rules_out=$(NOGGING_ROOT="$fixture" python3 - "$nogg" "$work/session.settings.json" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg_rq", sys.argv[1]).load_module()
session = m.run_quiet_deny_rules({"effective_settings_path": sys.argv[2]})
operator = m.run_quiet_deny_rules(None)
for argv in (["git", "push", "origin"], ["bash", "-c", "bd dolt push"], ["sudo", "x"], ["git", "status"]):
    print(" ".join(argv), "|", m.run_quiet_denied(argv, session), "|", m.run_quiet_denied(argv, operator))
try:
    m.run_quiet_deny_rules({"effective_settings_path": sys.argv[2] + ".missing"})
    print("unreadable | allowed")
except RuntimeError:
    print("unreadable | refused")
PY
)
check "a session's own deny rule refuses the wrapped command" has "$rules_out" "git push origin | Bash(git push:*) | None"
check "a session deny rule applies inside bash -c" has "$rules_out" "bash -c bd dolt push | Bash(bd dolt push:*) | None"
check "the floor applies with session rules too" has "$rules_out" "sudo x | Bash(sudo:*) | Bash(sudo:*)"
check "an allowed command passes the session rules" has "$rules_out" "git status | None | None"
check "unreadable session deny rules fail closed" has "$rules_out" "unreadable | refused"

# --- credential-looking values are masked in the summary, not in the log ------
o=$(out masked)
check "a secret-named NAME=value is masked" has "$o" "'GH_TOKEN=***'"
check "a known token prefix never reaches the summary" lacks "$o" "ghp_examplevalue123"
check "an API_KEY value is masked" has "$o" "'API_KEY=***'"

if [[ $fail -ne 0 ]]; then
  echo "run-quiet checks failed" >&2
  exit 1
fi
echo "all run-quiet checks passed"
