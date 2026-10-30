#!/usr/bin/env bash
# Installer next steps and readiness verdict (bin/lib/nextsteps.js): a numbered
# next-steps block after init, update and remove; a verdict with deduplicated
# gaps, a fix line each and no internal commands; and an installer `doctor` that
# prints the unchanged report once, then the verdict, and exits with doctor's
# status. No network, no real bd/Dolt, no tmux server, no real systemctl.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
cli="$root/bin/cli.js"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - skipped (node not installed)"
  echo "all installer next-steps checks passed"
  exit 0
fi

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stub() { # <dir> <name> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$3" >"$1/$2"
  chmod +x "$1/$2"
}

new_repo() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
}

# A bd that is installed but has no database, and a dolt that is present.
bin="$work/bin"; mkdir -p "$bin"
stub "$bin" bd 'case "${1:-}" in
  --version) echo "bd version 1.2.2 (stub)" ;;
  *) echo "Error: no beads database found" >&2; exit 1 ;;
esac'
stub "$bin" dolt 'echo "dolt version 2.3.1"'

run() { # <repo> <args...>; stdout+stderr to $out, status to $status
  local repo="$1"; shift
  status=0
  out=$(cd "$repo" && PATH="$bin:$PATH" NOGG_PREFLIGHT_TIMEOUT_MS=500 node "$cli" "$@" 2>&1) || status=$?
}

lineno() { grep -n -- "$1" <<<"$out" | head -1 | cut -d: -f1; }

# --- init: the tracker is the only gap --------------------------------------
repo="$work/init/repo"; new_repo "$repo"
run "$repo" init --no-beads --no-hooks
verdict='Nogging is installed but not ready: uninitialized tracker (run `bd init`)'
check "init: exits 0" test "$status" -eq 0
check "init: the tracker is the only gap in the verdict" grep -Fxq "$verdict" <<<"$out"
check "init: the verdict prefix appears once" \
  test "$(grep -Ec 'Nogging is (ready|installed but not ready)' <<<"$out")" -eq 1
check "init: no internal bd list command text" bash -c '! grep -Fq "bd list" <<<"$1"' _ "$out"
check "init: the gap is followed by an indented fix line" \
  grep -Fxq '  fix: run `bd init` in this repository' <<<"$out"
check "init: the fix line follows the verdict directly" \
  test "$(lineno 'fix: run')" -eq "$(( $(lineno 'Nogging is installed') + 1 ))"

# --- init: the numbered block, required before optional ---------------------
check "init: a Next steps block is present" grep -Fxq 'Next steps' <<<"$out"
check "init: items are numbered from 1" grep -Eq '^  1\. ' <<<"$out"
check "init: gaps come first" grep -Eq '^  1\. Resolve each gap above' <<<"$out"
check "init: doctor is the second item" grep -Eq '^  2\. Check the installation: `\./scripts/nogg doctor`' <<<"$out"
check "init: the first plan names /plan and worktree plan" \
  grep -Eq '^  3\. Start your first plan: `/plan` in Claude Code, or `\./scripts/nogg worktree plan <planning-id> <description>`' <<<"$out"
check "init: the first plan links the Quick Guide at the package tag" \
  grep -Fq "README.md#quick-guide" <<<"$out"
check "init: the sync timer item names the rendered unit and is optional" \
  grep -Eq '^  4\. Enable the sync timer: `systemctl --user enable --now "\$PWD/systemd/nogg-sync-repo\.timer"` \(optional\)$' <<<"$out"
check "init: the orchestrator item adds linger and is optional" \
  grep -Eq '^  5\. Enable the always-on Orchestration Agent: .*loginctl enable-linger .* \(optional\)$' <<<"$out"
check "init: the loop timer item names the rendered unit and is optional" \
  grep -Eq '^  6\. Enable the loop scheduler timer: `systemctl --user link "\$PWD/systemd/nogg-loops-repo\.service" && systemctl --user enable --now "\$PWD/systemd/nogg-loops-repo\.timer"` \(optional\)$' <<<"$out"
check "init: required items come before optional ones" \
  test "$(lineno 'Start your first plan')" -lt "$(lineno 'Enable the sync timer')"
check "init: only optional items carry the marker" \
  test "$(grep -c '(optional)$' <<<"$out")" -eq 3
check "init: nothing suggests plan-begin" bash -c '! grep -Fq "plan-begin" <<<"$1"' _ "$out"

# --- init --no-systemd drops the unit items ---------------------------------
nosd="$work/nosd/repo"; new_repo "$nosd"
run "$nosd" init --no-beads --no-hooks --no-systemd
check "--no-systemd: still lists the required items" grep -Eq '^  3\. Start your first plan' <<<"$out"
check "--no-systemd: no sync timer item" bash -c '! grep -Fq "sync timer" <<<"$1"' _ "$out"
check "--no-systemd: no orchestrator item" bash -c '! grep -Fq "Orchestration Agent" <<<"$1"' _ "$out"
check "--no-systemd: no loop timer item" bash -c '! grep -Fq "loop scheduler" <<<"$1"' _ "$out"

# --- init --dry-run prints no verdict and no steps --------------------------
dry="$work/dry/repo"; new_repo "$dry"
run "$dry" init --no-beads --dry-run
check "dry run: no verdict" bash -c '! grep -Eq "Nogging is (ready|installed but not ready)" <<<"$1"' _ "$out"
check "dry run: no next steps" bash -c '! grep -Fq "Next steps" <<<"$1"' _ "$out"

# --- update: a unit already enabled is not offered again --------------------
stub "$bin" systemctl 'case "$*" in
  "--user is-enabled "*.timer) echo enabled ;;
  "--user is-enabled "*) echo disabled; exit 1 ;;
  *) exit 1 ;;
esac'
run "$repo" update --no-beads --no-hooks
check "update: exits 0" test "$status" -eq 0
check "update: doctor is a step" grep -Eq '^  [0-9]\. Check the installation: `\./scripts/nogg doctor`' <<<"$out"
check "update: no timer hint when the timer is enabled" bash -c '! grep -Fq "sync timer" <<<"$1"' _ "$out"
check "update: no loop hint when its timer is enabled" bash -c '! grep -Fq "loop scheduler" <<<"$1"' _ "$out"
check "update: the disabled orchestrator is offered, without the qualifier" \
  grep -Eq '^  [0-9]\. Enable the always-on Orchestration Agent: ' <<<"$out"
check "update: the verdict is unchanged" grep -Fxq "$verdict" <<<"$out"

# --- update: an unavailable probe shows the hint with a qualifier -----------
stub "$bin" systemctl 'exit 1'
run "$repo" update --no-beads --no-hooks
check "update, probe unavailable: the timer hint is qualified" \
  grep -Eq '^  [0-9]\. Enable the sync timer if not already enabled: ' <<<"$out"
check "update, probe unavailable: the loop hint is qualified" \
  grep -Eq '^  [0-9]\. Enable the loop scheduler timer if not already enabled: ' <<<"$out"

# --- update: a preserved file is counted as the first step ------------------
printf '# my edit\n' >>"$repo/.codex/rules/nogging.rules"
run "$repo" update --no-beads --no-hooks
check "update after a local edit: the first step reviews the .nogging-new file" \
  grep -Eq '^  1\. Review each \.nogging-new file \(1\)' <<<"$out"

# --- remove: the disable steps name the rendered units ----------------------
run "$repo" remove
check "remove: exits 0" test "$status" -eq 0
check "remove: the sync timer is disabled by name" \
  grep -Eq '^  1\. Disable nogg-sync-repo\.timer before the checkout is moved or deleted: `systemctl --user disable --now nogg-sync-repo\.timer`' <<<"$out"
check "remove: the orchestrator service is disabled by name" \
  grep -Eq '^  2\. Disable nogg-orchestrator-repo\.service .*`systemctl --user disable --now nogg-orchestrator-repo\.service`' <<<"$out"
check "remove: the loop timer is disabled by name" \
  grep -Eq '^  3\. Disable nogg-loops-repo\.timer before the checkout is moved or deleted: `systemctl --user disable --now nogg-loops-repo\.timer nogg-loops-repo\.service`' <<<"$out"
check "remove: shared entries are left for review" grep -Eq '^  4\. Review the shared \.gitignore entries and the Git hooks' <<<"$out"
check "remove: the last step commits the removal" grep -Eq '^  5\. Commit the removal\.' <<<"$out"
run "$work/nosd/repo" remove
check "remove, no units rendered: no disable step" bash -c '! grep -Fq "disable --now" <<<"$1"' _ "$out"

# --- the installer's doctor -------------------------------------------------
doc="$work/doctor/repo"; new_repo "$doc"
mkdir -p "$doc/scripts" "$doc/.beads"
stub "$doc/scripts" nogg 'echo "doctor-report-line"; echo "OK  git"; echo "FAIL  dolt"; exit 3'
run "$doc" doctor
check "doctor: exits with the stub doctor's status" test "$status" -eq 3
check "doctor: the report is printed once, unchanged" test "$(grep -c '^doctor-report-line$' <<<"$out")" -eq 1
check "doctor: the verdict follows, naming the missing tool" \
  grep -Fxq 'Nogging is installed but not ready: dolt not found' <<<"$out"
check "doctor: the report comes before the verdict" \
  test "$(lineno 'doctor-report-line')" -lt "$(lineno 'Nogging is installed')"
check "doctor: the missing tool has a fix line" grep -Eq '^  fix: install dolt — ' <<<"$out"
check "doctor: ends with the init next steps 1-3" grep -Eq '^  3\. Start your first plan' <<<"$out"
check "doctor: no unit items" bash -c '! grep -Fq "(optional)" <<<"$1"' _ "$out"

stub "$doc/scripts" nogg 'echo "doctor-report-line"; echo "OK  git"; exit 0'
run "$doc" doctor
ready='Nogging is ready — start your first plan with /plan or ./scripts/nogg worktree plan <planning-id> <description>.'
check "doctor, ready: exits 0" test "$status" -eq 0
check "doctor, ready: prints the ready line" grep -Fxq "$ready" <<<"$out"
check "doctor, ready: the line matches release-smoke-test's grep" grep -q "Nogging is ready" <<<"$out"
check "doctor, ready: the line matches acceptance.sh's verdict pattern" \
  bash -c "grep -E 'Nogging is (ready|installed but not ready)' <<<\"\$1\" | tail -1 | grep -q 'Nogging is ready'" _ "$out"
check "doctor, ready: no gap step" bash -c '! grep -Fq "Resolve each gap" <<<"$1"' _ "$out"
check "doctor, ready: no fix line" bash -c '! grep -Eq "^  fix:" <<<"$1"' _ "$out"

stub "$doc/scripts" nogg 'echo "FAIL  bd list --status open --limit 0 --json: Error: no beads database found"; echo "FAIL  Planning lock is stale; remove it by hand"; exit 1'
run "$doc" doctor
check "doctor, internal FAIL text: the tracker gap is folded" \
  grep -Fq 'not ready: uninitialized tracker (run `bd init`); Planning lock is stale' <<<"$out"
check "doctor, internal FAIL text: no command line in the verdict" \
  bash -c '! grep -E "^Nogging is" <<<"$1" | grep -Fq "bd list"' _ "$out"

if [ "$fail" -ne 0 ]; then
  echo "installer next-steps checks failed" >&2
  exit 1
fi
echo "all installer next-steps checks passed"
