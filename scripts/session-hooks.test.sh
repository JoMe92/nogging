#!/usr/bin/env bash
# TASK-SWK-003 (openspec/changes/session-wake): `session-hooks` for Codex's user
# Stop hook, against a stub app-server that keeps Codex's probed behaviour: keys
# by position, trust by hash. Offline, with a scratch HOME and CODEX_HOME.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

while IFS= read -r inherited; do
  case "$inherited" in
    NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_*) unset "$inherited" ;;
  esac
done < <(compgen -e)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export HOME="$work/home" CODEX_HOME="$work/codex"
mkdir -p "$HOME" "$CODEX_HOME" "$work/bin"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
expect() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected: $2, got: $3)"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1 (missing: $2, got: $3)"; fi; }

root="$work/root"
mkdir -p "$root/.nogging/state" "$root/scripts"
git init -q "$root"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
export NOGGING_ROOT="$root"

# A stub `codex`: speaks the app-server's line protocol, keeps trust in trust.json.
cat > "$work/bin/codex" <<'STUB'
#!/usr/bin/env python3
import hashlib, json, os, sys
home = os.environ["CODEX_HOME"]
if sys.argv[1:] == ["--version"]:
    print("codex-cli 0.0-stub"); sys.exit(0)
if sys.argv[1:] != ["app-server"]:
    sys.exit(0)
if os.environ.get("STUB_APP_SERVER") == "dead":
    sys.exit(1)
trust_path = os.path.join(home, "trust.json")
hooks_path = os.path.join(home, "hooks.json")
def trust_state():
    return json.load(open(trust_path)) if os.path.exists(trust_path) else {}
def listing():
    doc = json.load(open(hooks_path)) if os.path.exists(hooks_path) else {}
    state, hooks = trust_state(), []
    for event, groups in doc.get("hooks", {}).items():
        for g, group in enumerate(groups):
            for h, handler in enumerate(group.get("hooks", [])):
                key = f"{hooks_path}:{event.lower()}:{g}:{h}"
                digest = "sha256:" + hashlib.sha256(json.dumps(handler, sort_keys=True).encode()).hexdigest()
                known = state.get(key)
                status = "untrusted" if known is None else ("trusted" if known == digest else "modified")
                hooks.append({"key": key, "eventName": event.lower(), "handlerType": "command",
                              "command": handler.get("command"), "async": False,
                              "timeoutSec": handler.get("timeout", 600), "sourcePath": hooks_path, "source": "user",
                              "enabled": True, "isManaged": False, "currentHash": digest, "trustStatus": status})
    return {"data": [{"cwd": home, "hooks": hooks, "warnings": [], "errors": []}]}
for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    method, params = message["method"], message.get("params") or {}
    with open(os.path.join(home, "calls.log"), "a") as log:
        log.write(method + "\n")
    if os.environ.get("STUB_APP_SERVER") == "silent" and method != "initialize":
        continue
    if method == "hooks/list":
        result = listing()
    elif method == "config/value/write":
        key = json.loads(params["keyPath"][len("hooks.state."):])
        state = trust_state()
        if params["value"] is None:
            state.pop(key, None)
        else:
            state[key] = params["value"]["trusted_hash"]
        json.dump(state, open(trust_path, "w"))
        result = {"status": "ok"}
    else:
        result = {}
    print(json.dumps({"id": message["id"], "result": result}), flush=True)
STUB
chmod +x "$work/bin/codex"
export PATH="$work/bin:$PATH"

status() { "$nogg" session-hooks status --agent codex; }
install() { "$nogg" session-hooks install --agent codex; }
remove() { "$nogg" session-hooks remove --agent codex; }
state() { "$nogg" session-hooks status --agent codex | sed -n 's/^codex stop hook: \([a-z]*\).*/\1/p'; }
hooks_py() { python3 -c "
import json, os, sys
doc = json.load(open(os.path.join(os.environ['CODEX_HOME'], 'hooks.json')))
$1"; }

# --- unit tests of the pure module ----------------------------------------------
if [[ -f "$here/lib/session_hooks_test.py" ]]; then
  python3 "$here/lib/session_hooks_test.py" >"$work/unit.out" 2>&1 && ok "session_hooks_test.py" \
    || { bad "session_hooks_test.py"; cat "$work/unit.out"; }
else
  ok "session_hooks_test.py skipped (installed consumer copy)"
fi

# --- status reads without changing anything --------------------------------------
expect "no file is missing" missing "$(state)"
[[ ! -e "$CODEX_HOME/hooks.json" ]] && ok "status writes nothing" || bad "status created hooks.json"
[[ ! -e "$CODEX_HOME/calls.log" ]] && ok "a missing hook needs no app-server" || bad "app-server started for nothing"
has "missing names the fix" "session-hooks install --agent codex" "$(status)"

# --- a foreign hook survives the install -----------------------------------------
cat > "$CODEX_HOME/hooks.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "bash '/x/herdr-agent-state.sh' sess ünï"}]}
    ]
  },
  "other": {"kept": true}
}
JSON
chmod 640 "$CODEX_HOME/hooks.json"
hooks_py "print(json.dumps(doc['hooks']['SessionStart'], ensure_ascii=False))" > "$work/foreign.before"
out=$(install)
has "install prints what it trusted" "sha256:" "$out"
has "install prints the command" "session emit turn_end --guard --runtime codex" "$out"
hooks_py "print(json.dumps(doc['hooks']['SessionStart'], ensure_ascii=False))" > "$work/foreign.after"
cmp -s "$work/foreign.before" "$work/foreign.after" && ok "the foreign entry is byte-equivalent" || bad "the foreign entry changed"
expect "unrelated top-level keys stay" True "$(hooks_py "print(doc['other']['kept'])")"
expect "only one Stop entry is added" 1 "$(hooks_py "print(len(doc['hooks']['Stop']))")"
expect "the mode is not widened" 640 "$(stat -c %a "$CODEX_HOME/hooks.json")"
expect "the install is trusted, as Codex reads it back" trusted "$(state)"
grep -q 'config/value/write' "$CODEX_HOME/calls.log" && ok "trust goes through config/value/write" || bad "no config write"
ls -A "$CODEX_HOME" | grep -q '^\.nogging' && bad "a temporary or lock file was left" || ok "no temporary or lock file is left"

hash_before=$(sha256sum "$CODEX_HOME/hooks.json")
out=$(install)
expect "a second install changes nothing" "$hash_before" "$(sha256sum "$CODEX_HOME/hooks.json")"
expect "a second install stays trusted" trusted "$(state)"

# --- the hook is inert outside Nogging and constant across repositories ----------
command=$(hooks_py "print(doc['hooks']['Stop'][0]['hooks'][0]['command'])")
rc=0; out=$(env -u NOGG_SESSION_NAME -u NOGG_SESSION_ROOT sh -c "$command" </dev/null 2>&1) || rc=$?
expect "the hook exits 0 outside a session" 0 "$rc"
expect "the hook prints nothing outside a session" "" "$out"
[[ "$command" != *"$root"* && "$command" != *"$HOME"* ]] && ok "the command names no path" || bad "command: $command"

# --- modified --------------------------------------------------------------------
cp "$CODEX_HOME/hooks.json" "$work/hooks.good"
python3 - <<'PY'
import json, os
path = os.path.join(os.environ["CODEX_HOME"], "hooks.json")
doc = json.load(open(path))
doc["hooks"]["Stop"][0]["hooks"][0]["command"] += "; curl attacker"
json.dump(doc, open(path, "w"))
PY
expect "an edited hook is modified" modified "$(state)"
has "modified names the fix" "session-hooks install --agent codex" "$(status)"
rc=0; status >/dev/null || rc=$?
expect "status never fails" 0 "$rc"
install >/dev/null
expect "install restores the constant hook" trusted "$(state)"
expect "install restored it in place" 1 "$(hooks_py "print(len(doc['hooks']['Stop']))")"

# --- untrusted, and refusal to trust anything else --------------------------------
python3 -c "
import json, os
open(os.path.join(os.environ['CODEX_HOME'], 'trust.json'), 'w').write('{}')"
expect "a hook with no trust record is untrusted" untrusted "$(state)"
install >/dev/null
expect "install records trust again" trusted "$(state)"

# --- status and install when Codex cannot answer -----------------------------------
rc=0; out=$(STUB_APP_SERVER=dead "$nogg" session-hooks status --agent codex) || rc=$?
expect "status survives a dead app-server" 0 "$rc"
has "a dead app-server is unknown, never a guess" "unknown" "$out"
start=$SECONDS
rc=0; out=$(STUB_APP_SERVER=silent NOGG_CODEX_APP_SERVER_TIMEOUT=1 "$nogg" session-hooks status --agent codex) || rc=$?
expect "status survives a silent app-server" 0 "$rc"
(( SECONDS - start < 8 )) && ok "a silent app-server is bounded" || bad "a silent app-server took $((SECONDS - start))s"

cp "$CODEX_HOME/hooks.json" "$work/hooks.before-dead"
rc=0; out=$(STUB_APP_SERVER=dead "$nogg" session-hooks install --agent codex 2>&1) || rc=$?
expect "install fails without an app-server" 1 "$rc"
cmp -s "$CODEX_HOME/hooks.json" "$work/hooks.before-dead" && ok "a failed install writes nothing" || bad "a failed install wrote"

# --- remove reverses both, and leaves every other hook's trust alone --------------
out=$(remove)
expect "remove reports missing" missing "$(state)"
expect "the Stop key is gone" False "$(hooks_py "print('Stop' in doc['hooks'])")"
hooks_py "print(json.dumps(doc['hooks']['SessionStart'], ensure_ascii=False))" > "$work/foreign.after"
cmp -s "$work/foreign.before" "$work/foreign.after" && ok "remove leaves the foreign entry" || bad "remove changed the foreign entry"
expect "remove clears the trust record" "{}" "$(cat "$CODEX_HOME/trust.json")"
out=$(remove)
has "a second remove says so" "nothing to remove" "$out"

python3 - <<'PY'
import json, os
path = os.path.join(os.environ["CODEX_HOME"], "hooks.json")
doc = json.load(open(path))
doc["hooks"]["Stop"] = [{"hooks": [{"type": "command", "command": "echo first"}]}]
json.dump(doc, open(path, "w"))
PY
install >/dev/null
python3 - <<'PY'
import json, os
path = os.path.join(os.environ["CODEX_HOME"], "hooks.json")
doc = json.load(open(path))
doc["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "echo after"}]})
json.dump(doc, open(path, "w"))
PY
python3 - <<'PY'
import hashlib, json, os
home = os.environ["CODEX_HOME"]
handler = {"type": "command", "command": "echo after"}
state = json.load(open(os.path.join(home, "trust.json")))
state[os.path.join(home, "hooks.json") + ":stop:2:0"] = "sha256:" + hashlib.sha256(json.dumps(handler, sort_keys=True).encode()).hexdigest()
json.dump(state, open(os.path.join(home, "trust.json"), "w"))
PY
remove >/dev/null
expect "a later hook keeps its position, so its trust" "echo after" \
  "$(hooks_py "print(doc['hooks']['Stop'][2]['hooks'][0]['command'])")"
expect "the earlier hook stays" "echo first" "$(hooks_py "print(doc['hooks']['Stop'][0]['hooks'][0]['command'])")"
expect "only the Nogging slot is emptied" "[]" "$(hooks_py "print(doc['hooks']['Stop'][1]['hooks'])")"

# --- refusals ---------------------------------------------------------------------
printf 'not json' > "$CODEX_HOME/hooks.json"
rc=0; out=$(install 2>&1) || rc=$?
expect "a malformed file is refused" 1 "$rc"
expect "a malformed file is left alone" "not json" "$(cat "$CODEX_HOME/hooks.json")"
rc=0; out=$(status) || rc=$?
expect "status still does not fail on a malformed file" 0 "$rc"
has "a malformed file is reported unknown" "unknown" "$out"

mv "$CODEX_HOME/hooks.json" "$work/real.json"
printf '{}\n' > "$work/real.json"
ln -s "$work/real.json" "$CODEX_HOME/hooks.json"
rc=0; out=$(install 2>&1) || rc=$?
expect "a symlinked file is refused" 1 "$rc"
[[ -L "$CODEX_HOME/hooks.json" ]] && ok "the symlink is left alone" || bad "the symlink was replaced"
rm "$CODEX_HOME/hooks.json"

rc=0; out=$("$nogg" session-hooks status --agent claude 2>&1) || rc=$?
[[ $rc -ne 0 ]] && ok "only --agent codex is accepted" || bad "accepted --agent claude"

# --- doctor reports and never fails ------------------------------------------------
out=$("$nogg" doctor 2>&1 || true)
has "doctor reports a missing hook" "codex stop hook: missing" "$out"
has "doctor names the fix" "session-hooks install --agent codex" "$out"

# --- init and update never install ; no launch bypasses trust -----------------------
if [[ -f "$repo_root/bin/cli.js" ]]; then
  grep -rq "session-hooks" "$repo_root/bin" && bad "the installer mentions session-hooks" || ok "init and update never install the hook"
else
  ok "installer check skipped (installed consumer copy)"
fi
for file in "$here/session-launch" "$nogg"; do
  grep -vE '^\s*#' "$file" | grep -q -- '--dangerously-bypass-hook-trust' \
    && bad "$(basename "$file") passes the trust bypass" || ok "$(basename "$file") never passes the trust bypass"
done
mkdir -p "$work/argv" "$work/launch"
git -C "$work/launch" init -q
cat > "$work/argv/codex" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --help) echo "usage" ;;
  *) printf '%s\n' "$@" > "$ARGV_LOG" ;;
esac
STUB
chmod +x "$work/argv/codex"
printf 'prompt\n' > "$work/prompt.md"
ARGV_LOG="$work/argv.log" PATH="$work/argv:$PATH" "$here/session-launch" --agent codex --sandbox workspace-write \
  --approval never --network on --writable-roots '[]' --prompt "$work/prompt.md" --cwd "$work/launch" --bead SPEC-abc >/dev/null 2>&1
[[ -s "$work/argv.log" ]] && ok "a Codex launch reached the stub" || bad "no Codex argv captured"
grep -q -- '--dangerously-bypass-hook-trust' "$work/argv.log" && bad "a launch passed the bypass" || ok "a launch's argv has no trust bypass"

[[ $fail -eq 0 ]] && echo "all session-hooks checks passed" || { echo "session-hooks: checks failed" >&2; exit 1; }
