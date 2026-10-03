#!/usr/bin/env bash
# Focused checks for the interactive-bootstrap-tui change
# (openspec/changes/interactive-bootstrap-tui): scripts/bootstrap's
# TTY/flag detection and (as later TASK-IBT-00x land) the wizard's decision
# logic and stubbed-whiptail wiring.
#
# Every later step after the TTY/mode decision performs real installs (npm,
# apt, nvm, network) or opens a real dialog, so — same discipline as
# scripts/compatibility.test.sh's platform-gate check — this sources the
# script with NOGGING_BOOTSTRAP_NO_MAIN=1 to unit-check individual functions
# directly, never by letting the full script run to completion.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap="$root/scripts/bootstrap"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- TASK-IBT-001: decide_run_mode (pure decision logic) --------------------
run_mode() {
  # run_mode <interactive_flag> <tty_result>
  NOGGING_BOOTSTRAP_NO_MAIN=1 bash -c '. "$1" && decide_run_mode "$2" "$3"' \
    _ "$bootstrap" "$1" "$2"
}

[ "$(run_mode '' 1)" = "interactive" ] \
  || fail "auto-detect with a TTY did not resolve to interactive"
[ "$(run_mode '' 0)" = "non-interactive" ] \
  || fail "auto-detect without a TTY did not resolve to non-interactive"
[ "$(run_mode 1 0)" = "interactive" ] \
  || fail "--interactive did not force interactive mode without a TTY"
[ "$(run_mode 0 1)" = "non-interactive" ] \
  || fail "--non-interactive did not force non-interactive mode with a TTY"
printf 'decide_run_mode: ok\n'

# --- TASK-IBT-001: is_interactive_tty reads the real stdin/stdout ----------
if NOGGING_BOOTSTRAP_NO_MAIN=1 bash -c '. "$1" && is_interactive_tty' \
    _ "$bootstrap" < /dev/null; then
  fail "is_interactive_tty reported a TTY when stdin was /dev/null"
fi
printf 'is_interactive_tty: ok\n'

# --- TASK-IBT-001: no behavior change for existing non-interactive runs ----
# The platform gate (scripts/compatibility.test.sh's own check_platform
# tests) is the first thing main() runs and fails fast on an unsupported
# host — cheap, deterministic, and exercised here only to prove that adding
# --interactive/--non-interactive parsing left every pre-existing argument
# combination's output byte-for-byte identical.
gate_scratch=$(mktemp -d)
trap 'rm -rf "$gate_scratch"' EXIT
printf 'ID=fedora\n' > "$gate_scratch/os-release"

run_gate() {
  # run_gate <extra-args...> -> stdout+stderr, exit status via $?
  NOGGING_BOOTSTRAP_OS_RELEASE="$gate_scratch/os-release" \
    NOGGING_BOOTSTRAP_UNAME_M=riscv64 \
    bash "$bootstrap" --repo "$gate_scratch/repo" "$@"
}

baseline=$(run_gate 2>&1) && fail "unsupported platform unexpectedly succeeded"
with_non_interactive=$(run_gate --non-interactive 2>&1) \
  && fail "unsupported platform unexpectedly succeeded with --non-interactive"
with_interactive=$(run_gate --interactive 2>&1) \
  && fail "unsupported platform unexpectedly succeeded with --interactive"

[ "$baseline" = "$with_non_interactive" ] \
  || fail "--non-interactive changed the unsupported-platform gate's output"
[ "$baseline" = "$with_interactive" ] \
  || fail "--interactive changed the unsupported-platform gate's output"

rm -rf "$gate_scratch"
trap - EXIT
printf 'no behavior change for existing flag combinations: ok\n'
