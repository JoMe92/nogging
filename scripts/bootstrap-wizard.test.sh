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

# --- TASK-IBT-003: print_welcome_banner / confirm_install_target ----------
banner_out=$(NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c '. "$1" && print_welcome_banner' _ "$bootstrap")
# Tagline is letter-spaced (tracked small-caps style), so match the
# collapsed form rather than the literal spaced text.
echo "$banner_out" | tr -d ' ' | grep -Fq "structureforwhat'snext." \
  || fail "print_welcome_banner did not print the tagline"
# The block-art wordmark is 7 rows tall; check row count+width rather than
# literal text since each letter is drawn, not spelled.
banner_art_rows=$(printf '%s\n' "$banner_out" | grep -c '####')
[ "$banner_art_rows" -ge 2 ] \
  || fail "print_welcome_banner's block-art wordmark looks malformed (expected multiple '####' rows, got $banner_art_rows)"

# confirm_install_target is a thin pass-through to `whiptail --yesno`'s own
# exit status (design.md, Decision 5) — stub whiptail on PATH to prove the
# call is wired (title/target passed through, exit status propagated),
# never stubbing the decision itself since there is none to factor out here.
confirm_stub_dir=$(mktemp -d)
trap 'rm -rf "$confirm_stub_dir"' EXIT

cat > "$confirm_stub_dir/whiptail" <<'STUB'
#!/bin/sh
# Records the full invocation so the test can assert on title/content, and
# exits with the code named by WHIPTAIL_STUB_EXIT (defaulting to 0/"Yes").
printf '%s\n' "$*" >> "$WHIPTAIL_STUB_LOG"
exit "${WHIPTAIL_STUB_EXIT:-0}"
STUB
chmod +x "$confirm_stub_dir/whiptail"

confirm_log="$confirm_stub_dir/calls.log"
: > "$confirm_log"
PATH="$confirm_stub_dir" WHIPTAIL_STUB_LOG="$confirm_log" WHIPTAIL_STUB_EXIT=0 \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && confirm_install_target /tmp/fake-target' _ "$bootstrap" \
  || fail "confirm_install_target returned failure for a whiptail 'Yes' answer (exit 0)"
grep -q -- '--yesno' "$confirm_log" \
  || fail "confirm_install_target did not call whiptail --yesno"
grep -q 'Install Nogging into: /tmp/fake-target' "$confirm_log" \
  || fail "confirm_install_target did not pass the install target to whiptail"

: > "$confirm_log"
if PATH="$confirm_stub_dir" WHIPTAIL_STUB_LOG="$confirm_log" WHIPTAIL_STUB_EXIT=1 \
    NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
    '. "$1" && confirm_install_target /tmp/fake-target' _ "$bootstrap"
then
  fail "confirm_install_target returned success for a whiptail 'No' answer (exit 1)"
fi

rm -rf "$confirm_stub_dir"
trap - EXIT
printf 'confirm_install_target wiring: ok\n'

# --- TASK-IBT-004: apply_checklist_answer (pure decision logic) -----------
checklist_vars() {
  # checklist_vars <answer> -> "with_pi no_beads no_hooks no_systemd"
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
    '. "$1" && apply_checklist_answer "$2" && echo "$with_pi $no_beads $no_hooks $no_systemd"' \
    _ "$bootstrap" "$1"
}

[ "$(checklist_vars '')" = "0 1 1 1" ] \
  || fail "an empty checklist answer did not map to every flag skipped"
[ "$(checklist_vars '"pi" "systemd" "hooks" "beads"')" = "1 0 0 0" ] \
  || fail "a fully-checked checklist answer did not map to every flag enabled"
[ "$(checklist_vars '"systemd" "beads"')" = "0 0 1 0" ] \
  || fail "a partial checklist answer was mapped incorrectly"
printf 'apply_checklist_answer: ok\n'

# --- TASK-IBT-004: checklist default state matches current flag values ----
# design.md, Decision 3/4: the checklist's default checked/unchecked state
# must match today's actual flag defaults exactly — verified here by
# checking prompt_optional_components' own default-ON/OFF wiring for both
# "nothing requested" and "everything requested" starting points.
checklist_stub_dir=$(mktemp -d)
trap 'rm -rf "$checklist_stub_dir"' EXIT
cat > "$checklist_stub_dir/whiptail" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WHIPTAIL_STUB_LOG"
exit 0
STUB
chmod +x "$checklist_stub_dir/whiptail"
checklist_log="$checklist_stub_dir/calls.log"

: > "$checklist_log"
PATH="$checklist_stub_dir" WHIPTAIL_STUB_LOG="$checklist_log" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && prompt_optional_components 0 0 0 0 >/dev/null' _ "$bootstrap"
grep -q 'pi Pi coding agent support OFF' "$checklist_log" \
  || fail "defaults (with_pi=0) did not show the Pi item unchecked"
grep -q 'systemd systemd sync timer ON' "$checklist_log" \
  || fail "defaults (no_systemd=0) did not show the systemd item checked"
grep -q 'hooks git hooks ON' "$checklist_log" \
  || fail "defaults (no_hooks=0) did not show the hooks item checked"
grep -q 'beads Beads issue tracker init ON' "$checklist_log" \
  || fail "defaults (no_beads=0) did not show the beads item checked"

: > "$checklist_log"
PATH="$checklist_stub_dir" WHIPTAIL_STUB_LOG="$checklist_log" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && prompt_optional_components 1 1 1 1 >/dev/null' _ "$bootstrap"
grep -q 'pi Pi coding agent support ON' "$checklist_log" \
  || fail "with_pi=1 did not show the Pi item checked"
grep -q 'systemd systemd sync timer OFF' "$checklist_log" \
  || fail "no_systemd=1 did not show the systemd item unchecked"
grep -q 'hooks git hooks OFF' "$checklist_log" \
  || fail "no_hooks=1 did not show the hooks item unchecked"
grep -q 'beads Beads issue tracker init OFF' "$checklist_log" \
  || fail "no_beads=1 did not show the beads item unchecked"

rm -rf "$checklist_stub_dir"
trap - EXIT
printf 'prompt_optional_components default state: ok\n'

# --- TASK-IBT-004: prompt_install_path returns the typed answer -----------
path_stub_dir=$(mktemp -d)
trap 'rm -rf "$path_stub_dir"' EXIT
cat > "$path_stub_dir/whiptail" <<'STUB'
#!/bin/sh
# Real whiptail writes its --inputbox answer to its own stderr (fd 2); the
# caller's `3>&1 1>&2 2>&3` dance routes that back to the captured stdout.
printf '%s\n' "$*" >> "$WHIPTAIL_STUB_LOG"
printf '%s' "$WHIPTAIL_STUB_ANSWER" >&2
exit "${WHIPTAIL_STUB_EXIT:-0}"
STUB
chmod +x "$path_stub_dir/whiptail"
path_log="$path_stub_dir/calls.log"
: > "$path_log"

typed=$(PATH="$path_stub_dir" WHIPTAIL_STUB_LOG="$path_log" \
  WHIPTAIL_STUB_ANSWER="/opt/my-repo" WHIPTAIL_STUB_EXIT=0 \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && prompt_install_path /default/path' _ "$bootstrap")
[ "$typed" = "/opt/my-repo" ] \
  || fail "prompt_install_path did not return the typed answer (got: $typed)"
grep -q '/default/path' "$path_log" \
  || fail "prompt_install_path did not pass the default path to whiptail"

if PATH="$path_stub_dir" WHIPTAIL_STUB_LOG="$path_log" WHIPTAIL_STUB_EXIT=1 \
    NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
    '. "$1" && prompt_install_path /default/path' _ "$bootstrap" > /dev/null
then
  fail "prompt_install_path returned success for a Cancel answer (exit 1)"
fi

rm -rf "$path_stub_dir"
trap - EXIT
printf 'prompt_install_path wiring: ok\n'

# --- TASK-IBT-004: run_nogging_init forwards the checklist's flags --------
# Maps answers onto the exact flags `init` already accepts — no new install
# logic (design.md, Decision 3): a stubbed `npx` proves the --no-beads/
# --no-hooks/--no-systemd flags reach it exactly when requested.
init_stub_dir=$(mktemp -d)
trap 'rm -rf "$init_stub_dir"' EXIT
cat > "$init_stub_dir/npx" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$NPX_STUB_LOG"
exit 0
STUB
chmod +x "$init_stub_dir/npx"
init_log="$init_stub_dir/calls.log"
init_repo="$init_stub_dir/repo"
mkdir -p "$init_repo/.git"

: > "$init_log"
NPX_STUB_LOG="$init_log" PATH="$init_stub_dir:$PATH" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && run_nogging_init "$2" 0 0 0' _ "$bootstrap" "$init_repo" > /dev/null 2>&1 || true
init_call=$(cat "$init_log")
echo "$init_call" | grep -q -- '--no-beads' && fail "run_nogging_init passed --no-beads when no_beads=0"
echo "$init_call" | grep -q -- '--no-hooks' && fail "run_nogging_init passed --no-hooks when no_hooks=0"
echo "$init_call" | grep -q -- '--no-systemd' && fail "run_nogging_init passed --no-systemd when no_systemd=0"

: > "$init_log"
NPX_STUB_LOG="$init_log" PATH="$init_stub_dir:$PATH" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && run_nogging_init "$2" 1 1 1' _ "$bootstrap" "$init_repo" > /dev/null 2>&1 || true
init_call=$(cat "$init_log")
echo "$init_call" | grep -q -- '--no-beads' || fail "run_nogging_init dropped --no-beads when no_beads=1"
echo "$init_call" | grep -q -- '--no-hooks' || fail "run_nogging_init dropped --no-hooks when no_hooks=1"
echo "$init_call" | grep -q -- '--no-systemd' || fail "run_nogging_init dropped --no-systemd when no_systemd=1"

rm -rf "$init_stub_dir"
trap - EXIT
printf 'run_nogging_init flag forwarding: ok\n'

# --- TASK-IBT-005: auth checks, exercised against the real CLIs ------------
# gh/codex are genuinely installed on this host; these checks are read-only
# (an auth *status* query, never a login), so they are run for real here
# rather than only stubbed — proving the wiring against the actual CLIs
# whiptail's own dialog can't be exercised without a TTY, but the decision
# logic underneath it can.
if command -v gh > /dev/null 2>&1; then
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c '. "$1" && check_gh_auth' _ "$bootstrap" \
    || fail "check_gh_auth reported not-authenticated against a real, already-logged-in gh"
  printf 'check_gh_auth (real gh): ok\n'
else
  printf 'check_gh_auth (real gh): skipped — gh not on PATH\n'
fi

if command -v codex > /dev/null 2>&1; then
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c '. "$1" && check_codex_auth' _ "$bootstrap" \
    || fail "check_codex_auth reported not-authenticated against a real, already-logged-in codex"
  printf 'check_codex_auth (real codex): ok\n'
else
  printf 'check_codex_auth (real codex): skipped — codex not on PATH\n'
fi

claude_auth_result=$(NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && if check_claude_auth; then echo yes; else echo no; fi' _ "$bootstrap")
real_claude_creds="$HOME/.claude/.credentials.json"
if [ -f "$real_claude_creds" ]; then
  [ "$claude_auth_result" = "yes" ] \
    || fail "check_claude_auth said no despite $real_claude_creds existing"
else
  [ "$claude_auth_result" = "no" ] \
    || fail "check_claude_auth said yes despite $real_claude_creds not existing"
fi
printf 'check_claude_auth (real HOME): ok\n'

# --- TASK-IBT-005: an already-authenticated tool shows no dialog ----------
# HOME is overridden to a scratch dir so check_claude_auth is deterministic
# regardless of the real host's credential state.
auth_stub_dir=$(mktemp -d)
trap 'rm -rf "$auth_stub_dir"' EXIT

already_authed_bin="$auth_stub_dir/already-authed"
mkdir -p "$already_authed_bin"
cat > "$already_authed_bin/gh" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$already_authed_bin/codex" <<'STUB'
#!/bin/sh
echo "Logged in using ChatGPT"
exit 0
STUB
cat > "$already_authed_bin/whiptail" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WHIPTAIL_STUB_LOG"
exit 1
STUB
chmod +x "$already_authed_bin/gh" "$already_authed_bin/codex" "$already_authed_bin/whiptail"

auth_home="$auth_stub_dir/home"
mkdir -p "$auth_home/.claude"
: > "$auth_home/.claude/.credentials.json"

auth_log="$auth_stub_dir/calls.log"
: > "$auth_log"
already_authed_summary=$(PATH="$already_authed_bin" HOME="$auth_home" \
  WHIPTAIL_STUB_LOG="$auth_log" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && run_auth_step && printf "%s" "$auth_summary"' _ "$bootstrap")

[ ! -s "$auth_log" ] \
  || fail "run_auth_step showed a dialog for an already-authenticated tool: $(cat "$auth_log")"
echo "$already_authed_summary" | grep -q 'GitHub: already authenticated' \
  || fail "run_auth_step summary missing the already-authenticated GitHub line"
echo "$already_authed_summary" | grep -q 'Codex: already authenticated' \
  || fail "run_auth_step summary missing the already-authenticated Codex line"
echo "$already_authed_summary" | grep -q 'Claude Code: already authenticated' \
  || fail "run_auth_step summary missing the already-authenticated Claude Code line"
printf 'offer_login: already-authenticated tools show no dialog: ok\n'

# --- TASK-IBT-005: an unauthenticated tool offers, then hands off, login --
not_authed_bin="$auth_stub_dir/not-authed"
mkdir -p "$not_authed_bin"
cat > "$not_authed_bin/gh" <<'STUB'
#!/bin/sh
# Stateful stub: starts unauthenticated, becomes authenticated once
# `auth login` has been called — so a re-check after the hand-off actually
# reflects the login happening, the same as the real CLI would.
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  [ -f "$LOGGED_IN_MARKER" ] && exit 0
  exit 1
fi
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
  printf 'gh auth login\n' >> "$LOGIN_CALL_LOG"
  : > "$LOGGED_IN_MARKER"
  exit 0
fi
exit 1
STUB
cat > "$not_authed_bin/whiptail" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WHIPTAIL_STUB_LOG"
exit "${WHIPTAIL_STUB_EXIT:-0}"
STUB
chmod +x "$not_authed_bin/gh" "$not_authed_bin/whiptail"

empty_home="$auth_stub_dir/empty-home"
mkdir -p "$empty_home"
login_log="$auth_stub_dir/login-calls.log"
dialog_log="$auth_stub_dir/dialog-calls.log"
logged_in_marker="$auth_stub_dir/logged-in-marker"

: > "$login_log"; : > "$dialog_log"; rm -f "$logged_in_marker"
yes_summary=$(PATH="$not_authed_bin" HOME="$empty_home" \
  LOGIN_CALL_LOG="$login_log" LOGGED_IN_MARKER="$logged_in_marker" \
  WHIPTAIL_STUB_LOG="$dialog_log" WHIPTAIL_STUB_EXIT=0 \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && offer_login GitHub check_gh_auth gh auth login && printf "%s" "$auth_summary"' \
  _ "$bootstrap")
grep -q -- '--yesno' "$dialog_log" \
  || fail "offer_login did not show a dialog for an unauthenticated tool"
grep -q 'gh auth login' "$login_log" \
  || fail "offer_login did not hand off to the login command on a Yes answer"
echo "$yes_summary" | grep -q 'GitHub: logged in just now' \
  || fail "offer_login summary did not report a successful just-now login"

: > "$login_log"; : > "$dialog_log"; rm -f "$logged_in_marker"
no_summary=$(PATH="$not_authed_bin" HOME="$empty_home" \
  LOGIN_CALL_LOG="$login_log" LOGGED_IN_MARKER="$logged_in_marker" \
  WHIPTAIL_STUB_LOG="$dialog_log" WHIPTAIL_STUB_EXIT=1 \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && offer_login GitHub check_gh_auth gh auth login && printf "%s" "$auth_summary"' \
  _ "$bootstrap")
[ ! -s "$login_log" ] \
  || fail "offer_login ran the login command despite a No answer"
echo "$no_summary" | grep -q 'GitHub: skipped' \
  || fail "offer_login summary did not report a declined login as skipped"

rm -rf "$auth_stub_dir"
trap - EXIT
printf 'offer_login: unauthenticated tool offers and hands off login: ok\n'
