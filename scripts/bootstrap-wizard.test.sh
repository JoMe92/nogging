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

# --- TASK-IBT-002: decide_post_whiptail_mode (pure decision logic) ---------
post_mode() {
  # post_mode <run_mode> <whiptail_ready>
  NOGGING_BOOTSTRAP_NO_MAIN=1 bash -c '. "$1" && decide_post_whiptail_mode "$2" "$3"' \
    _ "$bootstrap" "$1" "$2"
}

[ "$(post_mode interactive 1)" = "interactive" ] \
  || fail "a ready whiptail did not keep interactive mode"
[ "$(post_mode interactive 0)" = "non-interactive" ] \
  || fail "a failed whiptail install did not fall back to non-interactive"
[ "$(post_mode non-interactive 0)" = "non-interactive" ] \
  || fail "non-interactive was not stable with whiptail not ready"
[ "$(post_mode non-interactive 1)" = "non-interactive" ] \
  || fail "a ready whiptail wrongly upgraded non-interactive mode"
printf 'decide_post_whiptail_mode: ok\n'

# --- TASK-IBT-002: ensure_whiptail wiring, whiptail stubbed on PATH --------
# Real apt/sudo must never run in a test (same discipline as
# scripts/compatibility.test.sh's platform gate): PATH is narrowed to a
# scratch dir holding only stand-in binaries, so `command -v whiptail` and
# any `sudo`/`apt-get` call resolve to stubs, never the real tools. `bash`
# itself is resolved to an absolute path first — a PATH prefix assignment on
# the invoking command line affects that command's own lookup too, so a
# narrowed PATH must not be relied on to still contain `bash`.
real_bash=$(command -v bash)
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

whiptail_present_dir="$stub_dir/present"
mkdir -p "$whiptail_present_dir"
cat > "$whiptail_present_dir/whiptail" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$whiptail_present_dir/whiptail"

already_present_out=$(PATH="$whiptail_present_dir" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c '. "$1" && ensure_whiptail' _ "$bootstrap")
echo "$already_present_out" | grep -q 'whiptail .*skipped' \
  || fail "ensure_whiptail did not report an already-present whiptail as skipped"

missing_install_fails_dir="$stub_dir/missing-install-fails"
mkdir -p "$missing_install_fails_dir"
cat > "$missing_install_fails_dir/sudo" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$missing_install_fails_dir/sudo"

set +e
fail_out=$(PATH="$missing_install_fails_dir" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c '. "$1" && ensure_whiptail' _ "$bootstrap" 2>&1)
fail_status=$?
set -e
[ "$fail_status" -ne 0 ] \
  || fail "ensure_whiptail returned success when the apt install failed"
echo "$fail_out" | grep -q 'NOTE: could not install whiptail' \
  || fail "ensure_whiptail did not print the fallback NOTE on a failed install"

missing_install_ok_dir="$stub_dir/missing-install-ok"
mkdir -p "$missing_install_ok_dir"
cat > "$missing_install_ok_dir/sudo" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$missing_install_ok_dir/sudo"

install_ok_out=$(PATH="$missing_install_ok_dir" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c '. "$1" && ensure_whiptail' _ "$bootstrap")
echo "$install_ok_out" | grep -q 'whiptail .*installed' \
  || fail "ensure_whiptail did not report a successful install"

rm -rf "$stub_dir"
trap - EXIT
printf 'ensure_whiptail wiring: ok\n'
