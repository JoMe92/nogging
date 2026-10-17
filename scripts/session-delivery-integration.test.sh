#!/usr/bin/env bash
# TASK-RSI-008 (Decision 8): installed-consumer regression for reliable session
# input. A scratch consumer is installed from the packed package (fresh init,
# and an old install refreshed by update); the *installed* scripts/nogg then
# delivers real kickoff/send/nudge CLI invocations to Claude, Codex and
# Antigravity panes on the real tmux backend (through its patched transport)
# and the real herdr backend class over stateful fakes. The real readiness,
# composer, receipt and delivery code runs -- never the test-mode bypass --
# with a fake monotonic clock, a scratch CODEX_HOME and no real tmux server,
# herdr, bd, Dolt, sleeps or agent binaries.
set -euo pipefail
for name in $(compgen -e); do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_TMPDIR|TMUX_STUB_DIR|TMUX_STATEFUL_STUB) unset "$name" ;; esac
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/nogg.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
export CODEX_HOME="$scratch/codex"
export npm_config_cache="$scratch/npm-cache"
export HOME="$scratch/home"
mkdir -p "$CODEX_HOME" "$HOME"

packed=$(cd "$root" && npm pack --ignore-scripts --json --pack-destination "$scratch" 2>/dev/null)
filename=$(printf '%s' "$packed" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["filename"])')
printf '%s' "$packed" | python3 -c '
import json, sys
inventory = {e["path"] for e in json.load(sys.stdin)[0]["files"]}
for helper in ("nogg", "lib/session_backend.py", "lib/session_backend_tmux.py",
               "lib/session_backend_herdr.py", "lib/session_codex_delivery.py"):
    assert "scripts/" + helper in inventory, f"{helper} is not packaged"
'
tar -xzf "$scratch/$filename" -C "$scratch"
package="$scratch/package"
helpers="nogg lib/session_backend.py lib/session_backend_tmux.py lib/session_backend_herdr.py lib/session_codex_delivery.py"

install_consumer() {   # <fresh|old-install-update> -> prints the consumer directory
  local scenario=$1 consumer="$scratch/$1 consumer"
  mkdir "$consumer"
  git init -q "$consumer"
  local flags=(--no-beads --no-hooks --no-systemd)
  (cd "$consumer" && node "$package/bin/cli.js" init "${flags[@]}" >/dev/null)
  if [ "$scenario" = old-install-update ]; then
    # An install that predates the delivery helpers: the codex receipt reader and
    # the herdr backend are missing. update must restore them.
    rm "$consumer/scripts/lib/session_codex_delivery.py" "$consumer/scripts/lib/session_backend_herdr.py"
    (cd "$consumer" && node "$package/bin/cli.js" update "${flags[@]}" >/dev/null)
  fi
  for helper in $helpers; do
    cmp -s "$package/scripts/$helper" "$consumer/scripts/$helper" || { echo "FAIL: $scenario: scripts/$helper differs from the package" >&2; exit 1; }
  done
  [ -x "$consumer/scripts/nogg" ] || { echo "FAIL: $scenario: scripts/nogg is not executable" >&2; exit 1; }
  printf '%s\n' "$consumer"
}

fresh=$(install_consumer fresh)
updated=$(install_consumer old-install-update)

cat > "$scratch/harness.py" <<'PY'
import hashlib, io, json, os, re, subprocess, sys, textwrap, time as real_time
from contextlib import redirect_stderr, redirect_stdout
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

source, consumer, scratch = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
# The code under test is the installed copy, never the checkout's.
nogg = consumer / "scripts/nogg"
assert nogg.resolve() != (source / "scripts/nogg").resolve()
m = SourceFileLoader("installed_nogg", str(nogg)).load_module()
assert not m._is_legacy_mock(), "the real readiness and delivery path must run"
assert Path(m.__file__).resolve() == nogg.resolve()
backend_module = m.session_backend_module()
assert Path(backend_module.__file__).resolve().parent == (consumer / "scripts/lib").resolve(), backend_module.__file__
from session_backend_tmux import TmuxBackend
from session_backend_herdr import HerdrBackend

AGY = source / "scripts/fixtures/antigravity/1.4.0/panes"
CLAUDE = source / "scripts/fixtures/claude-panes"
HINT, WORKING = (AGY / "accept-edits-hint.txt").read_text(), (AGY / "working.txt").read_text()
RC_CONNECTING = (CLAUDE / "startup-rc-connecting.txt").read_text()
CLAUDE_READY = (CLAUDE / "startup-ready.txt").read_text()
RULE = "\x1b[38;5;244m" + "─" * 80
CODEX_READY = "\x1b[1m>_ OpenAI Codex\x1b[0m\n\n› \x1b[2mAsk Codex to do anything\x1b[0m\n\n  100% context left\n"
OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
def plain(text): return m._ANSI_RE.sub("", OSC_RE.sub("", text))
def digest(text): return hashlib.sha256(text.encode()).hexdigest()
TIMEOUT_ERRORS = ("was not ready for input", "nothing was typed")


# --- stateful runtime behind the real backend classes ------------------------
class Clock:
    def __init__(self): self.now = 0.0
    def monotonic(self): return self.now
    def sleep(self, seconds): self.now += max(seconds, 0)
    def time(self): return 1_800_000_000 + self.now

def with_composer(pane, agent, text):
    """Render typed `text` into the pane's composer like the runtime does."""
    rows = [row for line in text.split("\n") for row in (textwrap.wrap(line, 70) or [""])]
    lines = pane.splitlines()
    if agent == "antigravity":
        _l, _p, top, bottom = m._antigravity_composer_box(pane)
        body = ["\x1b[94m>\x1b[39m " + rows[0]] + ["  " + r for r in rows[1:]]
    elif agent == "claude":
        rules = [i for i, ln in enumerate(lines) if m._PROMPT_RULE_RE.match(m._ANSI_RE.sub("", ln))]
        top, bottom = rules[-2], rules[-1]
        body = ["\x1b[39m❯\xa0" + rows[0]] + ["  " + r for r in rows[1:]]
    else:   # Codex: the existing parser reads only the `›` row, so keep one row
        bottom = next(i for i, ln in enumerate(lines) if m._ANSI_RE.sub("", ln).startswith("›")) + 1
        top, body = bottom - 2, ["› " + text]
    return "\n".join(lines[:top + 1] + body + lines[bottom:]) + "\n"

AFTER_SUBMIT = {"antigravity": WORKING,
                "claude": f"{RULE}\n\x1b[39m❯\xa0\n{RULE}\n  ⏵⏵ bypass permissions on · esc to interrupt\n",
                "codex": "• Working (0s • esc to interrupt)\n\n› \n"}
PANE_ROWS = 40

class Runtime:
    """One agent pane: a timeline of base renders, typing and submission."""
    def __init__(self, agent, clock, timeline, *, status="idle", pid=4242):
        self.agent, self.clock, self.timeline = agent, clock, sorted(timeline, key=lambda e: e[0])
        self.status, self.pid, self.alive = status, pid, True
        self.text, self.submitted, self.typed, self.keys, self.hooks = None, False, [], [], []
        self.events, self.transport, self.captures = [], [], 0
    def base(self):
        for entry in list(self.hooks):
            if self.clock.now >= entry[0]:
                self.hooks.remove(entry)
                entry[1]()
        pane = ""
        for at, render in self.timeline:
            if self.clock.now >= at:
                pane = render
        return pane
    def capture(self, attributes):
        self.captures += 1
        pane = self.base()
        if self.submitted:
            pane = AFTER_SUBMIT[self.agent]
        elif self.text is not None:
            pane = with_composer(pane, self.agent, self.text)
        rows = pane.rstrip("\n").split("\n") if pane else []
        pane = "\n".join(rows + [""] * (PANE_ROWS - len(rows))) + "\n"   # capture-pane lists every row
        return pane if attributes else plain(pane)
    def type(self, text):
        self.typed.append((self.clock.now, text))
        self.events.append(("type", text))
        self.text = (self.text or "") + text
    def key(self, key):
        self.keys.append((self.clock.now, key))
        self.events.append(("key", key))
        if key == "enter" and self.text:
            self.submitted, self.status = True, "working"
        elif key == "ctrl+u" and self.text:       # kills the cursor's line, or the newline before it
            head, _, last = self.text.rpartition("\n")
            self.text = (head if not last and self.text.endswith("\n") else head + ("\n" if head and last else "")) or None
            self.text = self.text or None
        elif key == "backspace" and self.text:
            self.text = self.text[:-1] or None

def ok(stdout=""): return SimpleNamespace(returncode=0, stdout=stdout, stderr="")

def tmux_transport(rt):
    """The tmux command transport (`scripts/nogg`'s `tmux`) for one pane."""
    names = {"Enter": "enter", "C-u": "ctrl+u", "BSpace": "backspace", "Escape": "escape", "C-c": "ctrl+c"}
    buffers = {}
    def tmux(*args, check=True, stdin=None):
        op = args[0]
        if op == "list-sessions": return ok("w\n" if rt.alive else "")
        if op == "has-session": return SimpleNamespace(returncode=0 if rt.alive else 1, stdout="", stderr="")
        if op == "capture-pane": return ok(rt.capture("-e" in args))
        if op == "display-message": return ok(f"{rt.pid}\n" if rt.alive else "")
        if op == "load-buffer": buffers[args[2]] = stdin; return ok()
        if op == "paste-buffer":
            rt.transport.append("tmux paste-buffer")
            assert "-p" in args and "-r" in args and "-d" in args, args   # bracketed, LF-preserving, cleaned up
            rt.type(buffers.pop(args[args.index("-b") + 1])); return ok()
        if op == "delete-buffer": return ok()
        if op == "send-keys": rt.key(names[args[-1]]); return ok()
        raise AssertionError(args)
    return tmux

def herdr_substrate(rt):
    def run(binary, *args, check=False, timeout=None):
        args = args[2:]                                   # drop `--session <name>`
        if args[:2] == ("pane", "list"):
            return ok(json.dumps({"result": {"panes": [{"pane_id": "p1", "label": "w", "terminal_id": "t1"}]
                                             if rt.alive else []}}))
        if args[:2] == ("pane", "read"): return ok(rt.capture("ansi" in args))
        if args[:2] == ("pane", "process-info"): return ok(json.dumps({"result": {"process_info": {"shell_pid": rt.pid}}}))
        if args[:2] == ("agent", "get"):
            return ok(json.dumps({"result": {"agent": {"agent_status": rt.status}}}))
        if args[:2] == ("pane", "send-text"): rt.transport.append("herdr send-text"); rt.type(args[3]); return ok()
        if args[:2] == ("pane", "send-keys"): rt.key(args[3]); return ok()
        raise AssertionError(args)
    return HerdrBackend({"session_herdr_session": "input_ready", "session_repository_root": str(scratch)}, run)

class World:
    """A session record plus its runtime, wired into the installed scripts/nogg."""
    count = 0
    def __init__(self, backend, agent, timeline, *, status="idle", initial_turn=None, pid=4242, **fields):
        World.count += 1
        self.clock = Clock()
        self.rt = Runtime(agent, self.clock, timeline, status=status if backend == "herdr" else None)
        self.backend, self.agent = backend, agent
        self.herdr = herdr_substrate(self.rt) if backend == "herdr" else None
        self.dir = scratch / f"world-{World.count}"
        self.cfg = {**m.CFG, "session_state_dir": str(self.dir / "sessions")}
        log_path = self.dir / "w.log"
        rec = {"name": "w", "agent": agent, "role": "lead", "bead_id": "SPEC-test", "state": "running",
               "started_at": m.now(), "working_dir": str(self.dir), "backend": backend,
               "backend_ref": ({"name": "w", "socket": "nogg-input-ready-unused"} if backend == "tmux" else
                               {"label": "w", "pane_id": "p1", "terminal_id": "t1", "herdr_session": "input_ready"}),
               "session_pid": pid, "session_pid_start": "1", "session_pid_ns": "pid:[0]",
               "antigravity_initial_turn": agent == "antigravity" if initial_turn is None else initial_turn,
               "antigravity_conversation_id": None, "log_path": str(log_path), **fields}
        self.path = self.dir / "sessions" / "w.json"
        with patch.object(m, "CFG", self.cfg):
            m.write_session(m.sessions_dir() / "w.json", rec)
        log_path.write_text("")
        self.queue_calls = []
    def record(self): return json.loads(self.path.read_text())
    def stop_event(self, fully_idle=True):
        """This launch's Stop hook (a fullyIdle envelope sets antigravity_ready_at)."""
        with patch.object(m, "CFG", self.cfg):
            m.antigravity_stop_event("w", {"conversationId": "00000000-0000-4000-8000-000000000035",
                                           "workspacePaths": [str(self.dir)], "fullyIdle": fully_idle, "executionNum": 1})
    def cli(self, *argv):
        """Run `nogg session <argv>` through the installed script's own argument parser."""
        def invoke():
            with patch.object(sys, "argv", ["nogg", "session", *argv]):
                return m.main()
        return self.execute(invoke)
    def execute(self, thunk):
        stderr, stdout = io.StringIO(), io.StringIO()
        patches = [patch.object(m, "CFG", self.cfg),
                   patch.object(m, "time", SimpleNamespace(monotonic=self.clock.monotonic,
                                                            sleep=self.clock.sleep, time=self.clock.time)),
                   patch.object(m, "bead_change", return_value="reliable-session-input")]
        if self.backend == "tmux":
            patches.append(patch.object(m, "tmux", tmux_transport(self.rt)))
        else:   # herdr liveness needs its server: resolve to the fake-backed instance instead
            ref = lambda: m.record_backend_ref(self.record())
            patches += [patch.object(m, "backend_for_name", side_effect=lambda name, fallback=None: (self.herdr, ref())),
                        patch.object(m, "tmux_sessions", side_effect=lambda: {"w"} if self.rt.alive else set())]
        if self.agent == "codex":
            real_run = m.run
            def fake_run(*argv, **kw):
                if argv[:2] == ("codex", "queue"):
                    self.queue_calls.append(argv[argv.index("--message") + 1])
                    self.queue_effect(argv)
                    return SimpleNamespace(returncode=self.queue_answer[0], stdout=self.queue_answer[1],
                                           stderr=self.queue_answer[2])
                return real_run(*argv, **kw)
            patches.append(patch.object(m, "run", fake_run))
        for p in patches:
            p.start()
        try:
            with redirect_stderr(stderr), redirect_stdout(stdout):
                try:
                    return ("ok", thunk(), stdout.getvalue())
                except Exception as exc:    # what `__main__` turns into `nogg: <msg>` and exit 1
                    return ("error", str(exc), stdout.getvalue())
        finally:
            for p in reversed(patches):
                p.stop()
    queue_effect = staticmethod(lambda args: None)
    queue_answer = (0, "Queued message fake-id.\n", "")

def no_input(world):
    assert not world.rt.events, world.rt.events

def enters(world): return [k for _, k in world.rt.keys if k == "enter"]
def typed(world): return [t for _, t in world.rt.typed]

KICKOFF = m._compose_kickoff_message("SPEC-test", "reliable-session-input")
MULTILINE = "Review the diff.\nLine two has \"quotes\" and 'apostrophes'.\n  Indented ünïcode line three."
THREAD = "00000000-0000-4000-8000-0000000000bb"

def assert_delivered(world, message=KICKOFF, status="submitted"):
    """The record holds identity, never the instruction; kickoff_sent_at follows success only."""
    rec, kd = world.record(), world.record().get("kickoff_delivery")
    assert kd and kd["status"] == status and kd["message_sha256"] == digest(message), kd
    assert kd["launch"] == m._launch_identity(rec) and kd["at"], kd
    assert message not in world.path.read_text(), "the plaintext instruction must never be stored"
    assert bool(rec.get("kickoff_sent_at")) == (status == "submitted"), (status, rec.get("kickoff_sent_at"))

def drop_enter(world):
    """The runtime ignores Enter until `state['drop']` is cleared (but counts the press)."""
    state, original = {"drop": True}, world.rt.key
    def key(k):
        if state["drop"] and k == "enter":
            world.rt.keys.append((world.clock.now, k)); world.rt.events.append(("key", k))
            return
        original(k)
    world.rt.key = key
    return state

def codex_world(backend, timeline=None, **fields):
    w = World(backend, "codex", timeline or [(0, CODEX_READY)], codex_thread_id=THREAD, **fields)
    day = scratch / "codex/sessions/2026/10/17"
    day.mkdir(parents=True, exist_ok=True)
    w.transcript = day / f"rollout-2026-10-17T00-00-{World.count:02d}-{THREAD}.jsonl"
    meta = {"type": "session_meta", "payload": {"id": THREAD, "cwd": str(w.dir), "timestamp": "2026-10-17T00:00:00.000Z"}}
    w.transcript.write_text(json.dumps(meta) + "\n")
    return w

def append_user(world, text):
    record = {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                    "content": [{"type": "input_text", "text": text}]}}
    with world.transcript.open("a") as fh:
        fh.write(json.dumps(record) + "\n")

def accepted_after(world, message, delay):
    """`codex queue` accepts now; the transcript shows the user message `delay` seconds later."""
    world.queue_effect = lambda args: world.rt.hooks.append((world.clock.now + delay, lambda: append_user(world, message)))

def expect(result, outcome, needle=None):
    assert result[0] == outcome and (needle is None or needle in str(result[1]) + result[2]), result
    return result

for backend in ("tmux", "herdr"):
    # --- Backend selection: the record picks the substrate and its transport ---------------
    probe = World(backend, "claude", [(0, CLAUDE_READY)])
    with patch.object(m, "CFG", probe.cfg):
        chosen, _ref = m.backend_for_record(probe.record())
    assert type(chosen).__name__ == {"tmux": "TmuxBackend", "herdr": "HerdrBackend"}[backend], chosen
    expect(probe.cli("send", "w", MULTILINE), "ok")
    assert probe.rt.transport == [{"tmux": "tmux paste-buffer", "herdr": "herdr send-text"}[backend]], probe.rt.transport

    # --- Slow startup: nothing is typed before the runtime shows a ready composer ------------
    w = World(backend, "claude", [(0, RC_CONNECTING), (3, CLAUDE_READY)])
    expect(w.cli("kickoff", "w"), "ok")
    assert typed(w) == [KICKOFF] and w.rt.typed[0][0] >= 3 and len(enters(w)) == 1, (w.rt.typed, w.rt.keys)
    assert_delivered(w)

    w = World(backend, "antigravity", [(0, HINT), (0.3, WORKING), (45, HINT)], status="working")
    w.rt.hooks += [(45, w.stop_event), (45, lambda w=w: setattr(w.rt, "status", "idle"))]
    expect(w.cli("kickoff", "w"), "ok")                     # a start past the old fixed 30-second wait
    assert typed(w) == [KICKOFF] and w.rt.typed[0][0] >= 45 and len(enters(w)) == 1
    assert_delivered(w)
    rec = w.record()
    assert rec["antigravity_conversation_id"] and rec["input_ready_source"] == "stop", rec

    w = codex_world(backend, [(0, ""), (8, CODEX_READY)])   # Codex: queue only once its composer is ready
    accepted_after(w, KICKOFF, 4)
    seen, deliver = [], w.queue_effect
    w.queue_effect = lambda args: (seen.append(w.clock.now), deliver(args))
    expect(w.cli("kickoff", "w"), "ok")
    assert w.queue_calls == [KICKOFF] and seen and seen[0] >= 8 and not w.rt.typed and not w.rt.keys, (seen, w.rt.events)
    assert_delivered(w)

    # --- Readiness that never arrives fails the call with nothing typed and no marker --------
    for agent in ("claude", "antigravity", "codex"):
        w = (codex_world(backend, [(0, "")]) if agent == "codex" else World(backend, agent, [(0, "")]))
        w.cfg["session_startup_timeout_seconds"] = 20
        expect(w.cli("kickoff", "w"), "error", "was not ready for input within 20s")
        no_input(w)
        assert not w.queue_calls and "kickoff_delivery" not in w.record() and not w.record().get("kickoff_sent_at")

    # --- Multiline input reaches every agent exactly once, with one Enter ---------------------
    for agent in ("claude", "antigravity"):
        w = World(backend, agent, [(0, CLAUDE_READY if agent == "claude" else HINT)], initial_turn=False)
        expect(w.cli("send", "w", MULTILINE), "ok")
        assert typed(w) == [MULTILINE] and len(enters(w)) == 1 and w.rt.events[-1] == ("key", "enter"), w.rt.events
    w = codex_world(backend)
    accepted_after(w, MULTILINE, 1)
    expect(w.cli("send", "w", MULTILINE), "ok")
    assert w.queue_calls == [MULTILINE] and not w.rt.typed and not w.rt.keys

    # --- A queued operator draft is never overwritten by send; nudge replaces it (HSS) -------
    DRAFT = "operator draft line one\noperator draft line two\nthird half-typed li"
    for agent in ("claude", "antigravity"):
        w = World(backend, agent, [(0, CLAUDE_READY if agent == "claude" else HINT)], initial_turn=False)
        w.rt.text = DRAFT
        expect(w.cli("send", "w", MULTILINE), "error", "nothing was typed or submitted")
        no_input(w)
        assert w.rt.text == DRAFT, "send must leave the operator's draft untouched"
        expect(w.cli("nudge", "w"), "ok", "nothing to nudge")          # multiline draft: never resent blindly
        no_input(w)
        expect(w.cli("nudge", "w", "--message", MULTILINE), "ok")      # explicit replacement
        assert typed(w) == [MULTILINE] and len(enters(w)) == 1, w.rt.events
        first_type = next(i for i, (kind, _) in enumerate(w.rt.events) if kind == "type")
        clears = [k for kind, k in w.rt.events[:first_type] if kind == "key"]
        assert clears and set(clears) <= {"ctrl+u", "backspace"}, w.rt.events   # bounded clear, then one paste
        assert w.rt.events[first_type + 1:] == [("key", "enter")], w.rt.events
        assert w.rt.submitted and DRAFT not in (w.rt.text or ""), w.rt.text

    w = World(backend, "codex", [(0, CODEX_READY)])                 # Codex pane fallback (no thread id)
    w.rt.text = "operator draft"
    expect(w.cli("send", "w", "replacement"), "error", "nothing was typed or submitted")
    no_input(w)
    expect(w.cli("nudge", "w", "--message", "replacement"), "ok")
    assert typed(w) == ["replacement"] and len(enters(w)) == 1 and w.rt.submitted, w.rt.events

    # --- Failure propagation: unsubmitted input fails loudly and is never typed twice --------
    w = World(backend, "claude", [(0, CLAUDE_READY)])
    enter = drop_enter(w)
    expect(w.cli("kickoff", "w"), "error")
    assert typed(w) == [KICKOFF]
    assert_delivered(w, status="unverified")
    presses = len(enters(w))
    assert presses >= 1
    enter["drop"] = False
    expect(w.cli("kickoff", "w"), "ok")                             # the repeat only presses Enter on the owned text
    assert typed(w) == [KICKOFF] and len(enters(w)) == presses + 1, w.rt.events
    assert_delivered(w)
    expect(w.cli("kickoff", "w"), "ok", "already sent")             # confirmed: a no-op
    assert typed(w) == [KICKOFF] and len(enters(w)) == presses + 1

    w = World(backend, "claude", [(0, CLAUDE_READY)])
    w.rt.alive = False                                               # the session vanished
    expect(w.cli("send", "w", MULTILINE), "error", "no live tmux session")
    expect(w.cli("kickoff", "w"), "error", "not running")
    expect(w.cli("nudge", "w", "--message", MULTILINE), "error", "not running")
    no_input(w)

    # --- Codex: accepted but unconfirmed is never queued or typed again ---------------------
    w = codex_world(backend)
    expect(w.cli("kickoff", "w"), "error", "accepted the queued message")
    assert w.queue_calls == [KICKOFF] and not w.rt.typed and not w.rt.keys
    assert_delivered(w, status="unverified")
    expect(w.cli("kickoff", "w"), "error", "already attempted (unverified)")
    assert w.queue_calls == [KICKOFF] and not w.rt.typed and not w.rt.keys
    append_user(w, KICKOFF)                                          # the receipt finally arrives
    expect(w.cli("kickoff", "w"), "ok")
    assert w.queue_calls == [KICKOFF] and not w.rt.typed and not w.rt.keys
    assert_delivered(w)
    expect(w.cli("kickoff", "w"), "ok", "already sent")
    assert w.queue_calls == [KICKOFF]

    # --- Repeated and concurrent kickoffs deliver once ---------------------------------------
    for agent in ("claude", "antigravity"):
        w = World(backend, agent, [(0, CLAUDE_READY if agent == "claude" else HINT)], initial_turn=False)
        rival = []
        def contend(w=w, rival=rival):
            saved = w.clock.now                  # the contender spins on the fake clock; restore it
            rival.append(w.cli("kickoff", "w"))
            w.clock.now = saved
        w.rt.hooks.append((0, contend))
        expect(w.cli("kickoff", "w"), "ok")
        assert rival and rival[0][0] == "error" and "another kickoff is still in progress" in rival[0][1], rival
        for _ in range(3):
            expect(w.cli("kickoff", "w"), "ok", "already sent")
        assert typed(w) == [KICKOFF] and len(enters(w)) == 1, w.rt.events
        assert_delivered(w)

    # --- Pi keeps its direct delivery: no readiness wait, no composer inspection -------------
    w = World(backend, "pi", [(0, "")])
    expect(w.cli("kickoff", "w"), "ok")
    assert typed(w) == [KICKOFF] and len(enters(w)) == 1 and w.rt.captures == 0, (w.rt.events, w.rt.captures)
    assert_delivered(w)
    expect(w.cli("send", "w", MULTILINE), "ok")
    assert typed(w) == [KICKOFF, MULTILINE] and len(enters(w)) == 2 and w.rt.captures == 0

# A session that does not exist fails the real process with a non-zero exit and a nogg: diagnostic.
env = {k: v for k, v in os.environ.items() if not k.startswith(("NOGG_", "NOGGING_", "HERDR_", "TMUX"))}
for argv in (["send", "no-such-session", "hello\nworld"], ["kickoff", "no-such-session"], ["nudge", "no-such-session"]):
    done = subprocess.run([str(nogg), "session", *argv], cwd=consumer, env=env, capture_output=True, text=True, timeout=60)
    assert done.returncode == 1 and done.stderr.startswith("nogg: ") and "hello" not in done.stderr, (argv, done)

print(f"session delivery integration ({consumer.name}): ok")
PY

for consumer in "$fresh" "$updated"; do
  python3 "$scratch/harness.py" "$root" "$consumer" "$scratch"
done
echo "session delivery integration: fresh init and updated install passed"
