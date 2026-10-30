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
lead="$work/lead"
git -C "$root" worktree add -q -b feat/lead "$lead" develop
git -C "$lead" push -q -u origin feat/lead
write_record() { # write_record <name> <agent> [extra python dict items]
  python3 - "$sessions/$1.json" "$1" "$2" "$root" "${3:-}" <<'PY'
import json, sys
path, name, agent, root, extra = sys.argv[1:6]
record = {"name": name, "role": "lead", "agent": agent, "state": "running", "working_dir": root + "/../lead",
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
  echo dirty > "$lead/dirty.txt"
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
  rm "$lead/dirty.txt"

  out=$(stop "$s" '{"stop_hook_active":false}' "$agent")
  [[ "$(reason "$out")" == *"no completion signal"* ]] && ok "$agent: a missing signal is a gap" \
    || bad "$agent: no-signal not reported: $out"

  NOGG_SESSION_NAME="$s" NOGG_SESSION_AGENT="$agent" "$nogg" session signal done "PR 1 open" >/dev/null
  echo dirty > "$lead/dirty.txt"
  out=$(stop "$s" '{"stop_hook_active":false}' "$agent")
  expect "$agent: a signal in this turn allows a dirty stop" allow "$(decision "$out")"
  rm "$lead/dirty.txt"
done

# A blocked Lead may stop with a dirty tree.
write_record s-blocked claude
append s-blocked turn_start
NOGG_SESSION_NAME=s-blocked NOGG_SESSION_AGENT=claude "$nogg" session signal blocked "needs an operator" >/dev/null
echo dirty > "$lead/dirty.txt"
expect "a blocked Lead may stop" allow "$(decision "$(stop s-blocked '{"stop_hook_active":false}' claude)")"

# A signal from an earlier turn does not excuse this one.
write_record s-stale codex
append s-stale done; append s-stale turn_end
expect "a signal from an earlier turn does not excuse this one" block \
  "$(decision "$(stop s-stale '{"stop_hook_active":false}' codex)")"

write_record s-claude-new claude
append s-claude-new done; append s-claude-new turn_start
expect "a turn_start ends a signal's cover" block "$(decision "$(stop s-claude-new '{"stop_hook_active":false}' claude)")"

# Never blocked: background tasks, an API error, the wrong session kind.
write_record s-bg claude
expect "background tasks allow the stop" allow \
  "$(decision "$(stop s-bg '{"stop_hook_active":false,"background_tasks":[{"status":"running"}]}' claude)")"
write_record s-err claude
append s-err turn_start; append s-err turn_error
expect "a turn that ended in an API error is never blocked" allow "$(decision "$(stop s-err '{"stop_hook_active":false}' claude)")"

write_record s-plan claude '"role": "planning"'
expect "a planning session is not guarded" allow "$(decision "$(stop s-plan '{"stop_hook_active":false}' claude)")"
write_record s-restricted claude '"launch_prompt": "no-autonomous-claim"'
expect "a Lead not under the autonomous prompt is not guarded" allow "$(decision "$(stop s-restricted '{"stop_hook_active":false}' claude)")"
write_record s-old claude '"launch_prompt": None'
expect "a record from before the prompt was recorded is not guarded" allow "$(decision "$(stop s-old '{"stop_hook_active":false}' claude)")"
write_record s-agy claude '"agent": "antigravity"'
expect "an unguarded runtime is not guarded" allow "$(decision "$(stop s-agy '{"stop_hook_active":false}' claude)")"
write_record s-startup codex '"kickoff_sent_at": None'
expect "a startup turn before the kickoff is not guarded" allow "$(decision "$(stop s-startup '{"stop_hook_active":false}' codex)")"
expect "the startup turn still records its turn_end" turn_end "$(events s-startup)"
rm "$lead/dirty.txt"

# A Codex child inside a Claude session must not speak for its parent.
write_record s-nested claude
out=$(stop_nested() { printf '{}' | NOGG_SESSION_NAME=s-nested NOGG_SESSION_AGENT=claude \
  "$nogg" session emit turn_end --guard --runtime codex; }; stop_nested)
expect "a nested runtime's hook is ignored" "" "$out"
expect "a nested runtime's hook records nothing" "" "$(events s-nested)"

# The bound survives a payload that cannot be read.
write_record s-junk claude
echo dirty > "$lead/dirty.txt"
expect "an unreadable payload allows the stop" allow "$(decision "$(stop s-junk 'not json' claude)")"
big=$(python3 -c "import json; print(json.dumps({'stop_hook_active': True, 'last_assistant_message': 'x' * 70000}))")
expect "a payload past the read limit allows the stop" allow "$(decision "$(stop s-junk "$big" claude)")"
write_record s-twice claude
expect "the first stop is continued" block "$(decision "$(stop s-twice '{"stop_hook_active":false}' claude)")"
expect "guard_continue bounds a sequence even if a hook lies about it" allow \
  "$(decision "$(stop s-twice '{"stop_hook_active":false}' claude)")"
rm "$lead/dirty.txt"

# A stale `done` on Codex does not cover a later turn, on a clean tree either.
write_record s-stale-clean codex
append s-stale-clean done; append s-stale-clean turn_end
out=$(stop s-stale-clean '{"stop_hook_active":false}' codex)
[[ "$(reason "$out")" == *"no completion signal"* ]] && ok "an old signal is no signal for this stop" || bad "stale signal: $out"

# The events file is the session's to replace; the hook must not follow a link.
write_record s-link claude
printf 'precious\n' > "$work/precious"
ln -s "$work/precious" "$sessions/s-link.events.jsonl"
rc=0; printf '{}' | NOGG_SESSION_NAME=s-link NOGG_SESSION_AGENT=claude "$nogg" session emit turn_end >/dev/null 2>&1 || rc=$?
expect "a symlinked events file is not written through" precious "$(cat "$work/precious")"
rm "$sessions/s-link.events.jsonl"

# A Lead in the shared checkout answers for nothing it cannot call its own.
write_record s-shared claude "\"working_dir\": \"$root\""
append s-shared turn_start
printf 'not mine\n' > "$root/other.txt"
out=$(stop s-shared '{"stop_hook_active":false}' claude)
expect "a Lead in the shared checkout is still asked for its signal" block "$(decision "$out")"
text=$(reason "$out")
[[ "$text" == *"no completion signal"* && "$text" != *"uncommitted changes"* ]] \
  && ok "someone else's dirty file in the shared checkout is no gap" || bad "shared: $text"
rm "$root/other.txt"

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

# --- from a linked worktree: NOGGING_ROOT is unset in a real session, so the script's
#     own copy resolves ROOT to the worktree, whose store is empty ---------------------
mkdir -p "$wt/scripts/lib" "$wt/.nogging"
cp "$nogg" "$here/nogg_usage.py" "$wt/scripts/"; cp "$here"/lib/session_*.py "$wt/scripts/lib/"
cp "$root/.nogging/config.json" "$wt/.nogging/config.json"
write_record s-linked claude '"bead_id": "SPEC-abc"'
append s-linked turn_start
rm "$wt/more.txt" 2>/dev/null || true
env -u NOGGING_ROOT NOGG_SESSION_NAME=s-linked NOGG_SESSION_AGENT=claude \
  "$wt/scripts/nogg" session signal blocked "needs an operator" >/dev/null
expect "a signal from a worktree reaches the canonical store" turn_start,blocked "$(events s-linked)"
[[ ! -e "$wt/.nogging/state/sessions/s-linked.events.jsonl" ]] && ok "the signal did not land in the worktree's copy" || bad "signal in worktree store"
out=$(env -u NOGGING_ROOT NOGG_SESSION_NAME=s-linked NOGG_SESSION_AGENT=claude \
  "$wt/scripts/nogg" session completion-check --json) || true
[[ "$out" == *'"session": "s-linked"'* ]] && ok "completion-check finds its record from a worktree" || bad "worktree check: $out"
expect "the guard honours that signal" allow "$(decision "$(stop s-linked '{"stop_hook_active":false}' claude)")"

# Only a session's own record resolves through the canonical store: every backend,
# lock and liveness path around load_session reads the checkout's own store.
out=$(env -u NOGGING_ROOT NOGG_SESSION_NAME=s-linked NOGG_SESSION_AGENT=claude \
  "$wt/scripts/nogg" session stop s-wt --reason "from a worktree" 2>&1) && rc=0 || rc=$?
expect "a worktree cannot stop another session it cannot see the backend of" 1 "$rc"
[[ "$out" == *"no managed session"* ]] && ok "another session stays out of reach, as before" || bad "stop: $out"
expect "that session's record is untouched" running \
  "$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['state'])" "$sessions/s-wt.json")"

# --- it fails open --------------------------------------------------------------
rc=0; out=$("$nogg" session completion-check 2>&1) || rc=$?
expect "outside a session the check exits 0" 0 "$rc"
[[ "$out" == *"unknown"* ]] && ok "outside a session the check says it does not know" || bad "out: $out"

printf 'not json' > "$sessions/s-corrupt.json"
echo dirty > "$lead/dirty.txt"
expect "an unreadable record allows the stop" allow "$(decision "$(stop s-corrupt '{"stop_hook_active":false}' claude)")"
expect "an unreadable record still records turn_end" turn_end "$(events s-corrupt)"
rc=0; NOGG_SESSION_NAME=s-corrupt NOGG_SESSION_AGENT=claude "$nogg" session completion-check --json >/dev/null 2>&1 || rc=$?
expect "an internal error exits 0" 0 "$rc"
rm "$lead/dirty.txt"

write_record s-raises claude
out=$(python3 - "$nogg" <<'PY'
import subprocess, sys
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
m = SourceFileLoader("sf_swk003", sys.argv[1]).load_module()
env = {"NOGG_SESSION_NAME": "s-raises", "NOGG_SESSION_AGENT": "claude"}
payload = b'{"stop_hook_active":false}'
with patch.object(m, "_read_hook_stdin", return_value=payload), patch.dict(m.os.environ, env):
    with patch.object(m, "session_git_facts", side_effect=RuntimeError("boom")) as facts:
        m.session_emit("turn_end", guard=True)
    assert facts.called, "the check must be reached"
    with patch.object(m, "run", side_effect=subprocess.TimeoutExpired("git", 5)) as git:
        m.session_emit("turn_end", guard=True)
    assert git.called, "the check must be reached"
PY
)
expect "a raising or timed-out check allows the stop" "" "$out"
expect "a raising check still records turn_end" turn_end,turn_end "$(events s-raises)"

# --- Pi: agent_before_settle in the lifecycle extension ---------------------------
ext="$repo_root/.pi/extensions/nogging-lifecycle.ts"
if ! command -v node >/dev/null 2>&1; then
  ok "pi: skipped (node not installed)"
else
  cat > "$work/pi-runner.mjs" <<'NODE'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
const [, , extPath, mode, events] = process.argv;
let mod;
try { mod = await import(pathToFileURL(extPath).href); }
catch (e) { console.log("IMPORT_FAILED"); process.exit(2); }
let failed = 0;
const check = (desc, cond) => { console.log(`${cond ? "ok  " : "FAIL"} - ${desc}`); if (!cond) failed = 1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function fakePi() {
  const handlers = new Map();
  return { handlers,
    on(event, fn) { handlers.set(event, [...(handlers.get(event) || []), fn]); return () => {}; },
    async fire(event, payload = {}) {
      let result;
      for (const fn of handlers.get(event) || []) result = await fn({ type: event, ...payload }, {});
      return result;
    } };
}
const names = () => existsSync(events) ? readFileSync(events, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l).event) : [];
async function waitFor(name, count = 1) {
  for (let i = 0; i < 200; i++) { if (names().filter((n) => n === name).length >= count) return true; await sleep(50); }
  return false;
}
const settle = (extra = {}) => ({ outcome: "completed", entries: [], continue: false, ...extra });
const pi = fakePi();
mod.default(pi);
if (mode === "dirty") {
  await pi.fire("input", { text: "go", source: "interactive" });
  await pi.fire("agent_start");
  const foreign = { type: "custom_message", customType: "other", content: "x", display: false };
  const first = await pi.fire("agent_before_settle", settle({ entries: [foreign] }));
  check("pi: a dirty tree continues the run", first?.continue === true);
  const entry = first?.entries?.at(-1);
  check("pi: the continuation carries the fixed message",
    entry?.type === "custom_message" && String(entry?.content).startsWith("You are ending your turn with: uncommitted changes"));
  check("pi: another extension's proposed entry is kept", first?.entries?.[0] === foreign);
  check("pi: a continued stop records guard_continue", await waitFor("guard_continue"));
  await pi.fire("agent_start");
  check("pi: a second settle for the same input is allowed",
    (await pi.fire("agent_before_settle", settle())) === undefined);
  await pi.fire("input", { text: "again", source: "interactive" });
  await pi.fire("agent_start");
  await waitFor("turn_start", 3);
  check("pi: the next user input gets a new continuation",
    (await pi.fire("agent_before_settle", settle()))?.continue === true);
  await pi.fire("input", { text: "again", source: "interactive" });
  check("pi: an aborted run is never continued",
    (await pi.fire("agent_before_settle", settle({ outcome: "aborted" }))) === undefined);
  check("pi: a run another extension continues needs no guard",
    (await pi.fire("agent_before_settle", settle({ continue: true }))) === undefined);
  await pi.fire("agent_before_settle", settle({ outcome: "error" }));
  check("pi: an API error is never continued", await waitFor("turn_error"));
} else if (mode === "allowed") {
  await pi.fire("input", { text: "go", source: "interactive" });
  await pi.fire("agent_start");
  if (process.env.SIGNAL_NOGG) {
    await waitFor("turn_start");
    execFileSync(process.env.SIGNAL_NOGG, ["session", "signal", "blocked", "no operator"]);
  }
  check(`pi: ${process.env.CASE} allows the settle`, (await pi.fire("agent_before_settle", settle())) === undefined);
}
await pi.fire("session_shutdown", { reason: "reload" });
process.exit(failed);
NODE
  pi_run() { # pi_run <session> <mode> [case], with $PI_ROOT as the nogg root
    NOGG_SESSION_NAME="$1" NOGG_SESSION_AGENT=pi NOGG_SESSION_ROOT="${PI_ROOT:-$repo_root}" CASE="${3:-}" \
      node "$work/pi-runner.mjs" "$ext" "$2" "$sessions/$1.events.jsonl"
  }
  write_record s-pi pi
  echo dirty > "$lead/dirty.txt"
  set +e; out=$(pi_run s-pi dirty); rc=$?; set -e
  if [[ $rc -eq 2 ]]; then
    ok "pi: skipped (node cannot strip types)"
  else
    while IFS= read -r line; do
      case "$line" in "ok  "*) ok "${line#ok   - }" ;; *) bad "${line#FAIL - }" ;; esac
    done <<<"$out"
    pi_allowed() { # pi_allowed <session> <case>
      local out=""
      out=$(pi_run "$1" allowed "$2") || true
      if [[ "$out" == "ok  "* ]]; then ok "${out#ok   - }"; else bad "pi: $2: ${out:-no output}"; fi
    }
    write_record s-pi-blocked pi
    SIGNAL_NOGG="$nogg" pi_allowed s-pi-blocked "a blocked signal"
    write_record s-pi-prekick pi '"kickoff_sent_at": None'
    pi_allowed s-pi-prekick "a session with no kickoff"
    mkdir -p "$work/broken/scripts"
    printf '#!/usr/bin/env bash\necho not-json; exit 3\n' > "$work/broken/scripts/nogg"
    chmod +x "$work/broken/scripts/nogg"
    write_record s-pi-broken pi
    PI_ROOT="$work/broken" pi_allowed s-pi-broken "a broken check"
    PI_ROOT="$work/missing" pi_allowed s-pi-broken "a missing nogg"
  fi
  rm -f "$lead/dirty.txt"
fi

# --- a sandboxed launch refuses before any side effect ----------------------------
mkdir -p "$root/.nogging"
cp -r "$repo_root/.nogging/launch-profiles" "$root/.nogging/launch-profiles"
cp -r "$repo_root/.nogging/launch-prompts" "$root/.nogging/launch-prompts"
if [[ $(id -u) -eq 0 ]]; then
  ok "launch refusal skipped (root ignores file modes)"
else
  export XDG_CACHE_HOME="$work/cache"
  usage_dir="$XDG_CACHE_HOME/nogging/usage/reservations"
  mkdir -p "$usage_dir"; chmod 555 "$usage_dir"
  before=$(ls -A "$sessions" | sort)
  rc=0; out=$("$nogg" session launch --role lead --bead SPEC-abc --agent claude --full-access 2>&1) || rc=$?
  chmod 755 "$usage_dir"
  expect "a launch that cannot write its state is refused" 1 "$rc"
  [[ "$out" == *"this session cannot launch child sessions"* ]] && ok "the refusal is named" || bad "refusal: $out"
  [[ "$out" == *"$usage_dir"* ]] && ok "the refusal names the path" || bad "refusal: $out"
  [[ "$out" == *"signal blocked and let the orchestrator do it"* ]] && ok "the refusal says what to do" || bad "refusal: $out"
  [[ "$out" != *"Errno"* ]] && ok "no raw filesystem error reaches the caller" || bad "raw error: $out"
  expect "the refusal leaves no session, record or log" "$before" "$(ls -A "$sessions" | sort)"
  chmod 555 "$usage_dir"
  got=$(python3 - "$nogg" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_swk003e", sys.argv[1]).load_module()
print(bool(m.read_only_launch_path("lead")), m.read_only_launch_path("lead", ignore_usage_gate=True))
PY
)
  chmod 755 "$usage_dir"
  expect "--ignore-usage-gate does not need the ledger it skips" "True None" "$got"
  unset XDG_CACHE_HOME
fi
python3 - "$nogg" <<'PY' && ok "a read-only error from the usage gate is refused the same way" || bad "usage gate OSError"
import errno, sys
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
m = SourceFileLoader("sf_swk003c", sys.argv[1]).load_module()
error = OSError(errno.EROFS, "Read-only file system", "/x/reservations")
with patch.object(m, "require_agent_binary"), patch.object(m, "read_only_launch_path", return_value=None), \
     patch.object(m, "preflight_session_helpers"), patch.object(m, "bead_records", return_value=[{"labels": []}]), \
     patch.object(m, "unmet_dependencies", return_value=[]), patch.object(m, "session_state_grants", return_value=[]), \
     patch.object(m, "usage_gate_admission", side_effect=error):
    try:
        m._session_launch("lead", "SPEC-abc", None, False, None, full_access=True, agent="claude")
    except RuntimeError as exc:
        assert "cannot launch child sessions" in str(exc) and "Errno" not in str(exc), exc
    else:
        raise SystemExit("no refusal")
PY

# --- session capabilities, derived from what launch resolves ------------------------
caps() { "$nogg" session capabilities --json "$@"; }
answer() { python3 -c "import json, sys; print(json.loads(sys.argv[1])['capabilities'][sys.argv[2]]['answer'])" "$1" "$2"; }

trusted=$(caps --agent codex --profile trusted)
expect "codex trusted: the sandbox cannot write the usage ledger" no "$(answer "$trusted" launch_child_sessions)"
expect "codex trusted: reaches Dolt" yes "$(answer "$trusted" reach_dolt)"
expect "codex trusted: pushes" yes "$(answer "$trusted" push)"
expect "codex trusted: in-process specialists are unknown" unknown "$(answer "$trusted" in_process_specialists)"
restricted=$(caps --agent codex --profile restricted)
expect "codex restricted: no network, no Dolt" no "$(answer "$restricted" reach_dolt)"
expect "codex restricted: no push" no "$(answer "$restricted" push)"
expect "codex restricted: no pull request without a push" no "$(answer "$restricted" open_pull_request)"
claude_trusted=$(caps --agent claude --profile trusted)
expect "claude trusted: launches children" yes "$(answer "$claude_trusted" launch_child_sessions)"
expect "claude trusted: pushes" yes "$(answer "$claude_trusted" push)"
claude_restricted=$(caps --agent claude --profile restricted)
expect "claude restricted: the profile denies push" no "$(answer "$claude_restricted" push)"
expect "claude restricted: no pull request without a push" no "$(answer "$claude_restricted" open_pull_request)"
mkdir -p "$root/.claude/agents"; printf 'x\n' > "$root/.claude/agents/reviewer.md"
expect "claude: specialists come from .claude/agents" yes \
  "$(answer "$(caps --agent claude --profile trusted)" in_process_specialists)"
rm "$root/.claude/agents/reviewer.md"
expect "claude: none without an agent file" no \
  "$(answer "$(caps --agent claude --profile trusted)" in_process_specialists)"
mkdir -p "$root/.pi/extensions"
expect "pi: no guard, no launch, whatever the profile says" no "$(answer "$(caps --agent pi --profile trusted)" push)"
: > "$root/.pi/extensions/nogging-guard.ts"
expect "pi: no sandbox, so a push is possible" yes "$(answer "$(caps --agent pi --profile trusted)" push)"
expect "no helper, no proven rebase" unknown "$(answer "$(caps --agent pi --profile trusted)" rebase_without_operator)"
: > "$root/scripts/openspec-sandbox"
expect "the helper proves the rebase broker" yes "$(answer "$(caps --agent pi --profile trusted)" rebase_without_operator)"
rm "$root/scripts/openspec-sandbox"
python3 - "$nogg" <<'PY' && ok "codex: writable paths alone never read as a launch yes" || bad "codex launch false yes"
import sys
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
m = SourceFileLoader("sf_swk003f", sys.argv[1]).load_module()
spec = {"sandbox": "workspace-write", "network_access": True}
with patch.object(m, "launch_state_paths", return_value=[m.ROOT / "x"]):
    assert m._codex_capabilities(spec)["launch_child_sessions"][0] == "unknown"
PY
expect "antigravity: what is not derived reads unknown" unknown \
  "$(answer "$(caps --agent antigravity --profile restricted)" push)"
text=$("$nogg" session capabilities --agent codex --profile trusted)
[[ "$text" == *"launch_child_sessions"*"no"* ]] && ok "capabilities reads as a table" || bad "text: $text"
rc=0; "$nogg" session capabilities --agent codex --profile nonsense >/dev/null 2>&1 || rc=$?
expect "an unknown profile is refused, as a launch would" 1 "$rc"

# Every answer follows the profile: a spec with the network off changes the table.
sed -i 's/^network_access *= *true/network_access = false/' "$root/.nogging/launch-profiles/trusted.codex.toml"
expect "the table follows the resolved profile, not a list" no \
  "$(answer "$(caps --agent codex --profile trusted)" push)"

# --- SPEC-eeuv: a Lead never adopts a live Lead's Bead ------------------------------
mkdir -p "$work/argv" "$work/launch"
git -C "$work/launch" init -q
cat > "$work/argv/codex" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --help) echo "usage" ;;
  *) printf '%s' "${@: -1}" > "$ARGV_LOG" ;;
esac
STUB
chmod +x "$work/argv/codex"
printf 'THE PROMPT\n' > "$work/prompt.md"
codex_first_turn() { # codex_first_turn [--bead <id>]: the startup prompt Codex receives
  ARGV_LOG="$work/argv.log" PATH="$work/argv:$PATH" "$here/session-launch" --agent codex --sandbox workspace-write \
    --approval never --network on --writable-roots '[]' --prompt "$work/prompt.md" --cwd "$work/launch" "$@" >/dev/null 2>&1
  cat "$work/argv.log"
}
first=$(codex_first_turn --bead SPEC-abc)
[[ "$first" == "Startup only:"* ]] && ok "a Codex startup turn is startup only" || bad "startup: $first"
[[ "$first" == *"launched for Bead SPEC-abc and works only that Bead"* ]] && ok "the startup prompt names the launch Bead" || bad "startup: $first"
[[ "$first" == *"do not run recovery, do not claim or touch any Bead"* ]] && ok "the startup turn waits for the kickoff" || bad "startup: $first"
[[ "$first" == *"THE PROMPT" ]] && ok "the session instructions still follow" || bad "startup: $first"
expect "a launch with no Bead keeps its prompt verbatim" "THE PROMPT" "$(codex_first_turn)"

python3 - "$nogg" <<'PY' && ok "recover marks an owned Bead, and stays loud unless its Lead is proven working" || bad "recover owners"
import os, sys
from importlib.machinery import SourceFileLoader
from unittest.mock import MagicMock, patch
m = SourceFileLoader("sf_swk003d", sys.argv[1]).load_module()
issues = [{"id": bead, "status": "in_progress", "labels": []} for bead in ("SPEC-live", "SPEC-gone")]
commits = {bead: ("a" * 40, f"feat: x [{bead}]", 1) for bead in ("SPEC-live", "SPEC-gone")}
LEAD = {"name": "sf-other", "bead_id": "SPEC-live", "state": "running", "role": "lead"}

def scan(records=None, alive=("sf-other",), own=None, signal=None, unknown=()):
    env = {"NOGG_SESSION_NAME": own} if own else {}
    records = [("p", LEAD)] if records is None else records
    with patch.object(m, "beads", return_value=issues), \
         patch.object(m, "commit_tokens_with_subject", return_value=commits), \
         patch.object(m, "branch_commit_tokens", return_value=set(commits)), \
         patch.object(m, "session_liveness", return_value=(set(alive), set(unknown))), \
         patch.object(m.signals_module(), "current_signal", return_value=signal), \
         patch.object(m, "session_records", return_value=records), patch.dict(os.environ, env):
        sections, attention = m.recover_scan()
    return "\n".join(line for _, lines in sections for line in lines), attention

text, attention = scan()
assert "owned by session sf-other: do not adopt it" in text, text
assert "LIMBO SPEC-live" not in attention and "resumable SPEC-live" not in attention, attention
assert "LIMBO SPEC-gone" in attention and "resumable SPEC-gone" in attention, attention
text, attention = scan(alive=())
assert "do not adopt" not in text and "may still be running" not in text, "a Lead proven dead holds nothing"
assert "LIMBO SPEC-live" in attention, "its replacement sees an ordinary interrupted run"
text, attention = scan(alive=(), unknown=("sf-other",))
assert "may still be running" in text and "session reap" in text, text
assert "do not adopt it" not in text and "LIMBO SPEC-live" in attention, "unknown liveness stays loud"
text, attention = scan(signal={"event": "blocked"})
assert "do not adopt it" in text and "LIMBO SPEC-live" in attention, "a blocked Lead needs a person"
_, attention = scan(own="sf-other")
assert "LIMBO SPEC-live" in attention, "a session's own Bead keeps its classification"
text, attention = scan(records=[("p", dict(LEAD, role="specialist:code-reviewer"))])
assert "do not adopt it" not in text and "LIMBO SPEC-live" in attention, "a specialist owns nothing"
text, attention = scan(records=[("p", dict(LEAD, state="failed"))])
assert "do not adopt it" not in text, "an ended Lead owns nothing"
with patch.object(m, "session_records", side_effect=RuntimeError("boom")):
    assert m.bead_owners() == {}, "an unreadable store owns nothing"

# A Lead a kickoff authorized for its change also holds the Bead it moved on to.
mapped = [{"id": bead, "status": status, "labels": [f"openspec:change:{change}", "openspec:task:TASK-X-001"]}
          for bead, status, change in (("SPEC-next", "in_progress", "c1"), ("SPEC-done", "closed", "c1"),
                                       ("SPEC-else", "in_progress", "c2"), ("SPEC-mine", "in_progress", "c1"))]
WIDE = dict(LEAD, authorized_change="c1")
def owned(records=(("p", WIDE),), alive=("sf-other",), unknown=(), own=None, signal=None, issues=None):
    env = {"NOGG_SESSION_NAME": own or "sf-outsider"}
    listing = {"return_value": mapped} if issues is None else {"side_effect": issues}
    with patch.object(m, "beads", **listing), \
         patch.object(m, "session_liveness", return_value=(set(alive), set(unknown))), \
         patch.object(m.signals_module(), "current_signal", return_value=signal), \
         patch.object(m, "session_records", return_value=list(records)), patch.dict(os.environ, env):
        return m.bead_owners()
holder = owned()
assert set(holder) == {"SPEC-live", "SPEC-next", "SPEC-mine"}, holder
assert "sf-other" in holder["SPEC-next"][0], holder
assert owned(alive=()) == {}, "a dead Lead holds nothing of its change"
assert set(owned(records=(("p", LEAD),))) == {"SPEC-live"}, "no kickoff scope, only the launch Bead"
assert set(owned(signal={"event": "done"})) == {"SPEC-live"}, "a finished Lead keeps only its launch Bead"
assert owned(alive=(), unknown=("sf-other",))["SPEC-next"][1] is False, "unknown liveness stays loud"
assert owned(signal={"event": "blocked"})["SPEC-next"][1] is False, "a blocked Lead stays loud"
direct = ("r", {"name": "sf-direct", "bead_id": "SPEC-next", "state": "running", "role": "lead"})
direct_owner = owned(records=(("p", WIDE), direct), alive=("sf-other", "sf-direct"))["SPEC-next"]
assert "sf-direct" in direct_owner[0], "the Lead launched for a Bead outranks the change's holder"
sibling = ("q", {"name": "sf-me", "bead_id": "SPEC-mine", "state": "running", "role": "lead"})
assert "SPEC-mine" not in owned(records=(("p", WIDE), sibling), alive=("sf-other", "sf-me"), own="sf-me"), \
    "a caller's own Bead stays its own"
assert set(owned(own="sf-other")) == set(), "a change's holder is free to move on to its next Bead"
failed = owned(issues=RuntimeError("bd down"))
assert set(failed) == {"SPEC-live"}, "a failed Beads read keeps the launch Beads"

# A live owner's Bead cannot get a second worktree; its owner can, and an
# unreadable store refuses rather than reads as free.
def allocate(bead, own="sf-outsider", records=(("p", WIDE),), listing=None):
    env = {"NOGG_SESSION_NAME": own}
    with patch.object(m, "claimed_bead"), patch.object(m, "beads", **(listing or {"return_value": mapped})), \
         patch.object(m, "session_liveness", return_value=({"sf-other"}, set())), \
         patch.object(m.signals_module(), "current_signal", return_value=None), \
         patch.object(m, "session_records", return_value=list(records)), \
         patch.object(m, "branch_exists", return_value=True), patch.object(m, "worktree_record_path", create=True), \
         patch.object(m, "write_worktree_record") as wrote, patch.dict(os.environ, env):
        try:
            m.implementation_worktree(bead, "fix/adopted", "/nonexistent/spec-eeuv-probe")
        except RuntimeError as exc:
            assert not wrote.called, "a refusal writes nothing"
            return str(exc)
    raise AssertionError("allocation went on past its guards")
assert "refused: SPEC-live owned by session sf-other" in allocate("SPEC-live"), allocate("SPEC-live")
assert "refused: SPEC-next owned by session sf-other" in allocate("SPEC-next"), allocate("SPEC-next")
assert "branch already exists" in allocate("SPEC-next", own="sf-other"), "the holder passes the guard"
assert "branch already exists" in allocate("SPEC-else"), "another change is not held"
assert "bd down" in allocate("SPEC-else", listing={"side_effect": RuntimeError("bd down")}), "the gate fails closed"

# A failed tmux query proves nothing, for the caller that asks to know.
broken = MagicMock()
broken.live.side_effect = RuntimeError("no server")
record = {"name": "sf-other", "backend": "tmux"}
with patch.object(m, "session_backend", return_value=broken):
    assert m.session_liveness([record]) == (set(), set()), "the established rule stands"
    assert m.session_liveness([record], strict=True) == (set(), {"sf-other"})
PY

python3 - "$nogg" <<'PY' && ok "the recorded kickoff is what turns the guard on" || bad "kickoff record"
import json, os, sys, tempfile
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_swk003g", sys.argv[1]).load_module()
signals = m.signals_module()
name = "s-kicked"
path = m.sessions_dir() / f"{name}.json"
path.write_text(json.dumps({"name": name, "role": "lead", "agent": "claude", "state": "running",
                            "launch_prompt": "autonomous"}))
assert not signals.guard_applies(json.loads(path.read_text()), [])
m._write_kickoff_delivery(name, {"status": "submitted"}, sent=True)
assert signals.guard_applies(json.loads(path.read_text()), [])
PY

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
python3 - "$nogg" <<'PY' && ok "a real launch records the prompt the guard keys on" || bad "launch_prompt not recorded"
import sys
from importlib.machinery import SourceFileLoader
from unittest.mock import MagicMock, patch
m = SourceFileLoader("sf_swk003h", sys.argv[1]).load_module()

class Recorded(Exception):
    pass

def recorded(**flags):
    captured = {}
    def capture(_path, record):
        captured.update(record)
        raise Recorded()
    backend = MagicMock()
    backend.prepare.return_value = None
    with patch.object(m, "require_agent_binary"), patch.object(m, "preflight_session_helpers"), \
         patch.object(m, "bead_records", return_value=[{"labels": []}]), \
         patch.object(m, "unmet_dependencies", return_value=[]), \
         patch.object(m, "session_state_grants", return_value=[]), \
         patch.object(m, "usage_gate_admission", return_value={"decision": "disabled"}), \
         patch.object(m, "session_backend", return_value=backend), \
         patch.object(m, "tmux_sessions", return_value=set()), \
         patch.object(m, "tmux_has_session", return_value=False), \
         patch.object(m, "gen_session_name", return_value="s-recorded"), \
         patch.object(m, "write_session", side_effect=capture):
        try:
            m._session_launch("lead", "SPEC-abc", None, False, None, agent="claude", **flags)
        except Recorded:
            pass
    return captured.get("launch_prompt")

assert recorded(full_access=True) == "autonomous", recorded(full_access=True)
assert recorded(prompt="no-autonomous-claim") == "no-autonomous-claim"
PY

[[ $fail -eq 0 ]] && echo "all session-guard checks passed" || { echo "session-guard: checks failed" >&2; exit 1; }
