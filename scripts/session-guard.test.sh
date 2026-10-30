#!/usr/bin/env bash
# TASK-SWK-003 (openspec/changes/session-wake): the completion check and the
# bounded stop guard on Claude, Codex and Pi. Offline: stub hooks, a scratch git
# repository and a fake Pi, no real agent.
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
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
expect() { # expect <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected: $2, got: $3)"; fi
}

root="$work/root"
mkdir -p "$root/.nogging/state/sessions" "$root/.nogging/state/worktrees" "$root/scripts"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
export NOGGING_ROOT="$root"
upstream="$work/upstream.git"
git init -q --bare -b develop "$upstream"
git -C "$root" init -q -b develop
printf '.nogging/\nscripts/\n' > "$root/.gitignore"
git -C "$root" add .gitignore
git -C "$root" commit -qm init
git -C "$root" remote add origin "$upstream"
git -C "$root" push -q -u origin develop

sessions="$root/.nogging/state/sessions"
write_record() { # write_record <name> <agent> [extra python dict items]
  python3 - "$sessions/$1.json" "$1" "$2" "$root" "${3:-}" <<'PY'
import json, sys
path, name, agent, root, extra = sys.argv[1:6]
record = {"name": name, "role": "lead", "agent": agent, "state": "running", "working_dir": root,
          "launch_prompt": "autonomous", "kickoff_sent_at": "2026-10-30T00:00:00Z"}
record.update(eval("{" + extra + "}"))
json.dump(record, open(path, "w"))
PY
}
stop() { # stop <name> <payload> [agent]: the hook's stdout
  printf '%s' "$2" | NOGG_SESSION_NAME="$1" NOGG_SESSION_AGENT="${3:-claude}" \
    "$nogg" session emit turn_end --guard ${3:+--runtime "$3"} 2>/dev/null || true
}
events() { # events <name>: the event names, comma separated
  python3 -c "
import json, sys, os
path = sys.argv[1]
rows = [json.loads(l) for l in open(path) if l.strip()] if os.path.exists(path) else []
print(','.join(r['event'] for r in rows))" "$sessions/$1.events.jsonl"
}
decision() { python3 -c "
import json, sys
text = sys.argv[1].strip()
print(json.loads(text).get('decision') if text else 'allow')" "$1"; }
reason() { python3 -c "import json, sys; print(json.loads(sys.argv[1])['reason'])" "$1"; }
append() { printf '{"event":"%s","timestamp":"2026-10-30T00:00:01Z"}\n' "$2" >> "$sessions/$1.events.jsonl"; }

# --- pure unit tests (source-only; an installed consumer skips) -----------------
if [[ -f "$here/lib/session_signals_test.py" ]]; then
  python3 "$here/lib/session_signals_test.py" >"$work/unit.out" 2>&1 && ok "session_signals_test.py" \
    || { bad "session_signals_test.py"; cat "$work/unit.out"; }
else
  ok "session_signals_test.py skipped (installed consumer copy)"
fi

# --- the hook, on Claude and Codex ----------------------------------------------
for agent in claude codex; do
  s="s-$agent"
  write_record "$s" "$agent"
  echo dirty > "$root/dirty.txt"
  out=$(stop "$s" '{"stop_hook_active":false,"last_assistant_message":"AGENT-TEXT-MARKER"}' "$agent")
  expect "$agent: a dirty tree blocks the stop" block "$(decision "$out")"
  text=$(reason "$out")
  [[ "$text" == *"You are ending your turn with: uncommitted changes"* ]] \
    && ok "$agent: the fixed message names the gap" || bad "$agent: message: $text"
  [[ "$text" == *'./scripts/nogg session signal blocked "<why>"'* ]] \
    && ok "$agent: the message offers the blocked signal" || bad "$agent: message: $text"
  [[ "$text" != *"AGENT-TEXT-MARKER"* ]] && ok "$agent: no agent text reaches the message" || bad "$agent: echoed agent text"
  expect "$agent: a continued stop records guard_continue, not turn_end" guard_continue "$(events "$s")"

  out=$(stop "$s" '{"stop_hook_active":true}' "$agent")
  expect "$agent: stop_hook_active always allows the stop" allow "$(decision "$out")"
  expect "$agent: the allowed stop records turn_end" guard_continue,turn_end "$(events "$s")"
  rm "$root/dirty.txt"

  out=$(stop "$s" '{"stop_hook_active":false}' "$agent")
  [[ "$(reason "$out")" == *"no completion signal"* ]] && ok "$agent: a missing signal is a gap" \
    || bad "$agent: no-signal not reported: $out"

  NOGG_SESSION_NAME="$s" NOGG_SESSION_AGENT="$agent" "$nogg" session signal done "PR 1 open" >/dev/null
  echo dirty > "$root/dirty.txt"
  out=$(stop "$s" '{"stop_hook_active":false}' "$agent")
  expect "$agent: a signal in this turn allows a dirty stop" allow "$(decision "$out")"
  rm "$root/dirty.txt"
done

# A blocked Lead may stop with a dirty tree.
write_record s-blocked claude
append s-blocked turn_start
NOGG_SESSION_NAME=s-blocked NOGG_SESSION_AGENT=claude "$nogg" session signal blocked "needs an operator" >/dev/null
echo dirty > "$root/dirty.txt"
expect "a blocked Lead may stop" allow "$(decision "$(stop s-blocked '{}' claude)")"

# A signal from an earlier turn does not excuse this one.
write_record s-stale codex
append s-stale done; append s-stale turn_end
expect "a signal from an earlier turn does not excuse this one" block \
  "$(decision "$(stop s-stale '{}' codex)")"

write_record s-claude-new claude
append s-claude-new done; append s-claude-new turn_start
expect "a turn_start ends a signal's cover" block "$(decision "$(stop s-claude-new '{}' claude)")"

# Never blocked: background tasks, an API error, the wrong session kind.
write_record s-bg claude
expect "background tasks allow the stop" allow \
  "$(decision "$(stop s-bg '{"background_tasks":[{"status":"running"}]}' claude)")"
write_record s-err claude
append s-err turn_start; append s-err turn_error
expect "a turn that ended in an API error is never blocked" allow "$(decision "$(stop s-err '{}' claude)")"

write_record s-plan claude '"role": "planning"'
expect "a planning session is not guarded" allow "$(decision "$(stop s-plan '{}' claude)")"
write_record s-restricted claude '"launch_prompt": "no-autonomous-claim"'
expect "a Lead not under the autonomous prompt is not guarded" allow "$(decision "$(stop s-restricted '{}' claude)")"
write_record s-old claude '"launch_prompt": None'
expect "a record from before the prompt was recorded is not guarded" allow "$(decision "$(stop s-old '{}' claude)")"
write_record s-agy claude '"agent": "antigravity"'
expect "an unguarded runtime is not guarded" allow "$(decision "$(stop s-agy '{}' claude)")"
write_record s-startup codex '"kickoff_sent_at": None'
expect "a startup turn before the kickoff is not guarded" allow "$(decision "$(stop s-startup '{}' codex)")"
expect "the startup turn still records its turn_end" turn_end "$(events s-startup)"
rm "$root/dirty.txt"

# A Codex child inside a Claude session must not speak for its parent.
write_record s-nested claude
out=$(stop_nested() { printf '{}' | NOGG_SESSION_NAME=s-nested NOGG_SESSION_AGENT=claude \
  "$nogg" session emit turn_end --guard --runtime codex; }; stop_nested)
expect "a nested runtime's hook is ignored" "" "$out"
expect "a nested runtime's hook records nothing" "" "$(events s-nested)"

# --- which checkout: the Bead's worktree, not the launch directory ---------------
wt="$work/wt"
git -C "$root" worktree add -q -b feat/x "$wt" develop
printf '{"bead_id":"SPEC-abc","branch":"feat/x","kind":"implementation","path":"%s","state":"allocated"}\n' "$wt" \
  > "$root/.nogging/state/worktrees/implementation--spec-abc.json"
write_record s-wt claude '"bead_id": "SPEC-abc"'
append s-wt turn_start
check() { # check <name> [flags]: completion-check's stdout, and $check_rc
  check_rc=0
  check_out=$(NOGG_SESSION_NAME="$1" NOGG_SESSION_AGENT=claude "$nogg" session completion-check --json) || check_rc=$?
}
gaps() { python3 -c "import json, sys; print(','.join(json.loads(sys.argv[1])['gaps']))" "$check_out"; }
echo work > "$wt/file.txt"
check s-wt
expect "completion-check reads the Bead's worktree" dirty,unpushed,no-signal "$(gaps)"
expect "completion-check exits 1 on gaps" 1 "$check_rc"
git -C "$wt" add file.txt; git -C "$wt" commit -qm work
check s-wt
expect "committed work on a branch tracking nothing new is unpushed" unpushed,no-signal "$(gaps)"
git -C "$wt" push -q origin feat/x
check s-wt
expect "a pushed branch is no gap even without -u" no-signal "$(gaps)"
echo more > "$wt/more.txt"; git -C "$wt" add more.txt; git -C "$wt" commit -qm more
check s-wt
expect "commits ahead of the pushed branch are unpushed" unpushed,no-signal "$(gaps)"
git -C "$wt" push -q origin feat/x
NOGG_SESSION_NAME=s-wt NOGG_SESSION_AGENT=claude "$nogg" session signal done "PR 2 open" >/dev/null
check s-wt
expect "a finished Lead has no gaps" "" "$(gaps)"
expect "completion-check exits 0 without gaps" 0 "$check_rc"
text=$(NOGG_SESSION_NAME=s-wt NOGG_SESSION_AGENT=claude "$nogg" session completion-check)
[[ "$text" == *"no gaps"* ]] && ok "completion-check reads as text" || bad "text: $text"

# --- it fails open --------------------------------------------------------------
rc=0; out=$("$nogg" session completion-check 2>&1) || rc=$?
expect "outside a session the check exits 0" 0 "$rc"
[[ "$out" == *"unknown"* ]] && ok "outside a session the check says it does not know" || bad "out: $out"

printf 'not json' > "$sessions/s-corrupt.json"
echo dirty > "$root/dirty.txt"
expect "an unreadable record allows the stop" allow "$(decision "$(stop s-corrupt '{}' claude)")"
expect "an unreadable record still records turn_end" turn_end "$(events s-corrupt)"
rc=0; NOGG_SESSION_NAME=s-corrupt NOGG_SESSION_AGENT=claude "$nogg" session completion-check --json >/dev/null 2>&1 || rc=$?
expect "an internal error exits 0" 0 "$rc"
rm "$root/dirty.txt"

write_record s-raises claude
out=$(python3 - "$nogg" <<'PY'
import io, sys, subprocess
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
m = SourceFileLoader("sf_swk003", sys.argv[1]).load_module()
sys.stdin = io.StringIO("")
with patch.object(m, "session_git_facts", side_effect=RuntimeError("boom")), \
     patch.dict(m.os.environ, {"NOGG_SESSION_NAME": "s-raises", "NOGG_SESSION_AGENT": "claude"}):
    m.session_emit("turn_end", guard=True)
with patch.object(m, "run", side_effect=subprocess.TimeoutExpired("git", 5)), \
     patch.dict(m.os.environ, {"NOGG_SESSION_NAME": "s-raises", "NOGG_SESSION_AGENT": "claude"}):
    m.session_emit("turn_end", guard=True)
PY
)
expect "a raising or timed-out check allows the stop" "" "$out"
expect "a raising check still records turn_end" turn_end,turn_end "$(events s-raises)"

# --- wiring ---------------------------------------------------------------------
python3 - "$nogg" <<'PY' && ok "Claude's Stop hook carries --guard, and only Stop" || bad "Stop hook wiring"
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_swk003b", sys.argv[1]).load_module()
hooks = m.merge_observability_hooks({})["hooks"]
assert hooks["Stop"][0]["hooks"][0]["command"].endswith("session emit turn_end --guard"), hooks["Stop"]
for event in ("UserPromptSubmit", "Notification", "StopFailure", "SessionEnd"):
    assert "--guard" not in hooks[event][0]["hooks"][0]["command"], event
PY
grep -qF '"launch_prompt"' "$nogg" && ok "launch records the prompt the guard keys on" || bad "launch_prompt missing"

[[ $fail -eq 0 ]] && echo "all session-guard checks passed" || { echo "session-guard: checks failed" >&2; exit 1; }
