#!/usr/bin/env bash
# TASK-RSI-002 (Decision 3): validated timing keys and bounded startup readiness.
# The real readiness, composer classification and delivery code runs against
# the real tmux backend (through its patched transport, so liveness and backend
# resolution are real too) and the real herdr backend class over a stateful
# fake, with a fake monotonic clock. Panes are real Antigravity 1.4.0 / Claude
# Code 2.1.302 captures (scripts/fixtures/antigravity/1.4.0/panes,
# claude-panes/startup-*), padded to a full pane height as capture-pane returns
# them. No test-mode bypass, real tmux server, bd or Dolt is involved.
set -euo pipefail
for name in $(compgen -e); do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_TMPDIR|TMUX_STUB_DIR|TMUX_STATEFUL_STUB) unset "$name" ;; esac
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/codex"
export CODEX_HOME="$scratch/codex"
python3 - "$root" "$scratch" <<'PY'
import io, json, re, signal, sys, textwrap, time as real_time
from contextlib import redirect_stderr, redirect_stdout
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

root, scratch = Path(sys.argv[1]), Path(sys.argv[2])
m = SourceFileLoader("session_input_ready", str(root / "scripts/nogg")).load_module()
assert not m._is_legacy_mock(), "the real readiness and delivery path must run"
backend_module = m.session_backend_module()
from session_backend_tmux import TmuxBackend
from session_backend_herdr import HerdrBackend

AGY = root / "scripts/fixtures/antigravity/1.4.0/panes"
CLAUDE = root / "scripts/fixtures/claude-panes"
def agy(name): return (AGY / f"{name}.txt").read_text()
HINT, PLAN_HINT, TYPED, PANEL = agy("accept-edits-hint"), agy("plan-hint"), agy("typed-input"), agy("task-panel")
WORKING, SURVEY, TRUST = agy("working"), agy("feedback-prompt"), agy("trust-dialog")
RC_CONNECTING = (CLAUDE / "startup-rc-connecting.txt").read_text()
CLAUDE_READY = (CLAUDE / "startup-ready.txt").read_text()
RULE = "\x1b[38;5;244m" + "─" * 80
CLAUDE_PERMISSION = "Bash command\n\n  rm build\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"
CODEX_TRUST = "Do you trust the hooks in this project?\n› 1. Trust\n  2. Quit\n"
CODEX_READY = "\x1b[1m>_ OpenAI Codex\x1b[0m\n\n› \x1b[2mAsk Codex to do anything\x1b[0m\n\n  100% context left\n"
# The idle composer agy draws for a moment before its startup turn starts.
PRE_TURN = HINT
OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
def plain(text): return m._ANSI_RE.sub("", OSC_RE.sub("", text))

# --- real captures classify as the runtime means them ------------------------
for pane, kind in ((HINT, "placeholder"), (PLAN_HINT, "placeholder"), (PANEL, "empty"),
                   (WORKING, "empty"), (SURVEY, "unknown"), (TRUST, "unknown")):
    assert m._antigravity_composer_input(pane)[0] == kind, (kind, m._antigravity_composer_input(pane))
assert m._antigravity_composer_input(TYPED) == ("input", "hello world 123")
assert m._antigravity_prompt_box_text(plain(HINT)) == "" and m._antigravity_prompt_box_text(plain(PANEL)) == ""
assert m._antigravity_prompt_box_text(plain(TYPED)) == "hello world 123"
assert m._antigravity_feedback_prompt(SURVEY) and m._antigravity_feedback_prompt(plain(SURVEY))
assert not any(m._antigravity_feedback_prompt(p) for p in (HINT, PANEL, WORKING, TRUST, TYPED))
assert m.classify(plain(WORKING), m.ANTIGRAVITY_ADAPTER) == "working"      # 1.4.0 spins `Working...`
assert m.classify(plain(SURVEY), m.ANTIGRAVITY_ADAPTER) == "idle"          # why the survey needs its own check
assert m.classify(plain(TRUST), m.ANTIGRAVITY_ADAPTER) == "needs_input"
assert m.classify(plain(HINT), m.ANTIGRAVITY_ADAPTER) == "idle"
for pane in (RC_CONNECTING, CLAUDE_READY):
    assert m._claude_prompt_input(pane)[0] == "placeholder"
assert any(m._CLAUDE_STARTING_RE.search(ln) for ln in plain(RC_CONNECTING).splitlines())
assert not any(m._CLAUDE_STARTING_RE.search(ln) for ln in plain(CLAUDE_READY).splitlines())
# Gray text that is not the known mode hint, alone or mixed, is unknown: never
# input, and never the empty composer that would confirm a submission.
def agy_box(row): return "\x1b[90m" + "─" * 40 + f"\n\x1b[94m>\x1b[39m {row}\n\x1b[90m" + "─" * 40 + "\n? for shortcuts\n"
assert m._antigravity_composer_input(agy_box("\x1b[90mgray\x1b[39m typed"))[0] == "unknown"
assert m._antigravity_composer_input(agy_box("\x1b[90mqueued message\x1b[39m"))[0] == "unknown"
assert m._antigravity_composer_input(agy_box("\x1b[2mdim suggestion\x1b[0m"))[0] == "placeholder"
# A wrapped two-row footer still leaves the composer identifiable; anything
# longer below the last rule (the survey's rows) is no composer.
wrapped = HINT.replace(" · Gemini 3.8 Flash · low", "\n  Gemini 3.8 Flash · low")
assert m._antigravity_composer_input(wrapped)[0] == "placeholder"
assert m._antigravity_composer_box(plain(HINT) + "\nunframed overlay text\nmore text\n") is None

# --- stateful runtime behind the real backend classes ------------------------
class Clock:
    def __init__(self): self.now = 0.0
    def monotonic(self): return self.now
    def sleep(self, seconds): self.now += max(seconds, 0)
    def time(self): return 1_800_000_000 + self.now

def with_composer(pane, agent, text):
    """Render typed `text` into the pane's composer like the runtime does."""
    rows = textwrap.wrap(text, 70) or [""]
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
        self.captures, self.hang, self.fail_reads = 0, set(), 0
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
    def stall(self, what):
        if what in self.hang:
            real_time.sleep(5)
    def capture(self, attributes):
        self.stall("capture")
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
        self.text = (self.text or "") + text
    def key(self, key):
        self.keys.append((self.clock.now, key))
        if key == "enter" and self.text:
            self.submitted, self.status = True, "working"
        elif key in ("ctrl+u", "backspace"):
            self.text = None

def ok(stdout=""): return SimpleNamespace(returncode=0, stdout=stdout, stderr="")

def tmux_transport(rt):
    """The tmux command transport (`scripts/nogg`'s `tmux`) for one pane."""
    names = {"Enter": "enter", "C-u": "ctrl+u", "BSpace": "backspace", "Escape": "escape", "C-c": "ctrl+c"}
    buffers = {}
    def tmux(*args, check=True, stdin=None):
        op = args[0]
        if op == "list-sessions": rt.stall("list"); return ok("w\n" if rt.alive else "")
        if op == "has-session": return SimpleNamespace(returncode=0 if rt.alive else 1, stdout="", stderr="")
        if op == "capture-pane": return ok(rt.capture("-e" in args))
        if op == "display-message": rt.stall("pid"); return ok(f"{rt.pid}\n" if rt.alive else "")
        if op == "load-buffer": buffers[args[2]] = stdin; return ok()
        if op == "paste-buffer": rt.type(buffers.pop(args[args.index("-b") + 1])); return ok()
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
        if args[:2] == ("pane", "read"):
            if rt.fail_reads:
                rt.fail_reads -= 1
                raise m.subprocess.TimeoutExpired(binary, timeout)
            return ok(rt.capture("ansi" in args))
        if args[:2] == ("pane", "process-info"): return ok(json.dumps({"result": {"process_info": {"shell_pid": rt.pid}}}))
        if args[:2] == ("agent", "get"):
            rt.stall("status")
            return ok(json.dumps({"result": {"agent": {"agent_status": rt.status}}}))
        if args[:2] == ("pane", "send-text"): rt.type(args[3]); return ok()
        if args[:2] == ("pane", "send-keys"): rt.key(args[3]); return ok()
        raise AssertionError(args)
    return HerdrBackend({"session_herdr_session": "input_ready", "session_repository_root": str(scratch)}, run)

class World:
    """A session record plus its runtime, wired into scripts/nogg."""
    count = 0
    def __init__(self, backend, agent, timeline, *, status="idle", initial_turn=None, pid=4242,
                 log="", attributes=True, **fields):
        World.count += 1
        self.clock = Clock()
        self.rt = Runtime(agent, self.clock, timeline, status=status if backend == "herdr" else None)
        self.backend, self.agent, self.attributes = backend, agent, attributes
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
        log_path.write_text(log)
    def record(self): return json.loads(self.path.read_text())
    def stop_event(self, fully_idle=True):
        """This launch's Stop hook (a fullyIdle envelope sets antigravity_ready_at)."""
        conversation = "00000000-0000-4000-8000-000000000035"
        with patch.object(m, "CFG", self.cfg):
            m.antigravity_stop_event("w", {"conversationId": conversation, "workspacePaths": [str(self.dir)],
                                           "fullyIdle": fully_idle, "executionNum": 1})
    def run(self, fn, *args, **kwargs):
        stderr = io.StringIO()
        patches = [patch.object(m, "CFG", self.cfg),
                   patch.object(m, "time", SimpleNamespace(monotonic=self.clock.monotonic,
                                                            sleep=self.clock.sleep, time=self.clock.time)),
                   patch.object(m, "bead_change", return_value="reliable-session-input")]
        if self.backend == "tmux":
            patches.append(patch.object(m, "tmux", tmux_transport(self.rt)))
            if not self.attributes:
                patches.append(patch.object(TmuxBackend, "capabilities",
                                            backend_module.Capabilities(capture_attributes=False)))
        else:   # herdr liveness needs its server: resolve to the fake-backed instance instead
            ref = lambda: m.record_backend_ref(self.record())
            patches += [patch.object(m, "backend_for_name", side_effect=lambda name, fallback=None: (self.herdr, ref())),
                        patch.object(m, "tmux_sessions", side_effect=lambda: {"w"} if self.rt.alive else set())]
        for p in patches:
            p.start()
        try:
            with redirect_stderr(stderr), redirect_stdout(io.StringIO()):
                try:
                    return ("ok", fn("w", *args, **kwargs), stderr.getvalue())
                except RuntimeError as exc:
                    return ("error", str(exc), stderr.getvalue())
        finally:
            for p in reversed(patches):
                p.stop()

def no_input(world):
    assert not world.rt.typed and not world.rt.keys, (world.rt.typed, world.rt.keys)

KICKOFF = m._compose_kickoff_message("SPEC-test", "reliable-session-input")
TURN_LOG = "\x1b[?25l\r\x1b[3A⣾  \x1b[90mGenerating\x1b[94m...\x1b[m\r\n"

for backend in ("tmux", "herdr"):
    # Antigravity's first turn ends after thirty seconds: kickoff waits and sends once.
    w = World(backend, "antigravity", [(0, PRE_TURN), (0.3, WORKING), (35, HINT)], status="working")
    w.rt.hooks.append((35, w.stop_event))
    w.rt.hooks.append((35, lambda w=w: setattr(w.rt, "status", "idle")))
    outcome, value, err = w.run(m.session_kickoff)
    assert outcome == "ok", (backend, value)
    assert w.rt.typed and w.rt.typed[0][0] >= 35, w.rt.typed
    assert [text for _, text in w.rt.typed] == [KICKOFF], w.rt.typed
    assert [k for _, k in w.rt.keys] == ["enter"], w.rt.keys
    rec = w.record()
    assert rec["input_ready_source"] == "stop" and rec["input_ready_at"] and rec["kickoff_sent_at"]
    assert "waiting for Antigravity to be ready for input" in err
    assert len(err.strip().splitlines()) <= 35 / m.READINESS_NOTE_SECONDS + 1, err
    outcome, value, _ = w.run(m.session_kickoff)                     # a repeat never types again
    assert outcome == "ok" and len(w.rt.typed) == 1

    # The idle composer drawn before the startup turn starts is not readiness: with
    # no Stop at all, kickoff waits for the turn it saw to end (review finding 1).
    w = World(backend, "antigravity", [(0, PRE_TURN), (3, WORKING), (40, HINT)], status="idle")
    w.rt.hooks.append((3, lambda w=w: setattr(w.rt, "status", "working")))
    w.rt.hooks.append((40, lambda w=w: setattr(w.rt, "status", "idle")))
    outcome, value, _ = w.run(m.session_kickoff)
    assert outcome == "ok" and len(w.rt.typed) == 1 and w.rt.typed[0][0] >= 40.5, (value, w.rt.typed)
    rec = w.record()
    assert rec["input_ready_source"] == "live"
    assert rec["antigravity_conversation_id"] is None and not rec.get("antigravity_ready_at")

    # An idle pane alone, with no Stop and no sign of the startup turn, never suffices.
    w = World(backend, "antigravity", [(0, PRE_TURN)])
    outcome, value, _ = w.run(m.await_session_input_ready, timeout=20)
    assert outcome == "error" and "no sign its startup turn has run" in value and "within 20s" in value, value
    assert "`nogg session log w`" in value and "`nogg session watch w`" in value and "`nogg doctor`" in value
    assert "nothing was typed, keyed or queued" in value
    no_input(w)

    # A turn that ran before the wait (late kickoff, missing Stop hook) is found in the
    # session log or the events file; then two idle samples of the recorded process suffice.
    w = World(backend, "antigravity", [(0, HINT)], log="banner\r\n" + TURN_LOG + "READY\r\n")
    outcome, value, _ = w.run(m.await_session_input_ready)
    assert (outcome, value) == ("ok", "live") and 0 < w.clock.now < 2, (value, w.clock.now)
    no_input(w)
    w = World(backend, "antigravity", [(0, HINT)])
    w.stop_event(fully_idle=False)
    outcome, value, _ = w.run(m.await_session_input_ready)
    assert (outcome, value) == ("ok", "live"), value

    # The fallback needs the exact process: an unrecorded identity never suffices.
    w = World(backend, "antigravity", [(0, HINT)], pid=None, log=TURN_LOG)
    outcome, value, _ = w.run(m.await_session_input_ready, timeout=20)
    assert outcome == "error" and "identity is unverified" in value, value
    no_input(w)

    # A stale Stop (older than this launch) is not this launch's readiness.
    w = World(backend, "antigravity", [(0, HINT)], antigravity_ready_at="2000-01-01T00:00:00+00:00")
    outcome, value, _ = w.run(m.await_session_input_ready, timeout=5)
    assert outcome == "error" and "only a Stop older than this launch" in value, value
    no_input(w)

    # A working turn, a render that keeps changing and a working backend never count.
    w = World(backend, "antigravity", [(0, WORKING)], status="working")
    outcome, value, err = w.run(m.await_session_input_ready, timeout=20)
    assert outcome == "error" and "Antigravity is working" in value, value
    assert 3 <= len(err.strip().splitlines()) <= 4, err                # at most one note per five seconds
    no_input(w)
    flicker = [(t / 2, HINT if t % 2 == 0 else WORKING) for t in range(0, 40)]
    w = World(backend, "antigravity", flicker, log=TURN_LOG)
    outcome, value, _ = w.run(m.await_session_input_ready, timeout=10)
    assert outcome == "error", value
    no_input(w)
    if backend == "herdr":
        w = World(backend, "antigravity", [(0, HINT)], status="working", initial_turn=False)
        outcome, value, _ = w.run(m.await_session_input_ready, timeout=5)
        assert outcome == "error" and "backend reports Antigravity working" in value, value
        # One slow backend read is missing evidence, not a refusal (review finding 3).
        w = World(backend, "antigravity", [(0, HINT)], initial_turn=False)
        w.rt.fail_reads = 2
        outcome, value, _ = w.run(m.session_kickoff)
        assert outcome == "ok" and len(w.rt.typed) == 1, value

    # The pane process changing or the session disappearing ends the wait at once.
    for agent, pane in (("antigravity", WORKING), ("claude", RC_CONNECTING)):
        w = World(backend, agent, [(0, pane)])
        w.rt.hooks.append((10, lambda w=w: setattr(w.rt, "pid", 9999)))
        outcome, value, _ = w.run(m.session_kickoff)
        assert outcome == "error" and "process changed or vanished" in value and w.clock.now < 12, value
        no_input(w)
    w = World(backend, "antigravity", [(0, WORKING)])
    w.rt.hooks.append((10, lambda w=w: setattr(w.rt, "alive", False)))
    outcome, value, _ = w.run(m.session_kickoff)
    assert outcome == "error" and "is not running" in value and w.clock.now < 12, value
    no_input(w)

    # Trust and permission dialogs are never answered: the wait names the dialog and the remedy.
    for agent, pane, extra in (("antigravity", TRUST, {}), ("claude", CLAUDE_PERMISSION, {}),
                               ("codex", CODEX_TRUST, {})):
        w = World(backend, agent, [(0, pane)], **extra)
        outcome, value, _ = w.run(m.session_kickoff)
        assert outcome == "error" and "within 120s" in value, (agent, value)
        if agent != "codex":
            assert "trust, permission or approval prompt" in value and "answer it yourself" in value, value
        no_input(w)

    # A kickoff that cannot be composed refuses before any wait or capture.
    w = World(backend, "claude", [(0, CLAUDE_PERMISSION)], bead_id=None)
    outcome, value, _ = w.run(m.session_kickoff)
    assert outcome == "error" and "carries no bead_id" in value and w.clock.now == 0 and w.rt.captures == 0
    no_input(w)

    # The feedback survey replaces the composer: a plain send refuses at once and never
    # types (its digits would answer the survey); kickoff waits until it is dismissed.
    w = World(backend, "antigravity", [(0, SURVEY)], initial_turn=False)
    outcome, value, _ = w.run(m.session_send, "Reply with DONE")
    assert outcome == "error" and "feedback survey" in value and "Skip option (key 0)" in value, value
    assert w.clock.now == 0
    no_input(w)
    w = World(backend, "antigravity", [(0, SURVEY), (8, HINT)], initial_turn=False)
    outcome, value, err = w.run(m.session_kickoff)
    assert outcome == "ok" and w.rt.typed[0][0] >= 8 and len(w.rt.typed) == 1, (value, w.rt.typed)
    assert "feedback survey" in err

    # The fresh-session mode hint, a background-task panel and a wrapped footer are an
    # empty composer for send and nudge alike (all were refused before).
    for pane in (HINT, PLAN_HINT, PANEL, wrapped):
        w = World(backend, "antigravity", [(0, pane)], initial_turn=False)
        outcome, value, _ = w.run(m.session_send, "Reply with DONE")
        assert outcome == "ok" and [t for _, t in w.rt.typed] == ["Reply with DONE"], (value, w.rt.typed)
        assert [k for _, k in w.rt.keys] == ["enter"], w.rt.keys
        w = World(backend, "antigravity", [(0, pane)], initial_turn=False)
        outcome, value, _ = w.run(m.session_nudge, "Reply with DONE")
        assert outcome == "ok" and [t for _, t in w.rt.typed] == ["Reply with DONE"], (value, w.rt.typed)
    # A plain send during the first turn waits for it, then delivers once.
    w = World(backend, "antigravity", [(0, WORKING), (6, HINT)], status="working")
    w.rt.hooks.append((6, w.stop_event))
    w.rt.hooks.append((6, lambda w=w: setattr(w.rt, "status", "idle")))
    outcome, value, _ = w.run(m.session_send, "Reply with DONE")
    assert outcome == "ok" and len(w.rt.typed) == 1 and w.rt.typed[0][0] >= 6, (value, w.rt.typed)

    # Claude starting slowly: no box, then the banner still connecting Remote Control,
    # then a notice re-rendering above the composer. Kickoff types only once settled.
    notice = CLAUDE_READY.replace("● high · /effort", "tmux detected · scroll with PgUp/PgDn")
    assert m._settle_signature(notice, "claude") != m._settle_signature(CLAUDE_READY, "claude")
    w = World(backend, "claude", [(0, ""), (2, RC_CONNECTING), (4, CLAUDE_READY), (4.3, notice)])
    outcome, value, _ = w.run(m.session_kickoff)
    assert outcome == "ok", value
    assert len(w.rt.typed) == 1 and w.rt.typed[0][0] >= 5.0, w.rt.typed   # 4.0 then 4.5 differ
    assert [k for _, k in w.rt.keys] == ["enter"] and w.record()["input_ready_source"] == "composer"
    # A Remote Control that never connects delays kickoff by at most the delivery
    # timeout; the same words in a transcript below the banner never delay it.
    w = World(backend, "claude", [(0, RC_CONNECTING)])
    outcome, value, err = w.run(m.session_kickoff)
    assert outcome == "ok" and 15 <= w.rt.typed[0][0] < 17, (value, w.rt.typed)
    assert "Remote Control is connecting" in err
    transcript = CLAUDE_READY.replace("● high · /effort", "quoted banner: ~/src/nogging · /rc connecting…")
    assert any(m._CLAUDE_STARTING_RE.search(ln) for ln in plain(transcript).splitlines()[6:])
    w = World(backend, "claude", [(0, transcript)])
    outcome, value, _ = w.run(m.session_kickoff)
    assert outcome == "ok" and w.rt.typed[0][0] < 2, (value, w.rt.typed)

    # Codex: an active thread alone is not readiness; an identified ready composer is.
    w = World(backend, "codex", [(0, "")], codex_thread_id="00000000-0000-4000-8000-0000000000aa")
    outcome, value, _ = w.run(m.await_session_input_ready, timeout=5)
    assert outcome == "error" and "Codex's composer is not identifiable yet" in value, value
    no_input(w)
    w = World(backend, "codex", [(0, ""), (3, CODEX_READY)])
    outcome, value, _ = w.run(m.session_kickoff)
    assert outcome == "ok" and len(w.rt.typed) == 1 and w.rt.typed[0][0] >= 3, (value, w.rt.typed)

    # Plain sends to Claude or Codex keep their steering path: no startup wait.
    w = World(backend, "claude", [(0, f"{RULE}\n\x1b[39m❯\xa0\n{RULE}\n")])
    assert w.run(m.await_session_input_ready, for_kickoff=False)[:2] == ("ok", None) and w.rt.captures == 0

# Without screen attributes only the plain framed box counts: the mode hint is empty,
# typed text is input.
for pane, expected in ((HINT, ("ok", "composer")), (TYPED, ("error", "holding input"))):
    w = World("tmux", "antigravity", [(0, pane)], initial_turn=False, attributes=False)
    outcome, value, _ = w.run(m.await_session_input_ready, timeout=3)
    assert outcome == expected[0] and expected[1] in str(value), value

# Pi keeps its existing path: nothing is sampled.
w = World("tmux", "pi", [(0, "")])
assert w.run(m.await_session_input_ready)[:2] == ("ok", None) and w.rt.captures == 0

# Every invalid timing class refuses before any capture, key, paste or queue call.
invalid = {"session_submit_delay_seconds": [-0.1, 5.1], "session_submit_verify_delay_seconds": [0, 5.5],
           "session_delivery_timeout_seconds": [0.5, 121], "session_startup_timeout_seconds": [0, 601]}
for key, values in invalid.items():
    for value in values + [float("nan"), float("inf"), float("-inf"), True, False, "1", None, [1]]:
        for fn, args in ((m.session_kickoff, ()), (m.await_session_input_ready, ()), (m.session_send, ("hi",))):
            w = World("tmux", "antigravity", [(0, HINT)], initial_turn=False)
            w.cfg[key] = value
            outcome, message, _ = w.run(fn, *args)
            assert outcome == "error" and key in message, (key, value, message)
            assert w.rt.captures == 0, (key, value)
            no_input(w)
for key, value in (("session_submit_delay_seconds", 0), ("session_submit_verify_delay_seconds", 5),
                   ("session_delivery_timeout_seconds", 1), ("session_startup_timeout_seconds", 600)):
    assert m.validate_session_timing_config({key: value})[key] == float(value)

# A hung evidence read is cut off at the deadline, even inside reads that catch
# Exception (pid, liveness, herdr status), and the SIGALRM disposition is restored.
for backend, where in (("tmux", "capture"), ("tmux", "pid"), ("tmux", "list"), ("herdr", "status")):
    w = World(backend, "claude", [(0, CLAUDE_READY)])
    w.cfg["session_startup_timeout_seconds"] = 1
    w.rt.hang.add(where)
    before, started = signal.getsignal(signal.SIGALRM), real_time.monotonic()
    outcome, value, _ = w.run(m.await_session_input_ready)
    assert outcome == "error" and "evidence read did not finish" in value, (where, value)
    assert real_time.monotonic() - started < 4.5 and signal.getsignal(signal.SIGALRM) is before, where
    no_input(w)
print("session input readiness: ok")
PY
