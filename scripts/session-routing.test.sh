#!/usr/bin/env bash
# fixture-backend-pin: allow - routing entries select their own backend
# Routed and unrouted `session launch` (TASK-RTG-003).
#
# Covered, through the real CLI with PATH-injected bd, tmux and agent stubs and
# the herdr fixture (no real session or runtime is ever started):
#   - a routed launch takes the first entry that passes, in check order, and each
#     skip reason (operator-skip, tier, binary-missing, authority,
#     backend-unavailable, model-not-allowed, usage-denied, usage-unknown) moves
#     to the next entry; only the chosen entry's reservation reaches the ledger;
#   - every entry skipped exits 75 naming the earliest retry when one was
#     usage-denied and 1 otherwise, listing each entry, with no side effect;
#   - a defect (routing file, tier_overrides, table, usage_gate, profile, Bead,
#     dependency, flags) refuses instead of skipping, with no side effect;
#   - a routed Pi entry keeps the Pi launch path: its profile provider reaches
#     usage admission and pi_extensions loads, or refuses with no side effect;
#   - unrouted launches behave as without routing, carry no routing key and list
#     as before;
#   - entries supply model and effort with `route` provenance, Pi records a tier;
#   - the record, the printed routing= line and `session list` show the decision,
#     and launch mutates no Bead.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
unset NOGG_OPENSPEC_FENCED NOGG_SESSION_NAME  # hermetic: a supervised caller's state stays out
# A short path: the herdr socket lives under the root and has a length limit.
work=$(mktemp -d /tmp/rt.XXXXXX)
out="$work/out"
cleanup() {
  HERDR_STUB_DIR="$work/herdr" "$repo_root/scripts/fixtures/herdr/bin/herdr" --session rt server stop \
    >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BD_STUB_LOG:?}"
case "${1:-} ${2:-}" in
  show\ *)
    [[ -n "${BD_STUB_MISSING:-}" ]] && { echo '[]'; exit 0; }
    printf '[{"id":"%s","title":"stub"}]\n' "${2:-}" ;;
  dep\ list)
    if [[ -n "${BD_STUB_BLOCKED:-}" ]]; then
      echo '[{"id":"SPEC-dep","status":"open","dependency_type":"blocks"}]'
    else echo '[]'; fi ;;
  *) echo "stub bd: refusing $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"
if [[ "$cmd" == new-session ]]; then a=("$@"); for i in "${!a[@]}"; do [[ "${a[i]}" == -s ]] && : >"$d/live-${a[i+1]}"; done; fi
case "$cmd" in
  has-session) [[ -e "$d/live-${2:-}" ]] || exit 1 ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
stub_agent_binaries "$work/agents"
base_path="$work/bin:$(dirname "$(command -v python3)"):/usr/bin:/bin"
export HOME="$work/home" NOGG_LAUNCH_SETTLE_SECONDS=0 BD_STUB_LOG="$work/bd.log"
mkdir -p "$HOME/.gemini/antigravity-cli"
printf '{"toolPermission":"request-review"}\n' >"$HOME/.gemini/antigravity-cli/settings.json"
export PATH="$work/agents:$base_path"
# only_agents <name...>: every other agent binary leaves PATH.
only_agents() {
  rm -rf "$work/some"; mkdir -p "$work/some"
  local name; for name in "$@"; do cp "$work/agents/$name" "$work/some/"; done
  export PATH="$work/some:$base_path"
}

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

n=0
# new_root [routing json]: fresh checkout, usage state, and an optional routing file.
new_root() {
  n=$((n + 1)); root="$work/r$n"
  mkdir -p "$root/.nogging/state" "$root/scripts/hooks" "$root/openspec" "$root/.pi/extensions" "$root/.agents"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
     "$repo_root/scripts/openspec-sandbox" "$repo_root/scripts/nogg" "$root/scripts/"
  cp "$repo_root/scripts/hooks/agy-guard" "$root/scripts/hooks/"
  cp "$repo_root/templates/antigravity/hooks.json" "$root/.agents/hooks.json"
  cp "$repo_root/.pi/extensions/nogging-guard.ts" "$root/.pi/extensions/"
  git init -q "$root"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$root/.nogging/"
  cp "$repo_root/templates/model-selection.json" "$root/.nogging/model-selection.json"
  copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
  patch_config 'cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None); cfg.pop("tier_overrides", None); cfg["usage_gate"] = {"on_unknown": "warn"}'
  export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/t$n" XDG_CACHE_HOME="$work/c$n" CODEX_HOME="$work/x$n"
  mkdir -p "$TMUX_STUB_DIR" "$XDG_CACHE_HOME" "$CODEX_HOME"
  : >"$BD_STUB_LOG"
  [[ $# -eq 0 ]] || printf '%s\n' "$1" >"$root/.nogging/agent-routing.json"
}
patch_config() {
  python3 - "$root/.nogging/config.json" "$1" <<'PY'
import json, sys
path, patch = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
exec(patch)
json.dump(cfg, open(path, "w"), indent=2)
PY
}
# codex_usage / claude_usage <short percent>: a fresh observation of one account.
codex_usage() {
  python3 - "$CODEX_HOME" "$1" <<'PY'
import datetime as dt, json, sys
from pathlib import Path
home, short = Path(sys.argv[1]), float(sys.argv[2])
now = dt.datetime.now(dt.timezone.utc)
base = int(now.timestamp())
path = home / "sessions" / now.strftime("%Y/%m/%d") / "rollout-gate.jsonl"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({"type": "event_msg", "timestamp": now.isoformat(), "payload": {
    "type": "token_count", "rate_limits": {"limit_id": "codex-primary",
        "primary": {"used_percent": short, "window_minutes": 300, "resets_at": base + 3600},
        "secondary": {"used_percent": 1, "window_minutes": 10080, "resets_at": base + 86400}}}}) + "\n")
PY
}
claude_usage() {
  python3 - "$XDG_CACHE_HOME" "$1" <<'PY'
import datetime as dt, json, sys
from pathlib import Path
cache, short = Path(sys.argv[1]) / "nogging/usage/claude.json", float(sys.argv[2])
now = dt.datetime.now(dt.timezone.utc)
base = int(now.timestamp())
cache.parent.mkdir(parents=True, exist_ok=True)
cache.write_text(json.dumps({"schema_version": 1, "observed_at": now.isoformat(), "rate_limits": {
    "five_hour": {"used_percentage": short, "resets_at": base + 1800},
    "seven_day": {"used_percentage": 1, "resets_at": base + 86400}}}))
PY
}

launch() { "$nogg" session launch --role lead --bead SPEC-route --cwd "$root" "$@" >"$out" 2>&1; }
argv() { grep -F "new-session" "$TMUX_STUB_DIR/calls.log" | tail -1; }
has() { argv | grep -qF -- "$2" && ok "$1" || { bad "$1 (missing: $2)"; argv; }; }
lacks() { argv | grep -qF -- "$2" && { bad "$1 (present: $2)"; argv; } || ok "$1"; }
said() { grep -qF -- "$2" "$out" && ok "$1" || bad "$1 (missing: $2)"; }
# field <dotted.path>: one value of the newest record, as JSON ("missing" when absent).
field() {
  python3 - "$root" "$1" <<'PY'
import glob, json, sys
paths = [p for p in glob.glob(sys.argv[1] + "/.nogging/state/sessions/*.json")
         if not p.endswith(".settings.json")]
value = json.load(open(sorted(paths)[-1]))
for part in sys.argv[2].split("."):
    if isinstance(value, list) and int(part) < len(value):
        value = value[int(part)]
    elif isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print("missing"); sys.exit()
print(json.dumps(value))
PY
}
expect() { local got; got=$(field "$2"); [[ "$got" == "$3" ]] && ok "$1" || { echo "  $2: $got" >"$out"; bad "$1"; }; }
launched() { local label="$1"; shift; if launch "$@"; then ok "$label: launched"; else bad "$label: launch errored"; fi; }
# reserved: the ledger's reservation tokens, one per line.
reserved() {
  python3 - "$XDG_CACHE_HOME/nogging/usage/reservations/ledger.json" <<'PY'
import json, sys
try:
    entries = json.load(open(sys.argv[1]))
except FileNotFoundError:
    entries = {}
print("\n".join(sorted(entries)))
PY
}
nothing_started() {
  local label="$1"
  [[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null || true)" ]] \
    && ok "$label: no record, settings or log" || bad "$label: session state left behind"
  grep -qF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null \
    && bad "$label: tmux new-session reached" || ok "$label: no tmux session"
  [[ -z "$(reserved)" ]] && ok "$label: ledger empty" || bad "$label: reservation left in the ledger"
}
# refused <label> <exit code> <expected text> <args...>
refused() {
  local label="$1" code="$2" expect_text="$3" rc=0; shift 3
  launch "$@" || rc=$?
  [[ "$rc" == "$code" ]] && ok "$label: exit $code" || bad "$label: exit $rc, wanted $code"
  said "$label: names '$expect_text'" "$expect_text"
  nothing_started "$label"
}

THREE='{"schema_version": 1, "roles": {"lead": [
  {"agent": "pi", "backend": "tmux"}, {"agent": "codex", "backend": "tmux"}, {"agent": "claude", "backend": "tmux"}]}}'
TWO='{"schema_version": 1, "roles": {"lead": [
  {"agent": "codex", "backend": "tmux"}, {"agent": "claude", "backend": "tmux"}]}}'
SOL='{"schema_version": 1, "roles": {"lead": [{"agent": "codex", "backend": "tmux",
  "models": {"complex": {"model": "gpt-6-luna", "effort": "medium"}},
  "allow": [{"model": "gpt-6-luna"}, {"model": "gpt-6.1-sol", "efforts": ["low"]}]}]}}'
PI_ONLY='{"schema_version": 1, "roles": {"lead": [{"agent": "pi", "backend": "tmux"}]}}'

# --- routed launch: reasons in check order -----------------------------------
only_agents codex claude
new_root "$THREE"
launched binary-missing --full-access
has "binary-missing: entry 2 is Codex" "--agent codex"
expect "binary-missing: agent" agent '"codex"'
expect "binary-missing: mode" routing.mode '"routed"'
expect "binary-missing: role" routing.role '"lead"'
expect "binary-missing: file" routing.file "\"$root/.nogging/agent-routing.json\""
expect "binary-missing: chosen index" routing.chosen.index 2
expect "binary-missing: chosen agent" routing.chosen.agent '"codex"'
expect "binary-missing: chosen backend" routing.chosen.backend '"tmux"'
expect "binary-missing: skip index" routing.skipped.0.index 1
expect "binary-missing: skip agent" routing.skipped.0.agent '"pi"'
expect "binary-missing: skip backend" routing.skipped.0.backend '"tmux"'
expect "binary-missing: skip reason" routing.skipped.0.reason '"binary-missing"'
expect "binary-missing: skip detail" routing.skipped.0.detail '"pi is not on PATH"'
expect "binary-missing: skip_agents" routing.skip_agents '[]'
said "binary-missing: routing line" "routing=lead#2 codex/tmux; skipped #1 pi/tmux: binary-missing (pi is not on PATH)"
"$nogg" session list >"$out" 2>&1
said "binary-missing: list shows the route" "route=#2 skipped=#1:binary-missing"
grep -E '^(implement|write|update|create|close|add|remember)' "$BD_STUB_LOG" >"$out" \
  && bad "binary-missing: launch mutated a Bead" || ok "binary-missing: no Beads mutation"
export PATH="$work/agents:$base_path"

new_root "$TWO"
launched operator-skip --skip-agent codex --full-access
expect "operator-skip: Claude chosen" routing.chosen.index 2
expect "operator-skip: reason" routing.skipped.0.reason '"operator-skip"'
expect "operator-skip: recorded" routing.skip_agents '["codex"]'

new_root "$TWO"
refused all-skipped 1 "#2 claude/tmux: operator-skip" --skip-agent codex --skip-agent claude --full-access
said "all-skipped: lists the first entry" "#1 codex/tmux: operator-skip"

new_root '{"schema_version": 1, "roles": {"lead": [
  {"agent": "codex", "backend": "tmux", "tiers": ["complex"]}, {"agent": "claude", "backend": "tmux"}]}}'
launched tier-outside --tier routine --full-access
expect "tier-outside: reason" routing.skipped.0.reason '"tier"'
expect "tier-outside: detail" routing.skipped.0.detail '"tier routine is outside complex"'
new_root '{"schema_version": 1, "roles": {"lead": [
  {"agent": "codex", "backend": "tmux", "tiers": ["complex"]}, {"agent": "claude", "backend": "tmux"}]}}'
launched tier-absent --full-access
expect "tier-absent: detail" routing.skipped.0.detail '"no tier given"'

new_root '{"schema_version": 1, "roles": {"planning": [{"agent": "codex"}, {"agent": "antigravity"}]}}'
rc=0; "$nogg" session launch --role planning --planning-id rt --description routed >"$out" 2>&1 || rc=$?
[[ "$rc" == 1 ]] && ok "authority: exit 1" || bad "authority: exit $rc"
said "authority: names the reason" "#1 codex/tmux: authority"
nothing_started authority

new_root '{"schema_version": 1, "roles": {"lead": [{"agent": "claude", "backend": "herdr"}, {"agent": "codex", "backend": "tmux"}]}}'
patch_config 'cfg["session_herdr_command"] = "/missing/herdr"'
launched backend-unavailable --full-access
expect "backend-unavailable: reason" routing.skipped.0.reason '"backend-unavailable"'
expect "backend-unavailable: skip backend" routing.skipped.0.backend '"herdr"'
said "backend-unavailable: detail is the preflight's" "herdr backend binary is missing"
new_root '{"schema_version": 1, "roles": {"lead": [{"agent": "codex", "backend": "herdr"}]}}'
patch_config 'cfg["session_herdr_command"] = "/missing/herdr"'
launched explicit-backend --backend tmux --full-access
expect "explicit-backend: replaces the entry backend" backend '"tmux"'
expect "explicit-backend: recorded" routing.chosen.backend '"tmux"'

new_root '{"schema_version": 1, "roles": {"lead": [
  {"agent": "codex", "backend": "tmux", "allow": [{"model": "gpt-not-in-the-table"}]},
  {"agent": "claude", "backend": "tmux"}]}}'
launched model-not-allowed --tier complex --full-access
expect "model-not-allowed: reason" routing.skipped.0.reason '"model-not-allowed"'
expect "model-not-allowed: Claude chosen" agent '"claude"'
new_root '{"schema_version": 1, "roles": {"lead": [
  {"agent": "codex", "backend": "tmux", "allow": [{"model": "gpt-6-luna"}]},
  {"agent": "claude", "backend": "tmux"}]}}'
launched model-unknown --full-access
expect "model-unknown: the runtime default cannot be verified" routing.skipped.0.reason '"model-not-allowed"'

# --- the spec's own list: Pi, Codex and Claude on herdr, with Pi not installed ---
new_root '{"schema_version": 1, "roles": {"lead": [
  {"agent": "pi", "backend": "herdr"}, {"agent": "codex", "backend": "herdr"}, {"agent": "claude", "backend": "herdr"}]}}'
mkdir -p "$work/herdr" "$work/herdr-bin" "$root/.nogging/locks"
: >"$work/herdr/real_process"
: >"$root/.nogging/locks/openspec.readonly"
cp "$repo_root/scripts/session-pty-recorder" "$root/scripts/"
cat >"$root/scripts/openspec-sandbox" <<SHIM
#!/bin/sh
if [ "\${1:-}" = --contract ]; then exec "$repo_root/scripts/openspec-sandbox" --contract; fi
NOGG_OPENSPEC_FENCED=1 exec "\$@"
SHIM
printf '#!/bin/sh\nexport HERDR_STUB_DIR=%q\nexec %q "$@"\n' "$work/herdr" \
  "$repo_root/scripts/fixtures/herdr/bin/herdr" >"$work/herdr-bin/herdr"
printf '#!/bin/sh\nexec sleep 60\n' >"$work/herdr-bin/codex"
cp "$work/agents/claude" "$work/herdr-bin/"
chmod +x "$work/herdr-bin/herdr" "$work/herdr-bin/codex"
patch_config "cfg.update(session_herdr_command='$work/herdr-bin/herdr', session_herdr_session='rt')"
export PATH="$work/herdr-bin:$base_path" HERDR_STUB_DIR="$work/herdr"
"$work/herdr-bin/herdr" --session rt server stop >/dev/null 2>&1 || true
codex_usage 10
launched herdr --full-access
expect "herdr: Codex starts" agent '"codex"'
expect "herdr: on herdr" backend '"herdr"'
expect "herdr: entry 1 skipped" routing.skipped.0.reason '"binary-missing"'
said "herdr: routing line" "routing=lead#2 codex/herdr; skipped #1 pi/herdr: binary-missing"
"$nogg" session stop "$(field name | tr -d '"')" >/dev/null 2>&1 || true
export PATH="$work/agents:$base_path"

# --- quota -------------------------------------------------------------------
new_root "$TWO"
codex_usage 99; claude_usage 10
launched quota --tier complex --full-access
expect "quota: Claude starts" agent '"claude"'
expect "quota: reason" routing.skipped.0.reason '"usage-denied"'
expect "quota: tier stays" selection_tier '"complex"'
has "quota: Claude's complex model" "--model $(python3 -c 'import json;print(json.load(open("'"$repo_root"'/templates/model-selection.json"))["agents"]["claude"]["complex"]["model"])')"
expect "quota: admitted" usage_gate.decision '"admitted"'
[[ "\"$(reserved)\"" == "$(field usage_gate.reservation_id)" ]] \
  && ok "quota: only Claude's reservation is written" || { reserved >"$out"; bad "quota: ledger"; }

new_root '{"schema_version": 1, "roles": {"lead": [
  {"agent": "codex", "backend": "tmux", "on_unknown": "deny"}, {"agent": "claude", "backend": "tmux"}]}}'
claude_usage 10
launched usage-unknown --full-access
expect "usage-unknown: reason" routing.skipped.0.reason '"usage-unknown"'
expect "usage-unknown: next entry" agent '"claude"'

new_root '{"schema_version": 1, "roles": {"lead": [{"agent": "codex", "backend": "tmux", "on_unknown": "warn"}]}}'
patch_config 'cfg["usage_gate"]["on_unknown"] = "deny"'
launched entry-warns --full-access
expect "entry-warns: the entry's on_unknown wins" usage_gate.decision '"unknown-admitted"'

new_root "$TWO"
patch_config 'cfg["usage_gate"]["on_unknown"] = "deny"'
refused gate-on-unknown 1 "#1 codex/tmux: usage-unknown" --full-access
said "gate-on-unknown: no wait without a denial" "#2 claude/tmux: usage-unknown"

new_root "$TWO"
codex_usage 99; claude_usage 99
refused quota-all 75 "#1 codex/tmux: usage-denied" --full-access
said "quota-all: lists the second entry" "#2 claude/tmux: usage-denied"
retry=$(python3 -c '
import datetime as dt, json, pathlib, sys
row = json.load(open(sys.argv[1]))
print(dt.datetime.fromtimestamp(row["rate_limits"]["five_hour"]["resets_at"], dt.timezone.utc).strftime("%Y-%m-%dT%H:%M"))
' "$XDG_CACHE_HOME/nogging/usage/claude.json")
said "quota-all: names the earliest retry" "retry after $retry"

new_root '{"schema_version": 1, "roles": {"lead": [
  {"agent": "codex", "backend": "tmux"}, {"agent": "claude", "backend": "tmux", "tiers": ["complex"]}]}}'
codex_usage 99
refused quota-and-tier 75 "#2 claude/tmux: tier" --tier routine --full-access

# A disabled gate, an excluded role and the bypass never skip an entry.
new_root "$TWO"
codex_usage 99
patch_config 'cfg["usage_gate"]["enabled"] = False'
launched gate-disabled --full-access
expect "gate-disabled: first entry" routing.chosen.index 1
expect "gate-disabled: recorded" usage_gate.decision '"disabled"'
new_root "$TWO"
codex_usage 99
patch_config 'cfg["usage_gate"]["exclude_roles"] = ["lead"]'
launched gate-excluded --full-access
expect "gate-excluded: recorded" usage_gate.decision '"excluded"'
new_root "$TWO"
codex_usage 99
launched gate-ignored --ignore-usage-gate --full-access
expect "gate-ignored: first entry" routing.chosen.index 1
expect "gate-ignored: recorded" usage_gate.decision '"ignored"'
[[ -z "$(reserved)" ]] && ok "gate-ignored: nothing reserved" || bad "gate-ignored: reservation written"

# --- defects refuse ----------------------------------------------------------
new_root "$TWO"
printf 'not a toml spec\n' >"$root/.nogging/launch-profiles/trusted.codex.toml"
refused profile-defect 1 "trusted.codex.toml" --full-access
new_root '{"schema_version": 1, "roles": {"lead": [{"agent": "nobody"}]}}'
refused routing-defect 1 "roles.lead[0].agent" --full-access
new_root "$TWO"
refused unknown-tier 1 "is not a model-selection tier" --tier bogus --full-access
new_root "$PI_ONLY"
patch_config 'cfg["tier_overrides"] = {"routine": {"codex": {"effort": "bogus"}}}'
refused overrides-defect 1 "tier_overrides" --tier routine --full-access
new_root "$PI_ONLY"
printf '{}\n' >"$root/.nogging/model-selection.json"
refused table-defect 1 "launch refused" --tier routine --full-access
new_root "$PI_ONLY"
patch_config 'cfg["usage_gate"] = {"cap_percent": "high"}'
refused gate-defect 1 "invalid usage_gate" --full-access
new_root "$THREE"
BD_STUB_MISSING=1 refused bead-defect 1 "does not exist or cannot be read" --full-access
new_root "$THREE"
BD_STUB_BLOCKED=1 refused dependency-defect 1 "unmet dependency on SPEC-dep" --full-access
new_root "$THREE"
rc=0; "$nogg" session launch --role lead --full-access >"$out" 2>&1 || rc=$?
[[ "$rc" == 1 ]] && ok "no-bead: exit 1" || bad "no-bead: exit $rc"
said "no-bead: refused as a defect" "--bead is required"
nothing_started no-bead
new_root "$THREE"
mkdir -p "$work/brokengit"
printf '#!/bin/sh\nexit 1\n' >"$work/brokengit/git"; chmod +x "$work/brokengit/git"
PATH="$work/brokengit:$PATH" refused git-state 1 "canonical repository state" --full-access
new_root "$TWO"
refused complexity-defect 1 "disagrees with selection tier" --tier routine --complexity complex --full-access

new_root "$TWO"
refused model-needs-agent 1 "--model is refused on a routed launch" --model gpt-6-luna --full-access
said "model-needs-agent: remedy" "pass --agent"
new_root "$TWO"
refused effort-needs-agent 1 "--effort is refused on a routed launch" --effort low --full-access
new_root "$TWO"
refused resume-needs-agent 1 "--resume is refused on a routed launch" --resume 11111111-1111-1111-1111-111111111111 --full-access

# --- a routed Pi entry -------------------------------------------------------
new_root "$PI_ONLY"
printf 'provider = "anthropic"\n' >"$root/.nogging/launch-profiles/trusted.pi.toml"
PI_NOGG_USAGE_PROBE=0 launched pi-provider --full-access
expect "pi-provider: Pi chosen" agent '"pi"'
said "pi-provider: admission sees the profile provider" "no usage source for Pi provider anthropic"

new_root "$PI_ONLY"
patch_config 'cfg["pi_extensions"] = ["glm-usage"]'
mkdir -p "$root/.pi/nogging/extensions/glm-usage"
: >"$root/.pi/nogging/extensions/glm-usage/index.ts"
launched pi-extensions --full-access
expect "pi-extensions: recorded" pi_extensions '["glm-usage"]'
expect "pi-extensions: routing kept" routing.chosen.agent '"pi"'
said "pi-extensions: printed" "pi-extensions=glm-usage"

new_root "$PI_ONLY"
patch_config 'cfg["pi_extensions"] = ["glm-usage"]'
refused pi-extensions-missing 1 "pi_extensions names" --full-access

# --- unrouted ----------------------------------------------------------------
new_root
launched unrouted --agent codex --full-access
expect "unrouted: no routing key" routing missing
"$nogg" session list >"$out" 2>&1
! grep -qF "route=" "$out" && ok "unrouted: list as before" || bad "unrouted: list shows a route"
new_root '{"schema_version": 1, "roles": {"planning": [{"agent": "claude"}]}}'
launched other-role --full-access
expect "other-role: no list for the role" routing missing
new_root
refused unrouted-skip 1 "--skip-agent needs a routing list" --skip-agent codex --full-access
new_root '{"schema_version": 1, "roles": {"lead": [{"agent": "nobody"}]}}'
rc=0; "$nogg" session launch --role orchestrator --cwd "$root" >"$out" 2>&1 || rc=$?
! grep -qF "invalid agent routing file" "$out" && ok "orchestrator: never reads routing" \
  || bad "orchestrator: refused by routing"

new_root '{"schema_version": 1, "roles": {"lead": [{"agent": "codex", "backend": "tmux"}]}}'
patch_config 'cfg["session_agent"] = "claude"'
launched session-agent --full-access
expect "session-agent: the list replaces the default" agent '"codex"'
new_root '{"schema_version": 1, "roles": {"specialist": [{"agent": "codex", "backend": "tmux"}]}}'
"$nogg" session launch --role specialist:code-reviewer --bead SPEC-route --cwd "$root" --full-access >"$out" 2>&1 \
  && ok "specialist: launched" || bad "specialist: launch errored"
expect "specialist: list key" routing.role '"specialist"'

# --- selection and provenance ------------------------------------------------
new_root "$SOL"
patch_config 'cfg["tier_overrides"] = {"complex": {"codex": {"effort": "low"}}}'
launched entry-selection --tier complex --full-access
has "entry-selection: model" "--model gpt-6-luna"
has "entry-selection: effort" "--reasoning-effort medium"
expect "entry-selection: model source" model_source '"route"'
expect "entry-selection: effort source" reasoning_effort_source '"route"'
expect "entry-selection: tier" selection_tier '"complex"'
expect "entry-selection: tier effort" selection_tier_effort '"medium"'
expect "entry-selection: tier effort source" selection_tier_effort_source '"route"'
"$nogg" session list >"$out" 2>&1
said "entry-selection: list shows route effort" "effort=medium (route)"
said "entry-selection: list keeps the tier" "tier=complex route=#1"

new_root '{"schema_version": 1, "roles": {"lead": [{"agent": "codex", "backend": "tmux",
  "models": {"complex": {"effort": "medium"}}}]}}'
launched entry-effort --tier complex --full-access
expect "entry-effort: the table keeps the model" model_source '"launch"'
expect "entry-effort: the entry supplies the effort" reasoning_effort_source '"route"'

new_root '{"schema_version": 1, "roles": {"lead": [{"agent": "codex", "backend": "tmux"}]}}'
patch_config 'cfg["tier_overrides"] = {"complex": {"codex": {"effort": "low"}}}'
launched no-entry-selection --tier complex --full-access
expect "no-entry-selection: the override stays" selection_tier_effort_source '"project"'
expect "no-entry-selection: effort source" reasoning_effort_source '"project"'

new_root "$PI_ONLY"
launched pi-tier --tier standard --full-access
expect "pi-tier: agent" agent '"pi"'
expect "pi-tier: tier recorded" selection_tier '"standard"'
expect "pi-tier: null tier effort" selection_tier_effort null
expect "pi-tier: null source" selection_tier_effort_source null
expect "pi-tier: runtime default" model_source '"runtime-default"'
expect "pi-tier: no table lookup attributed" usage_attribution.0.selection_version null
exit "$fail"
