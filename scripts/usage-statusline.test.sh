#!/usr/bin/env bash
# Regression checks for Claude statusline cache installation, composition,
# doctor freshness hints, and orchestrator retry guidance (TASK-GSU-005).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
  printf '[{"id":"%s","title":"stub","labels":[]}]\n' "${2:-}"
  exit 0
fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
echo "stub bd: refusing $*" >&2; exit 1
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$work/bin/dolt" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux" "$work/bin/dolt"
export PATH="$work/bin:$PATH"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

# Python unit checks for statusline wrapper generation, composition, freshness notes, and retry guidance
python3 - "$here" <<'PY' && ok "Python unit tests: wrapper generation, composition, freshness notes, and retry guidance" || { echo "FAIL - python unit checks"; fail=1; }
import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import nogg_usage as u

# 1. Orchestrator retry guidance
# Denied gate with both windows limiting
gate_denied = {
    'decision': 'denied',
    'retry_after': '2026-10-17T12:00:00Z',
    'windows': [
        {'bucket': 'short', 'fits': False, 'resets_at': '2026-10-11T17:00:00Z'},
        {'bucket': 'weekly', 'fits': False, 'resets_at': '2026-10-17T12:00:00Z'}
    ]
}
guidance = u.orchestrator_retry_guidance(gate_denied)
assert guidance['model_switching_allowed'] is False, guidance
assert guidance['retry_after'] == '2026-10-17T12:00:00Z'
assert 'short' in guidance['limiting_windows'] and 'weekly' in guidance['limiting_windows']
assert 'without model switching' in u.describe_denial(gate_denied)

# Admitted gate has no guidance
assert u.orchestrator_retry_guidance({'decision': 'admitted'}) is None

# 2. Freshness notes
with tempfile.TemporaryDirectory() as td:
    tpath = Path(td)
    cache_path = tpath / 'claude.json'
    codex_dir = tpath / 'codex/sessions'
    codex_dir.mkdir(parents=True)
    os.environ['XDG_CACHE_HOME'] = str(tpath / 'cache')
    os.environ['CODEX_HOME'] = str(tpath / 'codex')

    # Missing sources
    notes = u.quota_freshness_notes({'stale_seconds': 600})
    assert any('install-statusline' in n for n in notes), notes
    assert any('missing usage source' in n for n in notes), notes

    # Fresh Claude cache
    now = dt.datetime.now(dt.timezone.utc)
    target_cache = tpath / 'cache/nogging/usage/claude.json'
    target_cache.parent.mkdir(parents=True)
    reset = int(now.timestamp()) + 3600
    target_cache.write_text(json.dumps({
        'schema_version': 1,
        'observed_at': now.isoformat().replace('+00:00', 'Z'),
        'rate_limits': {
            'five_hour': {'used_percentage': 20, 'resets_at': reset},
            'seven_day': {'used_percentage': 40, 'resets_at': reset + 86400}
        }
    }))
    notes = u.quota_freshness_notes({'stale_seconds': 600}, now=now)
    assert any('claude' in n and 'fresh' in n for n in notes), notes

    # Stale Claude cache
    stale_time = now + dt.timedelta(seconds=601)
    notes = u.quota_freshness_notes({'stale_seconds': 600}, now=stale_time)
    assert any('claude' in n and 'stale' in n for n in notes), notes
PY

# Setup test repository and environment
setup_test_env() {
  local num="$1"
  local base="$work/env$num"
  mkdir -p "$base/repo/.nogging/state" "$base/repo/scripts/hooks" "$base/repo/openspec" "$base/repo/.agents"
  cp "$repo_root/scripts/nogg" "$repo_root/scripts/nogg_usage.py" "$base/repo/scripts/"
  cp -r "$repo_root/scripts/lib" "$base/repo/scripts/"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$base/repo/.nogging/"
  cp "$repo_root/templates/model-selection.json" "$base/repo/.nogging/model-selection.json"
  git init -q -b develop "$base/repo"
  git -C "$base/repo" -c user.name=Test -c user.email=test@example.org commit -q --allow-empty -m init
  cat >"$base/repo/.nogging/config.json" <<'JSON'
{
  "beads_command": "bd",
  "planning_lock_ttl_seconds": 60,
  "usage_gate": {
    "enabled": true,
    "cap_percent": 92,
    "estimate_percent": 5,
    "stale_seconds": 600,
    "on_unknown": "warn"
  }
}
JSON
  echo "$base"
}

# --- Test 1: Fresh install with no prior settings.json ---
env1=$(setup_test_env 1)
export HOME="$env1/home"
export XDG_CACHE_HOME="$env1/cache"
export XDG_DATA_HOME="$env1/data"
export CLAUDE_CONFIG_DIR="$env1/claude_config"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$CLAUDE_CONFIG_DIR"

"$env1/repo/scripts/nogg" usage install-statusline >"$out" 2>&1 || { bad "install-statusline failed on clean setup"; }
grep -qF "installed statusline capture at" "$out" && ok "fresh install creates statusline wrapper" || bad "fresh install output"

# Check settings.json created and correct
wrapper_path="$XDG_DATA_HOME/nogging/claude-statusline"
[[ -x "$wrapper_path" ]] && ok "wrapper script is executable" || bad "wrapper script not executable"

python3 - "$CLAUDE_CONFIG_DIR/settings.json" "$wrapper_path" <<'PY' && ok "settings.json points to wrapper" || bad "settings.json statusLine"
import json, sys
data = json.load(open(sys.argv[1]))
assert data['statusLine']['type'] == 'command'
assert data['statusLine']['command'] == sys.argv[2]
PY

# Execute wrapper with mock Claude statusline payload on stdin
now_epoch=$(date +%s)
reset_5h=$((now_epoch + 3600))
reset_7d=$((now_epoch + 86400))
mock_payload=$(cat <<JSON
{
  "model": "claude-3-5-sonnet-20241022",
  "rate_limits": {
    "five_hour": {
      "used_percentage": 25.5,
      "resets_at": $reset_5h
    },
    "seven_day": {
      "used_percentage": 50.0,
      "resets_at": $reset_7d
    }
  },
  "secret_transcript": "SHOULD_NOT_LEAK"
}
JSON
)

echo "$mock_payload" | "$wrapper_path"

cache_file="$XDG_CACHE_HOME/nogging/usage/claude.json"
[[ -f "$cache_file" ]] && ok "cache file created by wrapper" || bad "cache file not created"

# Verify permissions: cache dir 0700, cache file 0600
dir_mode=$(stat -c "%a" "$(dirname "$cache_file")")
file_mode=$(stat -c "%a" "$cache_file")
[[ "$dir_mode" == "700" ]] && ok "cache directory permissions are 0700" || bad "cache dir mode $dir_mode != 700"
[[ "$file_mode" == "600" ]] && ok "cache file permissions are 0600" || bad "cache file mode $file_mode != 600"

# Verify cache schema and content
python3 - "$cache_file" <<'PY' && ok "cache content has schema v1 and no secret leakage" || bad "cache content"
import json, sys
data = json.load(open(sys.argv[1]))
assert data['schema_version'] == 1
assert 'observed_at' in data and data['observed_at'].endswith('Z')
assert data['rate_limits']['five_hour']['used_percentage'] == 25.5
assert data['rate_limits']['seven_day']['used_percentage'] == 50.0
assert 'secret_transcript' not in data
assert 'SHOULD_NOT_LEAK' not in json.dumps(data)
PY

# Verify nogg usage --agent claude --json reads the cache and reports known status
"$env1/repo/scripts/nogg" usage --agent claude --json >"$out" 2>&1
python3 - "$out" <<'PY' && ok "nogg usage reports known status from statusline cache" || bad "nogg usage reading cache"
import json, sys
data = json.load(open(sys.argv[1]))
assert data['status'] == 'known'
assert data['windows'][0]['used_percent'] == 25.5
assert data['windows'][1]['used_percent'] == 50.0
assert data['gate']['fits'] is True
PY

# --- Test 2: Composing with existing user statusline & preserving settings ---
env2=$(setup_test_env 2)
export HOME="$env2/home"
export XDG_CACHE_HOME="$env2/cache"
export XDG_DATA_HOME="$env2/data"
export CLAUDE_CONFIG_DIR="$env2/claude_config"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$CLAUDE_CONFIG_DIR"

custom_tool="$env2/custom-statusline.sh"
cat >"$custom_tool" <<'SH'
#!/usr/bin/env bash
echo "CUSTOM_STATUSLINE_RENDERED"
SH
chmod +x "$custom_tool"

cat >"$CLAUDE_CONFIG_DIR/settings.json" <<JSON
{
  "model": "claude-3-5-sonnet",
  "userSetting": "custom_preserved_value",
  "hooks": {
    "PreToolUse": [{"type": "command", "command": "echo test"}]
  },
  "statusLine": {
    "type": "command",
    "command": "$custom_tool"
  }
}
JSON

"$env2/repo/scripts/nogg" usage install-statusline >"$out" 2>&1 || { bad "install-statusline failed on composition"; }
grep -qF "composed with existing command" "$out" && ok "install-statusline composed existing command" || bad "composition output"

# Verify all unrelated settings preserved
python3 - "$CLAUDE_CONFIG_DIR/settings.json" "$custom_tool" <<'PY' && ok "unrelated settings and hooks preserved" || bad "settings preservation"
import json, sys
data = json.load(open(sys.argv[1]))
assert data['model'] == 'claude-3-5-sonnet'
assert data['userSetting'] == 'custom_preserved_value'
assert data['hooks']['PreToolUse'] == [{"type": "command", "command": "echo test"}]
assert data['statusLine']['type'] == 'command'
assert 'claude-statusline' in data['statusLine']['command']
PY

# Run the composed wrapper and check that both cache is populated AND upstream stdout is emitted
composed_wrapper="$XDG_DATA_HOME/nogging/claude-statusline"
wrapper_out=$(echo "$mock_payload" | "$composed_wrapper")
[[ "$wrapper_out" == "CUSTOM_STATUSLINE_RENDERED" ]] && ok "composed wrapper emitted upstream statusline output" || bad "composed wrapper output: $wrapper_out"

# --- Test 3: Idempotent re-run ---
"$env2/repo/scripts/nogg" usage install-statusline >"$out" 2>&1
grep -qF "already installed" "$out" && ok "install-statusline is idempotent on re-run" || bad "idempotent re-run output"

# --- Test 4: Refusal on conflicting / unsupported statusline configurations ---
env4=$(setup_test_env 4)
export CLAUDE_CONFIG_DIR="$env4/claude_config"
mkdir -p "$CLAUDE_CONFIG_DIR"

# 4a: Unsupported statusLine type
cat >"$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{
  "statusLine": {
    "type": "unsupported_inline_widget",
    "widget": "custom"
  }
}
JSON
if "$env4/repo/scripts/nogg" usage install-statusline >"$out" 2>&1; then
  bad "should refuse unsupported statusLine type"
else
  grep -qF "unsupported statusLine type" "$out" && grep -qF "Manual instructions" "$out" \
    && ok "refused unsupported statusLine type with manual instructions" || bad "unsupported type error message"
fi

# 4b: Empty command in statusLine
cat >"$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": ""
  }
}
JSON
if "$env4/repo/scripts/nogg" usage install-statusline >"$out" 2>&1; then
  bad "should refuse empty command"
else
  grep -qF "missing non-empty 'command'" "$out" && grep -qF "Manual instructions" "$out" \
    && ok "refused empty statusLine command with manual instructions" || bad "empty command error message"
fi

# 4c: Malformed settings.json
echo "NOT_VALID_JSON{}" >"$CLAUDE_CONFIG_DIR/settings.json"
if "$env4/repo/scripts/nogg" usage install-statusline >"$out" 2>&1; then
  bad "should refuse malformed JSON"
else
  grep -qF "malformed or unreadable" "$out" && grep -qF "Manual instructions" "$out" \
    && ok "refused malformed settings.json with manual instructions" || bad "malformed JSON error message"
fi

# --- Test 6: --dry-run previews and writes nothing; real install backs up and records ---
env6=$(setup_test_env 6)
export HOME="$env6/home"
export XDG_CACHE_HOME="$env6/cache"
export XDG_DATA_HOME="$env6/data"
export CLAUDE_CONFIG_DIR="$env6/claude_config"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CLAUDE_CONFIG_DIR"
cat >"$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{
  "model": "opus",
  "statusLine": {
    "command": "echo upstream-line",
    "padding": 2,
    "type": "command"
  }
}
JSON
snapshot() { (cd "$env6" && find home cache claude_config data -print0 2>/dev/null | sort -z | xargs -0 -r stat -c '%n %F %s %Y' ; find claude_config -type f -exec sha256sum {} +); }
before6=$(snapshot)
"$env6/repo/scripts/nogg" usage install-statusline --dry-run >"$out" 2>&1 || bad "dry-run failed"
after6=$(snapshot)
[[ "$before6" == "$after6" ]] && [[ ! -e "$XDG_DATA_HOME" ]] && ok "dry-run leaves the fixture tree byte-identical, no new directories" || bad "dry-run modified the tree"
grep -qF "would install statusline capture at $XDG_DATA_HOME/nogging/claude-statusline" "$out" \
  && grep -qF "would compose with: echo upstream-line" "$out" \
  && grep -qF -- "--- $CLAUDE_CONFIG_DIR/settings.json" "$out" \
  && grep -qF -- "+++ $CLAUDE_CONFIG_DIR/settings.json" "$out" \
  && grep -qF -- "+    \"command\": \"$XDG_DATA_HOME/nogging/claude-statusline\"" "$out" \
  && ok "dry-run prints wrapper, composed command and settings diff" || bad "dry-run output"
"$env6/repo/scripts/nogg" usage install-statusline --dry-run --json >"$out" 2>&1
python3 - "$out" <<'PY' && ok "dry-run --json shape" || bad "dry-run --json"
import json, sys
d = json.load(open(sys.argv[1]))
assert d['dry_run'] is True and d['status'] == 'installed' and d['composed_upstream'] == 'echo upstream-line'
assert '+++' in d['diff'] and 'backup_path' not in d
PY
"$env6/repo/scripts/nogg" usage --dry-run >"$out" 2>&1 && bad "--dry-run without an action should fail" \
  || { grep -qF "requires an action" "$out" && ok "--dry-run without an action is an argparse error"; } || bad "--dry-run w/o action message"

# dry-run against a missing settings file diffs against empty and creates nothing
env6b=$(setup_test_env 6b)
export CLAUDE_CONFIG_DIR="$env6b/claude_config" XDG_DATA_HOME="$env6b/data"
"$env6b/repo/scripts/nogg" usage install-statusline --dry-run >"$out" 2>&1
[[ ! -e "$CLAUDE_CONFIG_DIR" && ! -e "$XDG_DATA_HOME" ]] && grep -qF -- "+++ $CLAUDE_CONFIG_DIR/settings.json" "$out" \
  && ok "dry-run with no settings file creates no directory" || bad "dry-run with no settings file"

# real install: backup (byte for byte, 0600) and restore record
export CLAUDE_CONFIG_DIR="$env6/claude_config" XDG_DATA_HOME="$env6/data"
cp "$CLAUDE_CONFIG_DIR/settings.json" "$work/settings6.orig"
"$env6/repo/scripts/nogg" usage install-statusline >"$out" 2>&1 || bad "real install after dry-run failed"
cmp -s "$work/settings6.orig" "$CLAUDE_CONFIG_DIR/settings.json.nogging-install.bak" \
  && [[ "$(stat -c %a "$CLAUDE_CONFIG_DIR/settings.json.nogging-install.bak")" == "600" ]] \
  && ok "install backs up settings byte for byte with mode 0600" || bad "install backup"
record="$XDG_DATA_HOME/nogging/claude-statusline.restore.json"
python3 - "$record" "$CLAUDE_CONFIG_DIR/settings.json" <<'PY' && [[ "$(stat -c %a "$record")" == "600" ]] && ok "install writes a 0600 restore record" || bad "restore record"
import json, sys
r = json.load(open(sys.argv[1]))
assert r['schema_version'] == 1 and r['settings_path'] == sys.argv[2]
assert r['previous_statusline'] == {"command": "echo upstream-line", "padding": 2, "type": "command"}
assert r['installed_at'].endswith('Z')
PY
rm -f "$CLAUDE_CONFIG_DIR/settings.json.nogging-install.bak" "$record"
"$env6/repo/scripts/nogg" usage install-statusline >"$out" 2>&1
[[ ! -e "$CLAUDE_CONFIG_DIR/settings.json.nogging-install.bak" && ! -e "$record" ]] && grep -qF "already installed" "$out" \
  && ok "already-installed re-run writes neither backup nor record" || bad "idempotent path wrote files"
"$env6/repo/scripts/nogg" usage install-statusline --dry-run >"$out" 2>&1
grep -qF "already installed; nothing would change" "$out" && ok "dry-run on an installed state reports no change" || bad "dry-run already installed"

# --- Test 5: Doctor freshness hints ---
env5=$(setup_test_env 5)
export HOME="$env5/home"
export XDG_CACHE_HOME="$env5/cache"
export CODEX_HOME="$env5/codex"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CODEX_HOME"

# 5a: Missing cache hints
doctor_out=$("$env5/repo/scripts/nogg" doctor || true)
echo "$doctor_out" | grep -qF "NOTE  quota observation (claude): missing statusline cache — opt in with nogg usage install-statusline (installs a capture wrapper as the statusLine in ~/.claude/settings.json; --dry-run previews it) — see https://jome92.github.io/nogging/usage-limits/#claude-usage-is-unknown-by-default" \
  && ok "doctor advises missing Claude cache and install-statusline command" || bad "doctor missing Claude cache note"
echo "$doctor_out" | grep -qF "NOTE  quota observation (codex): missing usage source" \
  && ok "doctor advises missing Codex rollout source" || bad "doctor missing Codex note"

# 5b: Fresh Claude observation hint
claude_cache="$XDG_CACHE_HOME/nogging/usage/claude.json"
mkdir -p "$(dirname "$claude_cache")"
cat >"$claude_cache" <<JSON
{
  "schema_version": 1,
  "observed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "rate_limits": {
    "five_hour": {"used_percentage": 10.0, "resets_at": $((now_epoch + 3600))},
    "seven_day": {"used_percentage": 20.0, "resets_at": $((now_epoch + 86400))}
  }
}
JSON
doctor_out=$("$env5/repo/scripts/nogg" doctor || true)
echo "$doctor_out" | grep -qF "NOTE  quota observation (claude): fresh observation cache" \
  && ok "doctor reports fresh Claude cache" || bad "doctor fresh Claude cache note"

# 5c: Stale Claude observation hint (> 600s)
cat >"$claude_cache" <<JSON
{
  "schema_version": 1,
  "observed_at": "2026-01-01T00:00:00Z",
  "rate_limits": {
    "five_hour": {"used_percentage": 10.0, "resets_at": $((now_epoch + 3600))},
    "seven_day": {"used_percentage": 20.0, "resets_at": $((now_epoch + 86400))}
  }
}
JSON
doctor_out=$("$env5/repo/scripts/nogg" doctor || true)
echo "$doctor_out" | grep -qF "NOTE  quota observation (claude): observation is stale" \
  && ok "doctor reports stale Claude cache" || bad "doctor stale Claude cache note"

if [[ $fail -ne 0 ]]; then
  echo "Nogging: statusline regression tests failed" >&2
  exit 1
fi
echo "Nogging: statusline regression tests passed"
