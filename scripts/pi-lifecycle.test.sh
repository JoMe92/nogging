#!/usr/bin/env bash
# Drives .pi/extensions/nogging-lifecycle.ts with a fake `pi` and `ctx` under
# Node type stripping, against a stub scripts/nogg that records every
# `session emit` call. Skips with a pass where node is absent or cannot strip
# types, like scripts/pi-guard.test.sh. Offline: no real Pi, herdr or network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
ext="$root/.pi/extensions/nogging-lifecycle.ts"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - skipped (node not installed)"
  echo "all pi-lifecycle checks passed"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/scripts"
# Stub nogg: one line per call, "<event>\t<stdin>"; `stuck` hangs for a minute.
cat > "$work/root/scripts/nogg" <<'STUB'
#!/usr/bin/env bash
payload=$(cat)
if [ -n "${STUB_SLEEP:-}" ]; then sleep "$STUB_SLEEP"; fi
printf '%s\t%s\t%s\n' "$3" "${NOGG_SESSION_NAME:-}" "$payload" >> "$STUB_LOG"
STUB
chmod +x "$work/root/scripts/nogg"

runner="$work/runner.mjs"
cat > "$runner" <<'NODE'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";

const [, , extPath, mode, log] = process.argv;
let mod;
try {
  mod = await import(pathToFileURL(extPath).href);
} catch (e) {
  console.log("IMPORT_FAILED: " + (e && e.message ? e.message : e));
  process.exit(2);
}
const load = mod.default;

let fail = 0;
function check(desc, cond) {
  console.log(`${cond ? "ok  " : "FAIL"} - ${desc}`);
  if (!cond) fail = 1;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function fakePi() {
  const handlers = new Map();
  return {
    handlers,
    on(event, fn) { handlers.set(event, [...(handlers.get(event) || []), fn]); return () => {}; },
    async fire(event, payload = {}, ctx = {}) {
      for (const fn of handlers.get(event) || []) await fn({ type: event, ...payload }, ctx);
    },
  };
}
const ctxWith = (text, extra = {}) => ({
  sessionManager: { getBranch: () => [
    { type: "message", message: { role: "user", content: "go" } },
    { type: "message", message: { role: "assistant", content: [{ type: "text", text }], ...extra } },
  ] },
});
async function lines(expected) {
  for (let i = 0; i < 100; i++) {
    const got = existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean) : [];
    if (got.length >= expected) return got.map((l) => l.split("\t"));
    await sleep(50);
  }
  return existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => l.split("\t")) : [];
}

if (mode === "inert") {
  const pi = fakePi();
  load(pi);
  check("inert without NOGG_SESSION_NAME: registers nothing", pi.handlers.size === 0);
  process.exit(fail);
}

if (mode === "stuck") {
  const pi = fakePi();
  load(pi);
  const started = Date.now();
  await pi.fire("session_shutdown", { reason: "quit" });
  check("a stuck child delays the handler by at most the bounded drain", Date.now() - started < 2500);
  // Exiting now must not wait for the 60s child: the harness times this run.
  process.exit(fail);
}

const pi = fakePi();
load(pi);
check("registers the five lifecycle events and the settle observer",
  ["agent_start", "agent_before_settle", "agent_settled", "ui_prompt_start", "ui_prompt_end", "session_shutdown"]
    .every((e) => pi.handlers.has(e)));
check("never registers agent_end", !pi.handlers.has("agent_end"));

const second = fakePi();
load(second);
check("a second load in the same process registers nothing", second.handlers.size === 0);

// retry after agent_end: no turn_end until agent_settled
await pi.fire("agent_start");
await pi.fire("agent_end", { messages: [] });
await pi.fire("agent_start");
let got = await lines(2);
check("agent_end then a retry emits only turn_start twice",
  got.length === 2 && got.every((l) => l[0] === "turn_start"));
await pi.fire("agent_settled", { aborted: false }, ctxWith("PR #7 is open.\nNext line"));
got = await lines(3);
check("agent_settled emits turn_end with the last assistant message",
  got[2][0] === "turn_end" && JSON.parse(got[2][2]).last_assistant_message === "PR #7 is open.\nNext line");
check("the session name reaches the child", got[2][1] === "sf-lead-test");

// error outcome: turn_error with a rate_limit kind, and no turn_end after it
await pi.fire("agent_start");
await pi.fire("agent_before_settle", { outcome: "error" },
  ctxWith("partial", { stopReason: "error", errorMessage: "429 rate limit reached" }));
await pi.fire("agent_settled", { aborted: false }, ctxWith("partial"));
got = await lines(5);
check("outcome error emits turn_error with rate_limit",
  got[4][0] === "turn_error" && JSON.parse(got[4][2]).error === "rate_limit");
await sleep(300);
got = await lines(5);
check("no turn_end follows a turn_error", got.length === 5);
await pi.fire("agent_before_settle", { outcome: "completed" }, ctxWith("fine"));
await sleep(300);
check("a completed outcome emits nothing at before_settle", (await lines(5)).length === 5);

// prompts
await pi.fire("agent_start");
await pi.fire("ui_prompt_start", { kind: "confirm" });
await pi.fire("ui_prompt_end");
got = await lines(8);
check("ui_prompt_start emits needs_input", got[6][0] === "needs_input");
check("ui_prompt_end during a run resumes turn_start", got[7][0] === "turn_start");
await pi.fire("agent_settled", { aborted: false }, ctxWith("done"));
await pi.fire("ui_prompt_start", { kind: "input" });
await pi.fire("ui_prompt_end");
got = await lines(11);
check("ui_prompt_end while idle reports turn_end, not working", got[10][0] === "turn_end");

// shutdown: reload keeps the session, quit ends it, and a reload can re-register
await pi.fire("session_shutdown", { reason: "reload" });
await sleep(300);
check("a reload shutdown emits no session_end", (await lines(11)).length === 11);
const again = fakePi();
load(again);
check("a reload allows the extension to register again", again.handlers.size > 0);
await again.fire("session_shutdown", { reason: "quit" });
got = await lines(12);
check("a quit shutdown emits session_end", got[11] && got[11][0] === "session_end");

// handler errors never reach Pi
const bad = fakePi();
delete globalThis[Symbol.for("nogging.lifecycle.loaded")];
load(bad);
let threw = false;
try { await bad.fire("agent_settled", {}, { sessionManager: { getBranch() { throw new Error("boom"); } } }); } catch { threw = true; }
check("a throwing ctx does not propagate", !threw);

process.exit(fail);
NODE

run() { # mode extra-env...
  local mode=$1; shift
  env NOGG_SESSION_NAME="${SESSION:-sf-lead-test}" NOGG_SESSION_ROOT="$work/root" STUB_LOG="$work/$mode.log" "$@" \
    node "$runner" "$ext" "$mode" "$work/$mode.log"
}

set +e
out=$(run main 2>"$work/stderr"); rc=$?
set -e
if [[ $rc -eq 2 ]]; then
  echo "ok   - skipped (node cannot load nogging-lifecycle.ts directly, e.g. too old for TypeScript type-stripping)"
  echo "all pi-lifecycle checks passed"
  exit 0
fi
echo "$out"
[[ $rc -eq 0 ]] || { cat "$work/stderr" >&2; echo "pi-lifecycle checks failed" >&2; exit 1; }

# inert: the variable is unset
out=$(env -u NOGG_SESSION_NAME NOGG_SESSION_ROOT="$work/root" STUB_LOG="$work/inert.log" node "$runner" "$ext" inert "$work/inert.log") \
  || { echo "$out"; echo "pi-lifecycle checks failed" >&2; exit 1; }
echo "$out"
if [[ -e "$work/inert.log" ]]; then echo "FAIL - inert run emitted"; exit 1; fi
echo "ok   - inert run emitted nothing"

# a stuck child cannot delay Pi's exit
start=$(date +%s)
out=$(run stuck STUB_SLEEP=60) || { echo "$out"; echo "pi-lifecycle checks failed" >&2; exit 1; }
echo "$out"
if (( $(date +%s) - start > 10 )); then echo "FAIL - exit waited for a stuck child"; exit 1; fi
echo "ok   - exit did not wait for a stuck child"

echo "all pi-lifecycle checks passed"
