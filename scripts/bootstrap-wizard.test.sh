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
echo "$banner_out" | tr -d ' ' | grep -Fq "structureforateamofagents." \
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
# logic underneath it can. Authentication state itself is NOT assumed (a
# dev host may be logged in; a CI runner ships gh/codex preinstalled but
# unauthenticated by default) — each check is compared against the real
# command's own ground-truth outcome, the same way the check_claude_auth
# block below it already does via real file existence.
if command -v gh > /dev/null 2>&1; then
  expected_gh=no
  gh auth status > /dev/null 2>&1 && expected_gh=yes
  actual_gh=no
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c '. "$1" && check_gh_auth' _ "$bootstrap" \
    > /dev/null 2>&1 && actual_gh=yes
  [ "$actual_gh" = "$expected_gh" ] \
    || fail "check_gh_auth ($actual_gh) disagreed with gh auth status ($expected_gh)"
  printf 'check_gh_auth (real gh): ok\n'
else
  printf 'check_gh_auth (real gh): skipped — gh not on PATH\n'
fi

if command -v codex > /dev/null 2>&1; then
  codex_real_out=$(codex login status 2>&1); codex_real_exit=$?
  expected_codex=no
  case "$codex_real_out" in
    *"Logged in"*) [ "$codex_real_exit" -eq 0 ] && expected_codex=yes ;;
  esac
  actual_codex=no
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c '. "$1" && check_codex_auth' _ "$bootstrap" \
    > /dev/null 2>&1 && actual_codex=yes
  [ "$actual_codex" = "$expected_codex" ] \
    || fail "check_codex_auth ($actual_codex) disagreed with codex login status ($expected_codex)"
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

# --- TASK-IBT-006: build_closing_summary (pure decision logic) ------------
summary_text() {
  # summary_text <with_pi> <no_beads> <no_hooks> <no_systemd> <auth_summary>
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
    '. "$1" && build_closing_summary /opt/repo "$2" "$3" "$4" "$5" "$6"' \
    _ "$bootstrap" "$1" "$2" "$3" "$4" "$5"
}

all_installed=$(summary_text 1 0 0 0 'GitHub: already authenticated
')
echo "$all_installed" | grep -q 'Installed:.*Pi coding agent' \
  || fail "closing summary did not list Pi as installed when with_pi=1"
echo "$all_installed" | grep -q 'Installed:.*Beads issue tracking' \
  || fail "closing summary did not list Beads as installed when no_beads=0"
echo "$all_installed" | grep -q '^Skipped: nothing$' \
  || fail "closing summary did not report 'nothing' skipped when every component was installed"
echo "$all_installed" | grep -q 'GitHub: already authenticated' \
  || fail "closing summary did not include the auth step's own summary"
echo "$all_installed" | grep -q 'Next: cd /opt/repo && ./scripts/nogg doctor' \
  || fail "closing summary did not name the next command to run"

all_skipped=$(summary_text 0 1 1 1 '')
echo "$all_skipped" | grep -q 'Skipped:.*Pi coding agent' \
  || fail "closing summary did not list Pi as skipped when with_pi=0"
echo "$all_skipped" | grep -q 'Skipped:.*Beads issue tracking' \
  || fail "closing summary did not list Beads as skipped when no_beads=1"
echo "$all_skipped" | grep -q 'Skipped:.*git hooks' \
  || fail "closing summary did not list git hooks as skipped when no_hooks=1"
echo "$all_skipped" | grep -q 'Skipped:.*systemd sync timer' \
  || fail "closing summary did not list the systemd timer as skipped when no_systemd=1"
printf 'build_closing_summary: ok\n'

# --- TASK-IBT-006: show_closing_summary wiring -----------------------------
summary_stub_dir=$(mktemp -d)
trap 'rm -rf "$summary_stub_dir"' EXIT
cat > "$summary_stub_dir/whiptail" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WHIPTAIL_STUB_LOG"
exit 0
STUB
chmod +x "$summary_stub_dir/whiptail"
summary_log="$summary_stub_dir/calls.log"
: > "$summary_log"

PATH="$summary_stub_dir" WHIPTAIL_STUB_LOG="$summary_log" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c \
  '. "$1" && show_closing_summary "Installed: everything"' _ "$bootstrap"
grep -q -- '--msgbox' "$summary_log" \
  || fail "show_closing_summary did not call whiptail --msgbox"
grep -q 'Installed: everything' "$summary_log" \
  || fail "show_closing_summary did not pass the summary text to whiptail"

rm -rf "$summary_stub_dir"
trap - EXIT
printf 'show_closing_summary wiring: ok\n'

# --- TASK-IBT-007: the full wizard sequence, chained end-to-end ------------
# Every dialog's decision logic is already factored from the whiptail calls
# themselves (decide_run_mode, decide_post_whiptail_mode,
# apply_checklist_answer, build_closing_summary — each tested standalone
# above). This exercises the exact call order main() uses in interactive
# mode (confirm -> install path -> checklist -> auth -> summary) against one
# dispatching whiptail stub, proving the wiring end-to-end rather than
# function-by-function. The real installers (ensure_node et al.,
# run_nogging_init) stay out of scope here, same as everywhere else in this
# file — they are not whiptail/decision-logic concerns.
e2e_dir=$(mktemp -d)
trap 'rm -rf "$e2e_dir"' EXIT

cat > "$e2e_dir/whiptail" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WHIPTAIL_STUB_LOG"
case "$*" in
  *--yesno*) exit 0 ;;                                           # confirm: Yes
  *--inputbox*) printf '%s' "$E2E_CHOSEN_PATH" >&2; exit 0 ;;     # typed path
  *--checklist*) printf '%s' "$E2E_CHECKLIST_ANSWER" >&2; exit 0 ;;
  *--msgbox*) exit 0 ;;
esac
exit 1
STUB
chmod +x "$e2e_dir/whiptail"

cat > "$e2e_dir/gh" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$e2e_dir/codex" <<'STUB'
#!/bin/sh
echo "Logged in using ChatGPT"
exit 0
STUB
chmod +x "$e2e_dir/gh" "$e2e_dir/codex"

e2e_home="$e2e_dir/home"
mkdir -p "$e2e_home/.claude"
: > "$e2e_home/.claude/.credentials.json"

e2e_log="$e2e_dir/calls.log"
: > "$e2e_log"

e2e_script=$(cat <<'SCRIPT'
. "$1"
if ! confirm_install_target "/default/repo"; then exit 1; fi
chosen=$(prompt_install_path "/default/repo")
answer=$(prompt_optional_components 0 0 0 0)
apply_checklist_answer "$answer"
run_auth_step
summary=$(build_closing_summary "$chosen" "$with_pi" "$no_beads" "$no_hooks" "$no_systemd" "$auth_summary")
show_closing_summary "$summary" > /dev/null
printf 'REPO=%s WITH_PI=%s NO_BEADS=%s NO_HOOKS=%s NO_SYSTEMD=%s\n' \
  "$chosen" "$with_pi" "$no_beads" "$no_hooks" "$no_systemd"
printf '%s' "$summary"
SCRIPT
)

e2e_out=$(PATH="$e2e_dir" HOME="$e2e_home" WHIPTAIL_STUB_LOG="$e2e_log" \
  E2E_CHOSEN_PATH="/chosen/by/user" E2E_CHECKLIST_ANSWER='"pi" "beads"' \
  NOGGING_BOOTSTRAP_NO_MAIN=1 "$real_bash" -c "$e2e_script" _ "$bootstrap")

echo "$e2e_out" | grep -q 'REPO=/chosen/by/user WITH_PI=1 NO_BEADS=0 NO_HOOKS=1 NO_SYSTEMD=1' \
  || fail "end-to-end wizard sequence produced unexpected final state: $e2e_out"
echo "$e2e_out" | grep -q 'GitHub: already authenticated' \
  || fail "end-to-end wizard sequence summary missing the auth step's GitHub line"
echo "$e2e_out" | grep -q 'Next: cd /chosen/by/user && ./scripts/nogg doctor' \
  || fail "end-to-end wizard sequence summary missing the correct next-command line"

# Count distinct dialog *invocations*, not lines in the log — the summary
# dialog's own text is multi-line.
dialog_count=$(grep -oE -- '--(yesno|inputbox|checklist|msgbox)' "$e2e_log" | wc -l)
[ "$dialog_count" -eq 4 ] \
  || fail "expected exactly 4 whiptail dialogs (confirm, path, checklist, summary), got $dialog_count: $(cat "$e2e_log")"

rm -rf "$e2e_dir"
trap - EXIT
printf 'end-to-end wizard sequence (stubbed whiptail): ok\n'
