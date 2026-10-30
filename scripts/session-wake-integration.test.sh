#!/usr/bin/env bash
# TASK-SWK-006 (openspec/changes/session-wake): one Lead from kickoff to merged, through
# the real CLI with an injected clock, then the same life cycle across a pause and across
# a quiet-hours window. The fixture config sets no `enabled` key, so all of it runs on the
# default. Offline: a stub orchestrator and stub agents on a private socket, stub gh, stub bd.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs

while IFS= read -r inherited; do
  case "$inherited" in
    NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_*|GIT_*) unset "$inherited" ;;
  esac
done < <(compgen -e)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
work=$(mktemp -d); trap 'rm -rf "${work:?}"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
expect() { # expect <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected: $2, got: $3)"; fi
}
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no '$2' in: $3)" ;; esac; }

if ! command -v tmux >/dev/null; then
  ok "session-wake-integration skipped (tmux unavailable)"
  exit 0
fi

export HOME="$work/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
# A socket path must stay under 108 bytes, whatever TMPDIR is.
export TMUX_TMPDIR; TMUX_TMPDIR=$(mktemp -d /tmp/nogg-swk006.XXXXXX)
export NOGG_TEST_ARGS_DIR="$work/args"; mkdir -p "$NOGG_TEST_ARGS_DIR"
sock="nogg-swk006-$$"
trap 'tmux -L "$sock" kill-server 2>/dev/null || true; rm -rf "${work:?}" "${TMUX_TMPDIR:?}"' EXIT
root="$work/root"
sessions="$root/.nogging/state/sessions"
queue_file="$root/.nogging/state/dispatch/queue.json"
orch="nogg-orchestrator-root"
mkdir -p "$sessions" "$root/.nogging/state/worktrees" "$root/scripts" "$root/openspec/changes/demo" "$work/bin"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
ln -s "$here/lib" "$root/scripts/lib"
export NOGGING_ROOT="$root"
python3 - "$root/.nogging/config.json" "$sock" <<'PY'
import json, sys
path, sock = sys.argv[1:3]
config = json.load(open(path))
config.update(session_tmux_socket=sock, session_backend="tmux", session_dispatch={"retire_merged": True})
config["usage_gate"] = {"enabled": False}
json.dump(config, open(path, "w"), indent=2)
PY
cat >"$root/openspec/changes/demo/tasks.md" <<'MD'
# Tasks

- [ ] TASK-DEMO-1 [routine] [~10 loc] One.
- [ ] TASK-DEMO-2 [routine] [~10 loc] Two.
- [ ] TASK-DEMO-3 [routine] [~10 loc] Three.
MD
echo '# Demo' >"$root/openspec/changes/demo/proposal.md"
git init -q --bare -b develop "$work/upstream.git"
git -C "$root" init -q -b develop
printf '.nogging/\nscripts/\n' >"$root/.gitignore"
git -C "$root" add .gitignore openspec; git -C "$root" commit -qm init
git -C "$root" remote add origin "$work/upstream.git"; git -C "$root" push -q -u origin develop

printf '#!/bin/sh\ncat "%s/gh.json"\n' "$work" >"$work/bin/gh"
printf '#!/bin/sh\ncat "%s/bd.json"\n' "$work" >"$work/bin/bd"
chmod +x "$work/bin/gh" "$work/bin/bd"; export PATH="$work/bin:$PATH"
echo '[]' >"$work/gh.json"

cat >"$work/runtime.py" <<'PY'
import sys
rule = "─" * 80
def paint():
    print(rule + "\n❯ \n" + rule + "\n   ⏵⏵ bypass permissions on", flush=True)
print("stub agent started", flush=True)
paint()
for line in sys.stdin:
    with open(sys.argv[1], "a") as inbox:
        inbox.write(line)
    paint()
PY
# The real command line with both clocks of scripts/nogg moved on by <offset> seconds.
cat >"$work/at.py" <<'PY'
import datetime as real_datetime, sys, time as real_time, types
from importlib.machinery import SourceFileLoader
offset, script = float(sys.argv[1]), sys.argv[2]
m = SourceFileLoader("nogg_at", script).load_module()
class Clock(real_datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return real_datetime.datetime.now(tz) + real_datetime.timedelta(seconds=offset)
m.dt = types.SimpleNamespace(**{key: getattr(real_datetime, key) for key in dir(real_datetime) if not key.startswith("__")})
m.dt.datetime = Clock
m.time = types.SimpleNamespace(**{key: getattr(real_time, key) for key in dir(real_time) if not key.startswith("__")})
m.time.time = lambda: real_time.time() + offset
sys.argv = [script, *sys.argv[3:]]
m.main()
PY
clock=0
at() { python3 "$work/at.py" "$clock" "$nogg" "$@"; }
pass() { clock=$((clock + $1)); at session dispatch --once; } # pass <seconds later>
tick() { clock=$((clock + $1)); at loop tick; }
lines() { [[ -f "$work/$1.inbox" ]] && { grep -c "$2" "$work/$1.inbox" || true; } || echo 0; }
until_lines() { for _ in $(seq 1 50); do [[ "$(lines "$1" "$2")" == "$3" ]] && return 0; sleep 0.1; done; return 0; }
until_prompt() { for _ in $(seq 1 50); do tmux -L "$sock" capture-pane -p -t "$1" | grep -q '❯' && return 0; sleep 0.1; done; return 1; }
items() { python3 -c "import json,sys; print(','.join(sorted(i['kind'] for i in json.load(open(sys.argv[1])).get('items') or [])))" "$queue_file"; }
live() { tmux -L "$sock" has-session -t "=$1" 2>/dev/null && echo live || echo gone; }
beads() { # beads <id:status> ...: the whole Bead list, each mapped to the demo task of its number
  python3 - "$work/bd.json" "$@" <<'PY'
import json, sys
rows = []
for pair in sys.argv[2:]:
    bead, status = pair.split(":")
    rows.append({"id": bead, "status": status, "labels": ["openspec:change:demo", f"openspec:task:TASK-DEMO-{bead[1:]}"]})
json.dump(rows, open(sys.argv[1], "w"))
PY
  clock=$((clock + 301)) # past the Bead cache of a pass
}
pull_request() { # pull_request <lead> <OPEN|MERGED> <check conclusion or pending>: what gh reports for its head
  python3 - "$work/gh.json" "$(git -C "$work/$1" rev-parse HEAD)" "$2" "$3" <<'PY'
import json, sys
path, head, state, outcome = sys.argv[1:5]
check = {"name": "unit", "workflowName": "ci", "detailsUrl": "https://ci.invalid/" + head[:8],
         "status": "IN_PROGRESS" if outcome == "pending" else "COMPLETED"}
if outcome != "pending":
    check["conclusion"] = outcome
json.dump([{"number": 7, "url": "https://github.invalid/pull/7", "state": state, "headRefOid": head,
            "statusCheckRollup": [check], "mergeable": "MERGEABLE", "additions": 1, "deletions": 0}], open(path, "w"))
PY
}
start() { # start <name> <role> <bead>: a live, kicked-off session with a record and no hook
  local name=$1 role=$2 bead=$3 tree="$work/$1"
  git -C "$root" worktree add -q -b "feat/$name" "$tree" develop
  git -C "$tree" push -q -u origin "feat/$name"
  python3 - "$sessions/$name.json" "$name" "$role" "$bead" "$root" "$tree" <<'PY'
import json, sys
path, name, role, bead, root, tree = sys.argv[1:7]
record = {"name": name, "role": role, "agent": "claude", "state": "running", "working_dir": root,
          "launch_prompt": "autonomous", "kickoff_sent_at": "2026-10-30T00:00:00+00:00",
          "started_at": "2026-10-30T00:00:00+00:00", "log_path": root + "/" + name + ".log"}
if bead:
    record["bead_id"] = bead
    json.dump({"bead_id": bead, "path": tree},
              open(root + "/.nogging/state/worktrees/implementation--" + bead.lower() + ".json", "w"))
json.dump(record, open(path, "w"))
PY
  tmux -L "$sock" new-session -d -s "$name" -x 100 -y 12 "python3 $work/runtime.py $work/$name.inbox"
  until_prompt "$name" || bad "fixture: $name never painted a prompt"
}
save_work() { git -C "$work/$1" add -A; git -C "$work/$1" commit -qm "${2:-work}"; git -C "$work/$1" push -q; }
wakes() { lines "$orch" '^\[nogg wake '; }

start "$orch" orchestrator ""
printf '{"event": "turn_end", "timestamp": "%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" >"$sessions/$orch.events.jsonl"

# --- a Lead from kickoff to merged ---------------------------------------------------
beads B1:in_progress
start lead-1 lead B1
echo wip >"$work/lead-1/wip.txt"
pass 0 >/dev/null
expect "life: the first pass only starts the settle" "0" "$(lines lead-1 .)"
pass 90 >/dev/null
until_lines lead-1 . 1
has "life: an idle Lead with work is nudged, on the default" "uncommitted changes" "$(cat "$work/lead-1.inbox")"

save_work lead-1
pass 90 >/dev/null
until_lines lead-1 'no pull request' 1
sleep 0.3
expect "life: a clean Lead with no pull request is told to open one" "1" "$(lines lead-1 'no pull request')"

pull_request lead-1 OPEN pending
NOGG_SESSION_NAME=lead-1 at session signal done "PR #7 open" >/dev/null
before=$(lines lead-1 .)
pass 180 >/dev/null; pass 180 >/dev/null
expect "life: pending CI sends nothing" "$before" "$(lines lead-1 .)"
expect "life: and wakes nobody" "0" "$(wakes)"

pull_request lead-1 OPEN FAILURE
pass 180 >/dev/null
until_lines lead-1 'CI is failing on PR #7: unit' 1
expect "life: red CI nudges with the check name" "1" "$(lines lead-1 'CI is failing on PR #7: unit')"

git -C "$work/lead-1" commit -q --allow-empty -m fix; git -C "$work/lead-1" push -q
pull_request lead-1 OPEN SUCCESS
NOGG_SESSION_NAME=lead-1 at session signal done "PR #7 green" >/dev/null
pass 180 >/dev/null
expect "life: green CI queues a decision" "ready_for_review" "$(items)"
expect "life: which waits out its calm" "0" "$(wakes)"
pass 400 >/dev/null
until_lines "$orch" '^\[nogg wake ' 1
expect "life: one digest reaches the orchestrator" "1" "$(wakes)"
has "life: it names the item" "review B1 lead-1 PR #7" "$(cat "$work/$orch.inbox")"
expect "life: the queue is empty" "" "$(items)"

pull_request lead-1 MERGED SUCCESS
beads B1:closed
pass 400 >/dev/null
expect "life: a merged, closed and clean Lead is retired" "gone" "$(live lead-1)"
grep -q '"action": "retire"' "$root/.nogging/state/dispatch/dispatch.jsonl" && ok "life: the retirement is audited" || bad "life: no audit row"
pass 400 >/dev/null
expect "life: a pass after it changes nothing" "1" "$(wakes)"

# --- the same life across a pause ----------------------------------------------------
echo '[]' >"$work/gh.json"
beads B1:closed B2:in_progress
start lead-2 lead B2
echo wip >"$work/lead-2/wip.txt"
at pause --days 1 >/dev/null
keep_warm=$(lines "$orch" 'nogg keepwarm')
pass 90 >/dev/null; pass 90 >/dev/null
expect "pause: an idle Lead with work is not nudged" "0" "$(lines lead-2 .)"
# A running Lead may finish: it saves, opens its pull request and goes green.
save_work lead-2
pull_request lead-2 OPEN SUCCESS
NOGG_SESSION_NAME=lead-2 at session signal done "PR #7 green" >/dev/null
pass 200 >/dev/null; pass 1000 >/dev/null
expect "pause: the decision is queued" "ready_for_review" "$(items)"
expect "pause: nothing wakes the orchestrator" "1" "$(wakes)"
expect "pause: no keep-warm goes out" "$keep_warm" "$(lines "$orch" 'nogg keepwarm')"
expect "pause: the Lead has still heard nothing" "0" "$(lines lead-2 .)"
tick 90000 >/dev/null
[[ ! -e "$root/.nogging/state/pause.json" ]] && ok "pause: a tick past its end ends it" || bad "pause: it stayed"
until_lines "$orch" '^\[nogg wake ' 2
expect "pause: one digest follows" "2" "$(wakes)"
tail -n 12 "$work/$orch.inbox" >"$work/digest"
has "pause: the digest has the summary" "resumed" "$(cat "$work/digest")"
has "pause: and the decision that still holds" "review B2 lead-2 PR #7" "$(cat "$work/digest")"
has "pause: and the retirement of the first life" "Retired: B1" "$(cat "$work/digest")"
pull_request lead-2 MERGED SUCCESS
beads B1:closed B2:closed
tick 400 >/dev/null
expect "pause: the life ends the same way" "gone" "$(live lead-2)"

# --- the same life across quiet hours ------------------------------------------------
echo '[]' >"$work/gh.json"
beads B1:closed B2:closed B3:in_progress
start lead-3 lead B3
echo wip >"$work/lead-3/wip.txt"
python3 - "$root/.nogging/config.json" "$clock" <<'PY'
import json, sys
from datetime import datetime, timedelta
path, offset = sys.argv[1], int(sys.argv[2])
moment = datetime.now() + timedelta(seconds=offset)
config = json.load(open(path))
window = f"{moment - timedelta(minutes=30):%H:%M}-{moment + timedelta(hours=2):%H:%M}"
config["session_dispatch"]["wake"] = {"quiet_hours": [window], "keep_warm": False}
json.dump(config, open(path, "w"), indent=2)
PY
tick 90 >/dev/null; tick 90 >/dev/null
until_lines lead-3 . 1
has "quiet: a Lead is still nudged inside the window" "uncommitted changes" "$(cat "$work/lead-3.inbox")"
save_work lead-3
pull_request lead-3 OPEN SUCCESS
NOGG_SESSION_NAME=lead-3 at session signal done "PR #7 green" >/dev/null
tick 180 >/dev/null; tick 1000 >/dev/null
expect "quiet: the decision is queued" "ready_for_review" "$(items)"
expect "quiet: nothing wakes the orchestrator" "2" "$(wakes)"
tick 7200 >/dev/null
until_lines "$orch" '^\[nogg wake ' 3
expect "quiet: one digest after the window" "3" "$(wakes)"
pull_request lead-3 MERGED SUCCESS
beads B1:closed B2:closed B3:closed
tick 400 >/dev/null
expect "quiet: the life ends the same way" "gone" "$(live lead-3)"

[[ $fail -eq 0 ]] || { echo "session-wake-integration: checks failed" >&2; exit 1; }
echo "session-wake-integration: ok"
