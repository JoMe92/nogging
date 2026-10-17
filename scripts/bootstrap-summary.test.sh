#!/usr/bin/env bash
# Tests for bootstrap plan block, closing summary, platform refusal,
# and doctor execution (openspec/changes/release-readme-installer, Decision 6).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap="$root/scripts/bootstrap"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- 1. Platform refusal has no 2.0.x ----------------------------------------
gate_scratch=$(mktemp -d)
trap 'rm -rf "$gate_scratch"' EXIT
printf 'ID=fedora\n' > "$gate_scratch/os-release"

set +e
refusal_out=$(NOGGING_BOOTSTRAP_OS_RELEASE="$gate_scratch/os-release" \
  NOGGING_BOOTSTRAP_UNAME_M=riscv64 \
  bash "$bootstrap" --repo "$gate_scratch/repo" 2>&1)
refusal_status=$?
set -e

[ "$refusal_status" -ne 0 ] || fail "unsupported platform unexpectedly succeeded"
echo "$refusal_out" | grep -q 'Nogging bootstrap supports Debian/Ubuntu-family Linux on x86_64 or aarch64' \
  || fail "platform refusal missing supported platform description"
echo "$refusal_out" | grep -q 'macOS, Windows, and WSL are unsupported' \
  || fail "platform refusal missing unsupported OS list"
echo "$refusal_out" | grep -q 'Nothing has been installed' \
  || fail "platform refusal missing 'Nothing has been installed'"
if echo "$refusal_out" | grep -q '2\.0\.x'; then
  fail "platform refusal contains stale 2.0.x wording"
fi
printf 'platform refusal has no 2.0.x: ok\n'

# --- 2. plan_* probes for present, missing, out-of-range with no installs ----
test_scratch=$(mktemp -d)
stub_dir="$test_scratch/stubs"
mkdir -p "$stub_dir"
install_log="$test_scratch/install_calls.log"
: > "$install_log"

# Install command stubs that log if called (must remain uncalled during probes)
cat > "$stub_dir/nvm" <<STUB
#!/bin/sh
echo "nvm \$*" >> "$install_log"
exit 0
STUB
cat > "$stub_dir/npm" <<STUB
#!/bin/sh
echo "npm \$*" >> "$install_log"
exit 0
STUB
cat > "$stub_dir/curl" <<STUB
#!/bin/sh
echo "curl \$*" >> "$install_log"
exit 0
STUB
cat > "$stub_dir/apt-get" <<STUB
#!/bin/sh
echo "apt-get \$*" >> "$install_log"
exit 0
STUB
cat > "$stub_dir/sudo" <<STUB
#!/bin/sh
echo "sudo \$*" >> "$install_log"
exit 0
STUB
chmod +x "$stub_dir"/*

clean_sys_bin="$test_scratch/clean_sys_bin"
mkdir -p "$clean_sys_bin"
for cmd in bash sh sed grep head tail cat tr wc rm mkdir chmod cp date; do
  p=$(command -v "$cmd" 2>/dev/null || true)
  [ -n "$p" ] && ln -sf "$p" "$clean_sys_bin/$cmd"
done

run_plan_fn() {
  # run_plan_fn <custom_bin_dir> <func> [args...]
  local custom_bin="$1"
  shift
  PATH="$custom_bin:$stub_dir:$clean_sys_bin" \
    NOGGING_BOOTSTRAP_NO_MAIN=1 bash -c '. "$1" && shift && "$@"' _ "$bootstrap" "$@"
}

empty_bin="$test_scratch/empty_bin"
mkdir -p "$empty_bin"

# Probe: node
node_present_bin="$test_scratch/node_present"
mkdir -p "$node_present_bin"
cat > "$node_present_bin/node" <<'STUB'
#!/bin/sh
if [ "$1" = "-p" ]; then echo 22; exit 0; fi
echo "v22.14.0"
STUB
chmod +x "$node_present_bin/node"

out=$(run_plan_fn "$node_present_bin" plan_node)
echo "$out" | grep -E 'node\s+present\s+v22\.14\.0' >/dev/null \
  || fail "plan_node did not report present for Node 22 (got: $out)"

node_old_bin="$test_scratch/node_old"
mkdir -p "$node_old_bin"
cat > "$node_old_bin/node" <<'STUB'
#!/bin/sh
if [ "$1" = "-p" ]; then echo 16; exit 0; fi
echo "v16.0.0"
STUB
chmod +x "$node_old_bin/node"

out=$(run_plan_fn "$node_old_bin" plan_node)
echo "$out" | grep -E 'node\s+upgrade\s+v16\.0\.0\s+→\s+22' >/dev/null \
  || fail "plan_node did not report upgrade for Node 16 (got: $out)"

out=$(run_plan_fn "$empty_bin" plan_node)
echo "$out" | grep -E 'node\s+install\s+22' >/dev/null \
  || fail "plan_node did not report install for missing Node (got: $out)"

# Probe: npm_global (claude)
claude_present_bin="$test_scratch/claude_present"
mkdir -p "$claude_present_bin"
cat > "$claude_present_bin/claude" <<'STUB'
#!/bin/sh
echo "2.1.260"
STUB
chmod +x "$claude_present_bin/claude"

out=$(run_plan_fn "$claude_present_bin" plan_npm_global "@anthropic-ai/claude-code" "2.1.260" claude)
echo "$out" | grep -E 'claude\s+present\s+2\.1\.260' >/dev/null \
  || fail "plan_npm_global did not report present for claude (got: $out)"

claude_old_bin="$test_scratch/claude_old"
mkdir -p "$claude_old_bin"
cat > "$claude_old_bin/claude" <<'STUB'
#!/bin/sh
echo "2.0.0"
STUB
chmod +x "$claude_old_bin/claude"

out=$(run_plan_fn "$claude_old_bin" plan_npm_global "@anthropic-ai/claude-code" "2.1.260" claude)
echo "$out" | grep -E 'claude\s+upgrade\s+2\.0\.0\s+→\s+2\.1\.260' >/dev/null \
  || fail "plan_npm_global did not report upgrade for claude (got: $out)"

out=$(run_plan_fn "$empty_bin" plan_npm_global "@anthropic-ai/claude-code" "2.1.260" claude)
echo "$out" | grep -E 'claude\s+install\s+2\.1\.260' >/dev/null \
  || fail "plan_npm_global did not report install for missing claude (got: $out)"

# Probe: dolt
dolt_present_bin="$test_scratch/dolt_present"
mkdir -p "$dolt_present_bin"
cat > "$dolt_present_bin/dolt" <<'STUB'
#!/bin/sh
echo "dolt version 2.3.1"
STUB
chmod +x "$dolt_present_bin/dolt"

out=$(run_plan_fn "$dolt_present_bin" plan_dolt)
echo "$out" | grep -E 'dolt\s+present\s+2\.3\.1' >/dev/null \
  || fail "plan_dolt did not report present for dolt 2.3.1 (got: $out)"

dolt_old_bin="$test_scratch/dolt_old"
mkdir -p "$dolt_old_bin"
cat > "$dolt_old_bin/dolt" <<'STUB'
#!/bin/sh
echo "dolt version 1.0.0"
STUB
chmod +x "$dolt_old_bin/dolt"

out=$(run_plan_fn "$dolt_old_bin" plan_dolt)
echo "$out" | grep -E 'dolt\s+upgrade\s+1\.0\.0\s+→\s+2\.3\.1' >/dev/null \
  || fail "plan_dolt did not report upgrade for dolt 1.0.0 (got: $out)"

out=$(run_plan_fn "$empty_bin" plan_dolt)
echo "$out" | grep -E 'dolt\s+install\s+2\.3\.1' >/dev/null \
  || fail "plan_dolt did not report install for missing dolt (got: $out)"

# Probe: bd
bd_present_bin="$test_scratch/bd_present"
mkdir -p "$bd_present_bin"
cat > "$bd_present_bin/bd" <<'STUB'
#!/bin/sh
echo "bd version 1.2.2"
STUB
chmod +x "$bd_present_bin/bd"

out=$(run_plan_fn "$bd_present_bin" plan_bd)
echo "$out" | grep -E 'bd\s+present\s+1\.2\.2' >/dev/null \
  || fail "plan_bd did not report present for bd 1.2.2 (got: $out)"

bd_old_bin="$test_scratch/bd_old"
mkdir -p "$bd_old_bin"
cat > "$bd_old_bin/bd" <<'STUB'
#!/bin/sh
echo "bd version 0.9.0"
STUB
chmod +x "$bd_old_bin/bd"

out=$(run_plan_fn "$bd_old_bin" plan_bd)
echo "$out" | grep -E 'bd\s+upgrade\s+0\.9\.0\s+→\s+1\.2\.2' >/dev/null \
  || fail "plan_bd did not report upgrade for bd 0.9.0 (got: $out)"

out=$(run_plan_fn "$empty_bin" plan_bd)
echo "$out" | grep -E 'bd\s+install\s+1\.2\.2' >/dev/null \
  || fail "plan_bd did not report install for missing bd (got: $out)"

# Probe: system packages (git, tmux, gh)
git_present_bin="$test_scratch/git_present"
mkdir -p "$git_present_bin"
cat > "$git_present_bin/git" <<'STUB'
#!/bin/sh
echo "git version 2.39.5"
STUB
chmod +x "$git_present_bin/git"

out=$(run_plan_fn "$git_present_bin" plan_system_package git)
echo "$out" | grep -E 'git\s+present\s+2\.39\.5' >/dev/null \
  || fail "plan_system_package did not report present for git (got: $out)"

out=$(run_plan_fn "$empty_bin" plan_system_package git)
echo "$out" | grep -E 'git\s+install' >/dev/null \
  || fail "plan_system_package did not report install for missing git (got: $out)"

# Verify no install commands were invoked during any probe
[ ! -s "$install_log" ] || fail "install command was invoked during plan probes: $(cat "$install_log")"
printf 'plan_* probes for present/missing/out-of-range tools: ok\n'

# --- 3. print_plan block formatting -----------------------------------------
all_present_bin="$test_scratch/all_present"
mkdir -p "$all_present_bin"
cat > "$all_present_bin/node" <<'STUB'
#!/bin/sh
[ "$1" = "-p" ] && { echo 22; exit 0; }
echo "v22.14.0"
STUB
cat > "$all_present_bin/claude" <<'STUB'
#!/bin/sh
echo "2.1.260"
STUB
cat > "$all_present_bin/codex" <<'STUB'
#!/bin/sh
echo "0.148.0"
STUB
cat > "$all_present_bin/openspec" <<'STUB'
#!/bin/sh
echo "1.11.0"
STUB
cat > "$all_present_bin/pi" <<'STUB'
#!/bin/sh
echo "0.85.0"
STUB
cat > "$all_present_bin/dolt" <<'STUB'
#!/bin/sh
echo "dolt version 2.3.1"
STUB
cat > "$all_present_bin/bd" <<'STUB'
#!/bin/sh
echo "bd version 1.2.2"
STUB
cat > "$all_present_bin/git" <<'STUB'
#!/bin/sh
echo "git version 2.39.5"
STUB
cat > "$all_present_bin/tmux" <<'STUB'
#!/bin/sh
echo "tmux 3.3a"
STUB
cat > "$all_present_bin/gh" <<'STUB'
#!/bin/sh
echo "gh version 2.45.0"
STUB
chmod +x "$all_present_bin"/*

plan_out=$(run_plan_fn "$all_present_bin" print_plan "/target/repo" 0)
echo "$plan_out" | grep -q 'Plan for /target/repo (Nogging v2.2.0)' \
  || fail "print_plan missing header (got: $plan_out)"
echo "$plan_out" | grep -E 'node\s+present' >/dev/null || fail "print_plan missing node line"
echo "$plan_out" | grep -E 'claude\s+present' >/dev/null || fail "print_plan missing claude line"
echo "$plan_out" | grep -E 'codex\s+present' >/dev/null || fail "print_plan missing codex line"
echo "$plan_out" | grep -E 'openspec\s+present' >/dev/null || fail "print_plan missing openspec line"
echo "$plan_out" | grep -E 'dolt\s+present' >/dev/null || fail "print_plan missing dolt line"
echo "$plan_out" | grep -E 'bd\s+present' >/dev/null || fail "print_plan missing bd line"
echo "$plan_out" | grep -E 'git\s+present' >/dev/null || fail "print_plan missing git line"
echo "$plan_out" | grep -E 'tmux\s+present' >/dev/null || fail "print_plan missing tmux line"
echo "$plan_out" | grep -E 'gh\s+present' >/dev/null || fail "print_plan missing gh line"
echo "$plan_out" | grep -q 'pi' && fail "print_plan included pi when with_pi=0"

plan_with_pi=$(run_plan_fn "$all_present_bin" print_plan "/target/repo" 1)
echo "$plan_with_pi" | grep -E 'pi\s+present' >/dev/null || fail "print_plan missing pi when with_pi=1"

[ ! -s "$install_log" ] || fail "install command was invoked during print_plan: $(cat "$install_log")"
printf 'print_plan block formatting: ok\n'

# --- 4. doctor is invoked exactly once by run_nogging_init -------------------
doctor_scratch="$test_scratch/doctor_test"
mkdir -p "$doctor_scratch/repo/scripts"
doctor_calls_log="$doctor_scratch/doctor_calls.log"
: > "$doctor_calls_log"

cat > "$doctor_scratch/repo/scripts/nogg" <<STUB
#!/bin/sh
echo "nogg \$*" >> "$doctor_calls_log"
if [ "\$1" = "doctor" ]; then
  echo "OK  git present"
  echo "WARN  test warning message"
  echo "FAIL  test failure message"
  exit 1
fi
exit 0
STUB
chmod +x "$doctor_scratch/repo/scripts/nogg"

npx_stub_dir="$doctor_scratch/npx_bin"
mkdir -p "$npx_stub_dir"
cat > "$npx_stub_dir/npx" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$npx_stub_dir/npx"

set +e
init_run_out=$(PATH="$npx_stub_dir:$PATH" NOGGING_BOOTSTRAP_NO_MAIN=1 bash -c \
  '. "$1" && run_nogging_init "$2" 0 0 0' _ "$bootstrap" "$doctor_scratch/repo" 2>&1)
init_run_rc=$?
set -e

[ "$init_run_rc" -eq 1 ] || fail "run_nogging_init did not return doctor's exit status 1 (got: $init_run_rc)"
doctor_count=$(grep -c 'nogg doctor' "$doctor_calls_log" || true)
[ "$doctor_count" -eq 1 ] || fail "scripts/nogg doctor was not invoked exactly once (invoked $doctor_count times)"

# Check that FAIL and WARN were printed inline
echo "$init_run_out" | grep -q 'WARN  test warning message' \
  || fail "run_nogging_init output did not show WARN line"
echo "$init_run_out" | grep -q 'FAIL  test failure message' \
  || fail "run_nogging_init output did not show FAIL line"
# Check that OK lines were NOT printed inline (only FAIL/WARN)
if echo "$init_run_out" | grep -q 'OK  git present'; then
  fail "run_nogging_init output showed OK line inline"
fi
# Check that result line names the log file
echo "$init_run_out" | grep -q 'bootstrap-doctor.log' \
  || fail "run_nogging_init result line did not name bootstrap-doctor.log"
[ -f "$doctor_scratch/repo/.nogging/state/bootstrap-doctor.log" ] \
  || fail "bootstrap-doctor.log was not created"
grep -q 'OK  git present' "$doctor_scratch/repo/.nogging/state/bootstrap-doctor.log" \
  || fail "full doctor report was not saved to bootstrap-doctor.log"
printf 'doctor invoked exactly once by run_nogging_init: ok\n'

# --- 5. Summary text in non-interactive mode and logged-out hint ------------
auth_scratch="$test_scratch/auth_test"
mkdir -p "$auth_scratch/bin"
cat > "$auth_scratch/bin/gh" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$auth_scratch/bin/codex" <<'STUB'
#!/bin/sh
echo "Not logged in"
exit 1
STUB
chmod +x "$auth_scratch/bin"/*

fake_empty_home="$auth_scratch/empty_home"
mkdir -p "$fake_empty_home"

# When doctor_status is 0 (all OK):
summary_ok=$(PATH="$auth_scratch/bin:/bin:/usr/bin" HOME="$fake_empty_home" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 bash -c \
  '. "$1" && build_closing_summary /target/repo 0 0 0 0 "" 0' _ "$bootstrap")

echo "$summary_ok" | grep -q 'GitHub: not logged in — run gh auth login' \
  || fail "summary missing logged-out hint for gh"
echo "$summary_ok" | grep -q 'Claude Code: not logged in — run claude' \
  || fail "summary missing logged-out hint for claude"
echo "$summary_ok" | grep -q 'Codex: not logged in — run codex login' \
  || fail "summary missing logged-out hint for codex"
echo "$summary_ok" | grep -q 'Next: cd /target/repo; start your first plan with /plan or ./scripts/nogg worktree plan' \
  || fail "summary OK missing next steps with first plan"
echo "$summary_ok" | grep -q '(optional: systemctl --user enable --now nogging-sync.timer)' \
  || fail "summary missing optional sync timer hint"
if echo "$summary_ok" | grep -q 'doctor'; then
  fail "summary included doctor in next steps when doctor passed"
fi

# When doctor_status is non-zero (problem reported):
summary_problem=$(PATH="$auth_scratch/bin:/bin:/usr/bin" HOME="$fake_empty_home" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 bash -c \
  '. "$1" && build_closing_summary /target/repo 0 1 0 0 "" 1' _ "$bootstrap")

echo "$summary_problem" | grep -q 'Next: cd /target/repo && bd init && ./scripts/nogg doctor' \
  || fail "summary with doctor problem missing ./scripts/nogg doctor in next steps"
printf 'summary text in non-interactive mode with logged-out hints: ok\n'

# --- 6. No credential-shaped stub output reaches stdout ----------------------
leak_scratch="$test_scratch/leak_test"
mkdir -p "$leak_scratch/bin"
cat > "$leak_scratch/bin/gh" <<'STUB'
#!/bin/sh
echo "ghp_LEAKED_TOKEN_SECRET_9876543210"
exit 0
STUB
cat > "$leak_scratch/bin/codex" <<'STUB'
#!/bin/sh
echo "Logged in with token sk-proj-LEAKED_OPENAI_KEY_ABCDEF123456"
exit 0
STUB
chmod +x "$leak_scratch/bin"/*

fake_creds_home="$leak_scratch/home"
mkdir -p "$fake_creds_home/.claude"
echo '{"token": "bearer_secret_leaked_claude_token_555"}' > "$fake_creds_home/.claude/.credentials.json"

combined_out=$(PATH="$leak_scratch/bin:/bin:/usr/bin" HOME="$fake_creds_home" \
  NOGGING_BOOTSTRAP_NO_MAIN=1 bash -c \
  '. "$1" && build_closing_summary /target/repo 0 0 0 0 "" 0' _ "$bootstrap" 2>&1)

if echo "$combined_out" | grep -E '(ghp_|sk-proj-|bearer_secret)'; then
  fail "credential-shaped stub output leaked to stdout/stderr: $combined_out"
fi
printf 'no credential-shaped stub output reaches stdout: ok\n'

rm -rf "$gate_scratch" "$test_scratch"
trap - EXIT
printf 'all bootstrap-summary checks passed: ok\n'
