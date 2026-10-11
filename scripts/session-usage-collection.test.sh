#!/usr/bin/env bash
# Host usage collection through the real CLI (TASK-TUC-004), with PATH-injected
# tmux and bd stubs (no real session or runtime is ever started):
#   - `--complexity` disagreeing with `--tier` refuses before any session
#     record or tmux session exists; explicit, tier-derived and absent
#     complexity are snapshotted with source, vocabulary and table provenance,
#     plus task/change labels at launch;
#   - every launch records its own usage segment; agent argv and environment
#     carry no usage-store path, and the agent-invoked `session emit` hook
#     never touches the store (restricted authority);
#   - `session stop` durably spools exact-source usage (never failing when
#     usage state is unwritable); `session cleanup` imports it into the local
#     store, and refuses, naming a remedy, until evidence can be made durable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -f "$out"; rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
  printf '[{"id":"%s","title":"stub","labels":["openspec:change:demo-change","openspec:task:TASK-DEMO-001"]}]\n' "${2:-}"
  exit 0
fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
echo "stub bd: refusing $*" >&2; exit 1
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"
case "$cmd" in
  has-session) exit 1 ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
export PATH="$work/bin:$PATH"
export HOME="$work/home"
mkdir -p "$HOME"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

root="$work/repo"
mkdir -p "$root/.nogging/state" "$root/scripts/hooks" "$root/openspec"
cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" \
   "$repo_root/scripts/openspec-sandbox" "$repo_root/scripts/nogg" "$root/scripts/"
cp -r "$repo_root/scripts/lib" "$root/scripts/lib"
git init -q -b develop "$root"
git -C "$root" -c user.name=Test -c user.email=test@example.org commit -q --allow-empty -m init
cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$root/.nogging/"
cp "$repo_root/templates/model-selection.json" "$root/.nogging/model-selection.json"
python3 - "$repo_root/.nogging/config.json" "$root/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None)
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/tmux"
sessions="$root/.nogging/state/sessions"
usage="$root/.nogging/state/token-usage"

latest() { ls -t "$sessions"/*.json 2>/dev/null | grep -v '\.settings\.json$' | head -1; }
attr() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["usage_attribution"][0].get(sys.argv[2]))' "$(latest)" "$1"; }
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$(latest)" "$1"; }
launch() { "$nogg" session launch --role lead --bead SPEC-use --cwd "$root" --full-access "$@" >"$out" 2>&1; }
expect() { [[ "$2" == "$3" ]] && ok "$1" || { echo "  got: $2 want: $3" >"$out"; bad "$1"; }; }

# --- disagreement refuses before side effects ------------------------------
if launch --tier complex --complexity routine; then bad "tier/complexity disagreement should refuse"
else
  grep -qF -- "--complexity routine disagrees with selection tier complex" "$out" \
    && ok "disagreement refused naming both values" || bad "disagreement refusal text"
  [[ -z "$(ls -A "$sessions" 2>/dev/null || true)" ]] && ok "no session record" || bad "record left behind"
  ! grep -qF new-session "$TMUX_STUB_DIR/calls.log" 2>/dev/null && ok "no tmux session" || bad "tmux reached"
fi

# --- snapshots ---------------------------------------------------------------
launch --complexity routine && ok "explicit complexity launched" || bad "explicit complexity launch"
expect "explicit complexity recorded" "$(attr complexity)/$(attr complexity_source)/$(attr vocabulary_version)" "routine/launch/1"
expect "task and change snapshotted" "$(attr task_id)/$(attr change_id)/$(attr bead_id)" "TASK-DEMO-001/demo-change/SPEC-use"
expect "explicit complexity selects no tier" "$(field selection_tier)" "None"
"$nogg" session stop "$(field name)" >"$out" 2>&1 || bad "stop explicit"

launch --tier standard && ok "tier launched" || bad "tier launch"
table_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["table_version"])' "$root/.nogging/model-selection.json")
expect "tier complexity recorded" "$(attr complexity)/$(attr complexity_source)" "standard/selection_tier"
expect "selection table version recorded" "$(attr selection_version)" "$table_version"
[[ "$(attr selection_hash)" == sha256:* ]] && ok "selection table hash recorded" || bad "selection hash"
"$nogg" session stop "$(field name)" >"$out" 2>&1 || bad "stop tier"

launch && ok "plain launch" || bad "plain launch"
expect "absent complexity stays unknown" "$(attr complexity)/$(attr complexity_source)" "unknown/absent"
seg=$(field usage_segment_id)
[[ "$seg" =~ ^[0-9a-f-]{36}$ ]] && ok "launch records its own usage segment" || bad "usage segment id"
grep -F new-session "$TMUX_STUB_DIR/calls.log" | grep -qF token-usage \
  && bad "agent argv/environment names the usage store" || ok "agent argv and environment carry no usage-store path"

# --- agent-invoked hook never collects -------------------------------------
name=$(field name)
rm -rf "$usage"
NOGG_SESSION_NAME="$name" NOGG_SESSION_AGENT=claude "$nogg" session emit turn_end >"$out" 2>&1 \
  && ok "session emit ran" || bad "session emit"
[[ ! -e "$usage" ]] && ok "agent hook did not touch the usage store" || bad "agent hook created usage state"

# --- stop flushes exact-source usage ---------------------------------------
claude_id=$(field claude_session_id)
project="$HOME/.claude/projects/$(python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))' "$root")"
mkdir -p "$project"
started=$(field started_at)
python3 - "$project/$claude_id.jsonl" "$claude_id" "$started" <<'PY'
import datetime as dt, json, sys
ts = (dt.datetime.fromisoformat(sys.argv[3]) + dt.timedelta(seconds=1)).isoformat()
usage = {"input_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 7, "output_tokens": 11}
with open(sys.argv[1], "w") as fh:
    for _ in range(2):  # repeated streaming record for one message
        fh.write(json.dumps({"type": "assistant", "sessionId": sys.argv[2], "timestamp": ts,
                             "message": {"id": "msg_1", "role": "assistant", "model": "claude-test",
                                         "content": [{"type": "text", "text": "SECRET"}], "usage": usage}}) + "\n")
PY
"$nogg" session stop "$name" >"$out" 2>&1 && ok "stop succeeded" || bad "stop"
ls "$usage/collector/spool/"*.json >/dev/null 2>&1 && ok "stop durably spooled the evidence" || bad "stop spool"
! grep -rqF SECRET "$usage" && ok "no transcript text in usage state" || bad "transcript text leaked"
"$nogg" session cleanup "$name" >"$out" 2>&1 && ok "cleanup retired a flushed session" || bad "cleanup flushed"
if command -v dolt >/dev/null 2>&1; then
  q() { (cd "$usage/database" && dolt sql -r csv -q "$1" | tail -1 | tr -d '"'); }
  expect "cleanup imported the exact source once" \
    "$(q "SELECT COUNT(*), SUM(input_tokens), MAX(model), MAX(segment_id) FROM current_usage_events")" "1,112,claude-test,$seg"
  expect "start and observed exit recorded" \
    "$(q "SELECT GROUP_CONCAT(kind ORDER BY kind) FROM current_lifecycle_events WHERE segment_id='$seg'")" "exit,start"
  expect "attribution persisted" \
    "$(q "SELECT complexity, task_id FROM current_attribution_events WHERE segment_id='$seg'")" "unknown,TASK-DEMO-001"
  expect "spool drained" "$(ls "$usage/collector/spool" | wc -l | tr -d ' ')" "0"
else
  ok "dolt not installed; store assertions skipped"
fi

# --- unwritable usage state: stop continues, cleanup refuses ---------------
launch && ok "second launch" || bad "second launch"
name=$(field name)
chmod 500 "$usage/collector"
"$nogg" session stop "$name" >"$out" 2>&1 && ok "stop does not fail on unwritable usage state" || bad "stop failed"
grep -qF "NOTE: usage collection skipped" "$out" && ok "stop reports skipped collection" || bad "stop NOTE"
if "$nogg" session cleanup "$name" >"$out" 2>&1; then bad "cleanup should refuse"
else
  grep -qF "cleanup refused" "$out" && grep -qF ".nogging/state/token-usage/" "$out" \
    && ok "cleanup refuses naming the remedy" || bad "cleanup refusal text"
  expect "record not retired" "$(field state)" "stopped"
fi
chmod 700 "$usage/collector"
"$nogg" session cleanup "$name" >"$out" 2>&1 && ok "cleanup succeeds once evidence is durable" || bad "cleanup after repair"
expect "record retired" "$(field state)" "retired"

exit "$fail"
