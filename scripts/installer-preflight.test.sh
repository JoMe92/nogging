#!/usr/bin/env bash
# Installer preflight (bin/lib/preflight.js): advisory host check run first by
# init and update. Tools are PATH stubs in a temporary directory; no network, no
# bd/Dolt, no tmux server, no real systemctl.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
cli="$root/bin/cli.js"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - skipped (node not installed)"
  echo "all installer preflight checks passed"
  exit 0
fi
node_bin=$(command -v node)
real_git=$(command -v git)

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# stub <bin-dir> <name> <body...>: an executable that runs the given shell body.
stub() {
  local dir="$1" name="$2"; shift 2
  printf '#!/usr/bin/env bash\n%s\n' "$*" >"$dir/$name"
  chmod +x "$dir/$name"
}

# A PATH directory holding only what init needs plus version stubs for every
# preflight tool, so the host's own tools never leak into the result.
make_bin() { # <dir>
  local dir="$1" t
  mkdir -p "$dir"
  for t in bash env sleep cat dirname chmod mkdir; do
    ln -s "$(command -v "$t")" "$dir/$t"
  done
  stub "$dir" git "if [ \"\${1:-}\" = --version ]; then echo 'git version 2.40.0'; else exec '$real_git' \"\$@\"; fi"
  stub "$dir" python3 "echo 'Python 3.11.2'"
  stub "$dir" openspec "echo '1.13.2'"
  stub "$dir" bd "echo 'bd version 1.2.2 (abc)'"
  stub "$dir" dolt "echo 'dolt version 2.3.1'"
  stub "$dir" tmux "echo 'tmux 3.4'"
  stub "$dir" systemctl "exit 99"
  stub "$dir" claude "exit 99"
  stub "$dir" codex "exit 99"
}

new_repo() { # <dir>; every case uses the basename "repo" because it is written into files
  mkdir -p "$1"
  "$real_git" -C "$1" init -q
}

run() { # <repo> <bin-dir> <args...>; stdout+stderr to $out, status to $status
  local repo="$1" bin="$2"; shift 2
  status=0
  out=$(cd "$repo" && PATH="$bin" NOGG_PREFLIGHT_TIMEOUT_MS=500 "$node_bin" "$cli" "$@" 2>&1) || status=$?
}

manifest() { # <repo>: sorted per-file hashes; the repo path (rendered into units) is normalised
  local f
  (cd "$1" && find . -type f -not -path './.git/*' | sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sed "s|$1|@REPO@|g" "$f" | sha256sum | cut -d' ' -f1)" "$f"
  done)
}

# --- all tools present ------------------------------------------------------
ok_bin="$work/ok-bin"; make_bin "$ok_bin"
ok_repo="$work/ok/repo"; new_repo "$ok_repo"
run "$ok_repo" "$ok_bin" init --no-beads
check "all present: exits 0" test "$status" -eq 0
check "all present: one summary line" \
  grep -Eq '^Preflight: 7/7 required tools OK; optional: tmux, systemd, claude, codex$' <<<"$out"
check "all present: no problem lines" bash -c "! grep -Eq 'MISSING|TOO OLD|UNKNOWN|WARN' <<<\"\$1\"" _ "$out"
manifest "$ok_repo" >"$work/ok.manifest"

# --- openspec missing -------------------------------------------------------
miss_bin="$work/miss-bin"; make_bin "$miss_bin"; rm "$miss_bin/openspec"
miss_repo="$work/miss/repo"; new_repo "$miss_repo"
run "$miss_repo" "$miss_bin" init --no-beads
check "openspec missing: exits 0" test "$status" -eq 0
check "openspec missing: named with the npm hint" \
  grep -Fq 'MISSING OpenSpec CLI (need >= 1.11) — fix: npm install -g @fission-ai/openspec@1.11' <<<"$out"
check "openspec missing: install writes the same tree" \
  diff -q "$work/ok.manifest" <(manifest "$miss_repo")

# --- git too old ------------------------------------------------------------
old_bin="$work/old-bin"; make_bin "$old_bin"
stub "$old_bin" git "if [ \"\${1:-}\" = --version ]; then echo 'git version 2.25.0'; else exec '$real_git' \"\$@\"; fi"
old_repo="$work/old/repo"; new_repo "$old_repo"
run "$old_repo" "$old_bin" init --no-beads
check "git too old: exits 0" test "$status" -eq 0
check "git too old: found version and minimum" \
  grep -Fq 'TOO OLD Git (2.25.0 < 2.30)' <<<"$out"
check "git too old: bootstrap hint names the package version" \
  grep -Fq "raw.githubusercontent.com/JoMe92/nogging/v$(node -p "require('$root/package.json').version")/scripts/bootstrap" <<<"$out"
check "git too old: install writes the same tree" \
  diff -q "$work/ok.manifest" <(manifest "$old_repo")

# --- a probe that hangs -----------------------------------------------------
slow_bin="$work/slow-bin"; make_bin "$slow_bin"
stub "$slow_bin" dolt "sleep 30"
slow_repo="$work/slow/repo"; new_repo "$slow_repo"
start=$SECONDS
run "$slow_repo" "$slow_bin" init --no-beads
check "hanging probe: returns well within the sleep" test $((SECONDS - start)) -lt 20
check "hanging probe: exits 0" test "$status" -eq 0
check "hanging probe: reported UNKNOWN" grep -Fq 'UNKNOWN Dolt (no answer within 500 ms' <<<"$out"
check "hanging probe: install writes the same tree" \
  diff -q "$work/ok.manifest" <(manifest "$slow_repo")

# --- no agent CLI -----------------------------------------------------------
noagent_bin="$work/noagent-bin"; make_bin "$noagent_bin"; rm "$noagent_bin/claude" "$noagent_bin/codex"
noagent_repo="$work/noagent/repo"; new_repo "$noagent_repo"
run "$noagent_repo" "$noagent_bin" init --no-beads
check "no agent CLI: exits 0" test "$status" -eq 0
check "no agent CLI: WARN with the compatibility link" \
  grep -Eq 'WARN no agent CLI found .*docs/compatibility.md' <<<"$out"
check "no agent CLI: required summary still passes" grep -Fq 'Preflight: 7/7 required tools OK' <<<"$out"
check "no agent CLI: install writes the same tree" \
  diff -q "$work/ok.manifest" <(manifest "$noagent_repo")

# --- --no-systemd skips the systemd row -------------------------------------
nosd_repo="$work/nosd/repo"; new_repo "$nosd_repo"
rm "$ok_bin/systemctl"
run "$nosd_repo" "$ok_bin" init --no-beads --no-systemd
check "--no-systemd: no systemd warning" bash -c "! grep -Fq 'systemd user services' <<<\"\$1\"" _ "$out"

# --- --dry-run prints the preflight and writes nothing ----------------------
dry_repo="$work/dry/repo"; new_repo "$dry_repo"
run "$dry_repo" "$miss_bin" init --no-beads --dry-run
check "dry-run: exits 0" test "$status" -eq 0
check "dry-run: prints the preflight" grep -Fq 'MISSING OpenSpec CLI' <<<"$out"
check "dry-run: writes nothing" test -z "$(manifest "$dry_repo")"

# --- update runs the preflight, remove and version do not -------------------
run "$miss_repo" "$miss_bin" update --no-beads
check "update: runs the preflight" grep -Fq 'MISSING OpenSpec CLI' <<<"$out"
check "update: exits 0" test "$status" -eq 0
run "$miss_repo" "$miss_bin" remove --dry-run
check "remove: no preflight" bash -c "! grep -Fq Preflight <<<\"\$1\"" _ "$out"
run "$miss_repo" "$miss_bin" version
check "version: no preflight" bash -c "! grep -Fq Preflight <<<\"\$1\"" _ "$out"

if [ "$fail" -ne 0 ]; then
  echo "installer preflight checks failed" >&2
  exit 1
fi
echo "all installer preflight checks passed"
