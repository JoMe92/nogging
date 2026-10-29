#!/usr/bin/env bash
# Agent routing file: loader, validator, `route check`, and the doctor/validate
# FAIL and NOTEs (change configurable-agent-routing, TASK-RTG-001).
#
# Offline: fixture repositories with stub PATHs, no Dolt, no bd server, no
# real agent CLI. The pure loader/validator is unit-tested in
# scripts/lib/agent_routing_test.py; this suite covers the CLI surface.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
out="$work/out"
fail=0

check() { # check <description> <expected-substring>
  if grep -qF -- "$2" "$out"; then echo "ok   - $1"; else
    echo "FAIL - $1 (missing: $2)"; cat "$out"; fail=1; fi
}
refute() { # refute <description> <substring-that-must-be-absent>
  if grep -qF -- "$2" "$out"; then echo "FAIL - $1 (present: $2)"; cat "$out"; fail=1; else
    echo "ok   - $1"; fi
}

# A fixture repository with the shipped config keys and a curated stub PATH:
# doctor's host probes see git/python3/dolt/tmux and the `bd` stub, but no
# agent CLI (claude/codex/pi/agy) and no herdr, whatever the host has.
make_repo() { # make_repo <dir>
  local dir="$1" tool
  git init -q -b main "$dir"
  git -C "$dir" config user.email fixture@example.invalid
  git -C "$dir" config user.name Fixture
  cp "$repo_root/.nogging/config.json" "$work/host-config.json"
  copy_host_config "$work/host-config.json" "$dir/.nogging/config.json" tmux
  mkdir -p "$dir/.nogging/state" "$dir/bin"
  cp "$repo_root/templates/model-selection.json" "$dir/.nogging/model-selection.json"
  cat >"$dir/bin/bd" <<'STUB'
#!/usr/bin/env bash
echo '[]'
STUB
  chmod +x "$dir/bin/bd"
  for tool in git python3 dolt tmux sh bash env uname readlink dirname; do
    src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$dir/bin/$tool" || true
  done
}
# A PATH with only the fixture bin: no agent CLI, no herdr.
run_nogg() { # run_nogg <root> <nogg args...>
  # The usage gate must never read the operator's live quota (scripts/test
  # does the same): an empty CODEX_HOME/XDG_CACHE_HOME means unknown usage.
  env -i PATH="$1/bin" HOME="$HOME" NOGGING_ROOT="$1" \
    CODEX_HOME="$work/usage/codex" XDG_CACHE_HOME="$work/usage/cache" \
    AGY_NOGG_USAGE_PROBE=0 NOGG_LAUNCH_SETTLE_SECONDS=0.25 \
    "$here/nogg" "${@:2}"
}

mkdir -p "$work/usage/codex" "$work/usage/cache"
VALID='{"schema_version": 1, "roles": {"lead": [
  {"agent": "pi", "backend": "herdr"},
  {"agent": "codex", "backend": "herdr", "on_unknown": "deny",
   "models": {"complex": {"model": "gpt-6-luna", "effort": "medium"}},
   "allow": [{"model": "gpt-6-luna"},
             {"model": "gpt-6.1-sol", "efforts": ["low"],
              "note": "extremely hard tasks only"}]},
  {"agent": "claude", "backend": "herdr"}],
 "planning": [{"agent": "claude"}]}}'
INVALID='{"schema_version": 1, "roles": {"lead": [{"agent": "pi", "wat": 1}]}}'

# --- unit tests of the pure module run first --------------------------------
# The unit test file ships with the package, so this runs in a consumer too.
if python3 "$here/lib/agent_routing_test.py" >"$out" 2>&1; then
  echo "ok   - scripts/lib/agent_routing_test.py"
else
  echo "FAIL - scripts/lib/agent_routing_test.py"; cat "$out"; fail=1
fi

# --- shipped surface: template key, docs, manifest, package files -----------
# These checks read the source-checkout layout. The installed consumer copy
# (installed-diagnostics runs this suite there) has no bin/, templates/ or
# docs/configuration.md, so each check is skipped when its file is absent.
if [[ -f "$repo_root/templates/nogging-config.json" ]]; then
  grep -q '"agent_routing_file": ".nogging/agent-routing.json"' \
    "$repo_root/templates/nogging-config.json" \
    && echo "ok   - template carries the agent_routing_file default" \
    || { echo "FAIL - template lacks agent_routing_file"; fail=1; }
else
  echo "ok   - template check skipped (installed consumer copy)"
fi

if [[ -f "$repo_root/docs/configuration.md" ]]; then
  grep -q 'agent_routing_file' "$repo_root/docs/configuration.md" \
    && echo "ok   - configuration.md documents agent_routing_file" \
    || { echo "FAIL - configuration.md lacks agent_routing_file"; fail=1; }
else
  echo "ok   - configuration.md check skipped (installed consumer copy)"
fi

if [[ -f "$repo_root/bin/lib/manifest.js" ]]; then
  grep -q "scripts/lib/agent_routing.py" "$repo_root/bin/lib/manifest.js" \
    && echo "ok   - manifest.js ships scripts/lib/agent_routing.py" \
    || { echo "FAIL - manifest.js lacks agent_routing.py"; fail=1; }
  grep -q "scripts/lib/agent_routing_test.py" "$repo_root/bin/lib/manifest.js" \
    && echo "ok   - manifest.js ships scripts/lib/agent_routing_test.py" \
    || { echo "FAIL - manifest.js lacks agent_routing_test.py"; fail=1; }
  grep -q "scripts/lib/agent_routing.py" "$repo_root/package.json" \
    && echo "ok   - package files list ships scripts/lib/agent_routing.py" \
    || { echo "FAIL - package.json lacks agent_routing.py"; fail=1; }
  grep -q "scripts/lib/agent_routing_test.py" "$repo_root/package.json" \
    && echo "ok   - package files list ships scripts/lib/agent_routing_test.py" \
    || { echo "FAIL - package.json lacks agent_routing_test.py"; fail=1; }
  node -e "require('$repo_root/bin/lib/manifest.js')" \
    && echo "ok   - manifest.js still parses" \
    || { echo "FAIL - manifest.js does not parse"; fail=1; }
else
  echo "ok   - manifest checks skipped (installed consumer copy)"
fi

# --- route check: absent, valid, invalid ------------------------------------
repo="$work/repo-absent"; make_repo "$repo"
cd "$repo"
run_nogg "$repo" route check >"$out" 2>&1
check "absent file: named as absent" "agent routing $repo/.nogging/agent-routing.json: absent (no routing)"
run_nogg "$repo" route check >/dev/null 2>&1 \
  && echo "ok   - absent file: route check exits 0" \
  || { echo "FAIL - absent file: route check exited non-zero"; fail=1; }

printf '%s\n' "$VALID" > .nogging/agent-routing.json
run_nogg "$repo" route check >"$out" 2>&1
check "valid file: reported valid with counts" "is valid (2 roles, 4 entries)"
run_nogg "$repo" route check >/dev/null 2>&1 \
  && echo "ok   - valid file: route check exits 0" \
  || { echo "FAIL - valid file: route check exited non-zero"; fail=1; }

# Bare `route`: every role's entries with effective per-tier model and effort
run_nogg "$repo" route >"$out" 2>&1
check "bare route: lead role listed" "lead:"
check "bare route: entry numbering and backend" "#1 pi/herdr"
check "bare route: codex complex entry selection" "complex: model=gpt-6-luna (route) effort=medium (route)"
check "bare route: pi falls back to the table/default" "#3 claude/herdr"

printf '%s\n' "$INVALID" > .nogging/agent-routing.json
run_nogg "$repo" route check >"$out" 2>&1 || rc=$?
rc=${rc:-0}
[[ $rc -ne 0 ]] && echo "ok   - invalid file: route check exits non-zero" \
  || { echo "FAIL - invalid file: route check exited 0"; fail=1; }
check "invalid file: error names the file" "agent-routing.json"
check "invalid file: error names the JSON path" "roles.lead[0]"
check "invalid file: error names the rule" "unknown key 'wat'"

# --- doctor / validate: FAIL for an invalid file -----------------------------
run_nogg "$repo" doctor >"$out" 2>&1 || true
check "doctor: invalid file is a FAIL" "FAIL"
check "doctor: FAIL names the routing file" "agent routing $repo/.nogging/agent-routing.json is invalid"
run_nogg "$repo" validate >"$out" 2>&1 || true
check "validate: invalid file is a FAIL" "agent routing $repo/.nogging/agent-routing.json is invalid"

# --- doctor NOTEs on a valid file, no agent CLI on PATH ----------------------
printf '%s\n' "$VALID" > .nogging/agent-routing.json
run_nogg "$repo" doctor >"$out" 2>&1 || true
check "doctor: missing CLI is a NOTE, not a FAIL" "agent routing $repo/.nogging/agent-routing.json: roles.lead[2] agent codex is not on PATH"
refute "doctor: missing CLI does not fail doctor" "FAIL  agent routing"

# herdr entry while herdr is missing on the stub PATH.
run_nogg "$repo" doctor >"$out" 2>&1 || true
check "doctor: herdr missing is a NOTE" "targets herdr but herdr (herdr) is not on PATH"

# --- doctor NOTE: table model outside the entry's allow list ------------------
cat > .nogging/agent-routing.json <<'JSON'
{"schema_version": 1, "roles": {"lead": [
  {"agent": "codex",
   "allow": [{"model": "gpt-6.1-sol", "efforts": ["low"],
              "note": "extremely hard tasks only"}]}]}}
JSON
run_nogg "$repo" doctor >"$out" 2>&1 || true
check "doctor: table model outside allow is a NOTE" "table model"
check "doctor: NOTE names the reason code" "model-not-allowed"

# --- linked-worktree resolution ----------------------------------------------
repo="$work/repo-wt"; make_repo "$repo"
cd "$repo"
python3 - "$repo" <<'PY'
import json, pathlib, sys
cfg = pathlib.Path(sys.argv[1], ".nogging/config.json")
config = json.loads(cfg.read_text())
config["agent_routing_file"] = ".nogging/state/agent-routing.json"
cfg.write_text(json.dumps(config, indent=2) + "\n")
PY
printf '%s\n' "$VALID" > .nogging/state/agent-routing.json
git add -A >/dev/null 2>&1 || true
git commit -qm fixture >/dev/null 2>&1 || true
git worktree add -q "$work/linked" -b linked >/dev/null 2>&1
cp .nogging/config.json "$work/linked/.nogging/config.json"
mkdir -p "$work/linked/bin" && cp bin/bd "$work/linked/bin/bd"
cd "$work/linked"
# No routing file inside the linked worktree's own tree; the main checkout's
# file must be the one read.
run_nogg "$work/linked" route check >"$out" 2>&1
check "linked worktree: main checkout's file is read" \
  "agent routing $repo/.nogging/state/agent-routing.json is valid (2 roles, 4 entries)"
refute "linked worktree: worktree-local path not resolved" "$work/linked/.nogging/state/agent-routing.json is valid"

cd "$repo_root"
if [[ $fail -ne 0 ]]; then echo "Nogging: agent-routing.test.sh FAILED" >&2; exit 1; fi
echo "Nogging: agent-routing.test.sh passed"
