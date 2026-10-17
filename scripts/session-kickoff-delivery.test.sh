#!/usr/bin/env bash
# TASK-RSI-006 (Decision 7): every kickoff variant goes through the bounded
# readiness wait and the verified delivery routine, is serialized by its own
# lock, and persists only a message hash, launch identity, time and status so
# an ambiguous repeat can never duplicate input. The real readiness, composer,
# receipt and delivery code runs against the real tmux backend (through its
# patched transport) and the real herdr backend class over a stateful fake,
# with a fake monotonic clock and a scratch Codex transcript. No test-mode
# bypass, real tmux server, bd or Dolt is involved.
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
import hashlib, io, json, re, signal, sys, textwrap, time as real_time
from contextlib import redirect_stderr, redirect_stdout
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

root, scratch = Path(sys.argv[1]), Path(sys.argv[2])
m = SourceFileLoader("session_kickoff_delivery", str(root / "scripts/nogg")).load_module()
assert not m._is_legacy_mock(), "the real readiness and delivery path must run"
backend_module = m.session_backend_module()
from session_backend_tmux import TmuxBackend
from session_backend_herdr import HerdrBackend

AGY = root / "scripts/fixtures/antigravity/1.4.0/panes"
CLAUDE = root / "scripts/fixtures/claude-panes"
def agy(name): return (AGY / f"{name}.txt").read_text()
HINT, WORKING = agy("accept-edits-hint"), agy("working")
RC_CONNECTING = (CLAUDE / "startup-rc-connecting.txt").read_text()
CLAUDE_READY = (CLAUDE / "startup-ready.txt").read_text()
RULE = "\x1b[38;5;244m" + "─" * 80
CODEX_READY = "\x1b[1m>_ OpenAI Codex\x1b[0m\n\n› \x1b[2mAsk Codex to do anything\x1b[0m\n\n  100% context left\n"
PRE_TURN = HINT
OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
def plain(text): return m._ANSI_RE.sub("", OSC_RE.sub("", text))


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
THREAD = "00000000-0000-4000-8000-0000000000bb"
real_run = m.run

def digest(text): return hashlib.sha256(text.encode()).hexdigest()
def delivery(world): return world.record().get("kickoff_delivery")

def assert_delivered(world, message=KICKOFF, status="submitted"):
    """The record holds identity, never the instruction; kickoff_sent_at follows success only."""
    rec, kd = world.record(), world.record().get("kickoff_delivery")
    assert kd and kd["status"] == status and kd["message_sha256"] == digest(message), kd
    assert kd["launch"] == m._launch_identity(rec) and kd["at"], kd
    assert message not in world.path.read_text(), "the plaintext instruction must never be stored"
    assert bool(rec.get("kickoff_sent_at")) == (status == "submitted"), (status, rec.get("kickoff_sent_at"))

def enters(world): return [k for _, k in world.rt.keys if k == "enter"]

def drop_enter(world):
    """The runtime ignores Enter until `state['drop']` is cleared (but counts the press)."""
    state, original = {"drop": True}, world.rt.key
    def key(k):
        if state["drop"] and k == "enter":
            world.rt.keys.append((world.clock.now, k))
            return
        original(k)
    world.rt.key = key
    return state

def user_record(text):
    return {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                  "content": [{"type": "input_text", "text": text}]}}

def codex_world(backend, **fields):
    w = World(backend, "codex", [(0, CODEX_READY)], codex_thread_id=THREAD, **fields)
    day = scratch / "codex/sessions/2026/10/17"
    day.mkdir(parents=True, exist_ok=True)
    w.transcript = day / f"rollout-2026-10-17T00-00-{World.count:02d}-{THREAD}.jsonl"
    meta = {"type": "session_meta", "payload": {"id": THREAD, "cwd": str(w.dir), "timestamp": "2026-10-17T00:00:00.000Z"}}
    w.transcript.write_text(json.dumps(meta) + "\n")
    w.queue_calls = []
    w.queue_effect = lambda args: None
    w.queue_answer = (0, "Queued message fake-id.\n", "")
    return w

def append_user(world, text):
    with world.transcript.open("a") as fh:
        fh.write(json.dumps(user_record(text)) + "\n")

def run_codex(world, fn, *args, **kwargs):
    """Run with `codex queue` answered by the world's scripted effect (exit 0, accepted)."""
    def fake_run(*argv, **kw):
        if argv[:2] == ("codex", "queue"):
            world.queue_calls.append(argv[argv.index("--message") + 1])
            world.queue_effect(argv)
            return SimpleNamespace(returncode=world.queue_answer[0], stdout=world.queue_answer[1],
                                   stderr=world.queue_answer[2])
        return real_run(*argv, **kw)
    with patch.object(m, "run", fake_run):
        return world.run(fn, *args, **kwargs)

def run_with_bd(world, rows, fn, *args, **kwargs):
    def fake_run(*argv, **kw):
        if argv[1:2] == ("show",):
            return SimpleNamespace(returncode=0, stdout=json.dumps(rows), stderr="")
        return real_run(*argv, **kw)
    with patch.object(m, "run", fake_run):
        return world.run(fn, *args, **kwargs)

for backend in ("tmux", "herdr"):
    # --- Every role composes its scope, waits for readiness and verifies delivery ------
    w = World(backend, "claude", [(0, RC_CONNECTING), (3, CLAUDE_READY)])
    outcome, value, _ = w.run(m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered"), value
    assert [t for _, t in w.rt.typed] == [KICKOFF] and w.rt.typed[0][0] >= 3 and len(enters(w)) == 1
    assert_delivered(w)
    outcome, value, _ = w.run(m.session_kickoff)                      # a confirmed repeat is a no-op
    assert (outcome, value) == ("ok", "noop") and len(w.rt.typed) == 1 and len(enters(w)) == 1

    plan = World(backend, "claude", [(0, CLAUDE_READY)], role="planning", bead_id=None,
                 planning_id="plan-one", description="scope")
    with patch.object(m, "planning_launch_workdir", return_value="/work/plan-one"):
        outcome, value, _ = plan.run(m.session_kickoff)
    assert outcome == "ok", value
    text = plan.rt.typed[0][1]
    assert "plan-one" in text and "/work/plan-one" in text and "plan-begin yourself" in text, text
    assert_delivered(plan, text)

    claimed = [{"id": "SPEC-test", "status": "in_progress", "assignee": "Nogging Lead"}]
    spec = World(backend, "claude", [(0, CLAUDE_READY)], role="specialist:test-runner")
    outcome, value, _ = run_with_bd(spec, claimed, m.session_kickoff)
    assert outcome == "ok", value
    text = spec.rt.typed[0][1]
    assert "already-claimed Bead SPEC-test" in text and "Do not claim, re-status, close or commit" in text, text
    assert_delivered(spec, text)

    explicit = World(backend, "claude", [(0, CLAUDE_READY)], bead_id=None)
    outcome, value, _ = explicit.run(m.session_kickoff, "Explore the log and report.")
    assert outcome == "ok" and [t for _, t in explicit.rt.typed] == ["Explore the log and report."]
    assert_delivered(explicit, "Explore the log and report.")

    scoped = World(backend, "claude", [(0, CLAUDE_READY)])
    outcome, value, _ = scoped.run(m.session_kickoff, None, "reliable-session-input")
    assert outcome == "ok", value
    text = scoped.rt.typed[0][1]
    assert text.startswith("Implement all mapped tasks in authorized change reliable-session-input"), text
    assert_delivered(scoped, text)
    assert scoped.record()["authorized_change"] == "reliable-session-input"
    outcome, value, _ = scoped.run(m.session_kickoff, None, "reliable-session-input")
    assert outcome == "ok" and len(scoped.rt.typed) == 1 and len(enters(scoped)) == 1   # no replay
    outcome, value, _ = scoped.run(m.session_kickoff, None, "another-change")
    assert outcome == "error" and "change scope requires a lead session" in value and len(scoped.rt.typed) == 1

    # --- Refusals happen before any wait, keystroke or record ---------------------------
    for fields, role_text in ((dict(bead_id=None), "carries no bead_id"),):
        w = World(backend, "claude", [(0, CLAUDE_READY)], **fields)
        outcome, value, _ = w.run(m.session_kickoff)
        assert outcome == "error" and role_text in value and w.rt.captures == 0 and w.clock.now == 0, value
        no_input(w)
        assert delivery(w) is None and not w.record().get("kickoff_sent_at")
    w = World(backend, "claude", [(0, CLAUDE_READY)], role="specialist:test-runner")
    outcome, value, _ = run_with_bd(w, [dict(claimed[0], status="open")], m.session_kickoff)
    assert outcome == "error" and "already-claimed Bead SPEC-test" in value and w.rt.captures == 0, value
    no_input(w)
    assert delivery(w) is None

    # --- A failed readiness wait leaves no marker and is safe to retry ------------------
    w = World(backend, "claude", [(0, ""), (500, CLAUDE_READY)])
    w.cfg["session_startup_timeout_seconds"] = 20
    outcome, value, _ = w.run(m.session_kickoff)
    assert outcome == "error" and "was not ready for input within 20s" in value, value
    no_input(w)
    assert delivery(w) is None and not w.record().get("kickoff_sent_at")
    w.clock.now = 500
    outcome, value, _ = w.run(m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered") and len(w.rt.typed) == 1
    assert_delivered(w)

    # --- Antigravity: a start past thirty seconds, the Stop event arriving mid-delivery -
    w = World(backend, "antigravity", [(0, PRE_TURN), (0.3, WORKING), (45, HINT)], status="working")
    w.rt.hooks.append((45, w.stop_event))
    w.rt.hooks.append((45, lambda w=w: setattr(w.rt, "status", "idle")))
    before_kickoff = w.record()
    original_type = w.rt.type
    def type_then_stop(text, w=w, original_type=original_type):
        original_type(text)
        w.stop_event()                       # a late Stop lands between pending and submitted
    w.rt.type = type_then_stop
    outcome, value, _ = w.run(m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered"), value
    assert [t for _, t in w.rt.typed] == [KICKOFF] and w.rt.typed[0][0] >= 45
    assert_delivered(w)
    rec = w.record()
    assert rec["antigravity_conversation_id"] and rec["antigravity_ready_at"] and rec["input_ready_source"] == "stop"
    with patch.object(m, "CFG", w.cfg):                                  # a stale lifecycle write keeps it all
        m.transition(w.path, dict(before_kickoff), "running")
    kept = w.record()
    assert kept["kickoff_delivery"] == rec["kickoff_delivery"] and kept["kickoff_sent_at"] == rec["kickoff_sent_at"]
    assert kept["antigravity_conversation_id"] == rec["antigravity_conversation_id"]
    outcome, value, _ = w.run(m.session_kickoff, "A different instruction")   # one kickoff per launch
    assert (outcome, value) == ("ok", "noop") and len(w.rt.typed) == 1

    # An Antigravity kickoff that lost the race for the lock finds the launch's kickoff
    # already sent and types nothing, whatever its message.
    w = World(backend, "antigravity", [(0, HINT)], initial_turn=False)
    w.stop_event()
    state, real_acquire = {"first": True}, m.acquire_bounded_flock
    def acquire_after_rival(handle, deadline, *args, **kwargs):
        if state["first"] and str(handle.name).endswith(".kickoff.lock"):
            state["first"] = False
            assert w.run(m.session_kickoff, "The rival's instruction")[:2] == ("ok", "delivered")
        return real_acquire(handle, deadline, *args, **kwargs)
    with patch.object(m, "acquire_bounded_flock", acquire_after_rival):
        outcome, value, _ = w.run(m.session_kickoff, "The late instruction")
    assert (outcome, value) == ("ok", "noop"), value
    assert [t for _, t in w.rt.typed] == ["The rival's instruction"] and len(enters(w)) == 1

    # --- Concurrent calls are serialized by the kickoff lock ---------------------------
    w = World(backend, "claude", [(0, CLAUDE_READY)])
    seen = []
    def second_caller(w=w):
        saved = w.clock.now                  # the contender spins on the fake clock; restore it
        seen.append(w.run(m.session_kickoff))
        w.clock.now = saved
    w.rt.hooks.append((0, second_caller))
    outcome, value, _ = w.run(m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered"), value
    assert seen and seen[0][0] == "error" and "another kickoff is still in progress" in seen[0][1], seen
    assert len(w.rt.typed) == 1 and len(enters(w)) == 1
    assert_delivered(w)

    # --- Codex: delayed queue delivery is submitted evidence, not a failure -------------
    w = codex_world(backend)
    w.queue_effect = lambda args, w=w: w.rt.hooks.append((w.clock.now + 4, lambda: append_user(w, KICKOFF)))
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered"), value
    assert w.queue_calls == [KICKOFF] and not w.rt.typed and not w.rt.keys
    assert_delivered(w)

    # --- Codex: accepted but unconfirmed is never queued or typed again ----------------
    w = codex_world(backend)
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert outcome == "error" and "accepted the queued message" in value, value
    assert w.queue_calls == [KICKOFF] and not w.rt.typed and not w.rt.keys
    assert_delivered(w, status="unverified")
    kd = delivery(w)
    assert kd["receipt_source"]["thread_id"] == THREAD and isinstance(kd["receipt_source"]["offset"], int)
    assert "partial" not in json.dumps(kd) and KICKOFF not in w.path.read_text()
    outcome, value, _ = run_codex(w, m.session_kickoff)               # no new evidence: still no replay
    assert outcome == "error" and "already attempted (unverified)" in value and "not typed or queued again" in value, value
    assert w.queue_calls == [KICKOFF] and not w.rt.typed and not w.rt.keys
    append_user(w, "an unrelated message")                            # foreign text is not a receipt
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert outcome == "error" and w.queue_calls == [KICKOFF]
    append_user(w, KICKOFF)                                           # the receipt finally arrives
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered"), value
    assert w.queue_calls == [KICKOFF] and not w.rt.typed and not w.rt.keys
    assert_delivered(w)
    assert delivery(w)["receipt"] and delivery(w)["receipt_source"]["thread_id"] == THREAD
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert (outcome, value) == ("ok", "noop") and w.queue_calls == [KICKOFF]

    # A different explicit instruction is a new operator-directed attempt, not a replay.
    w = codex_world(backend)
    outcome, _, _ = run_codex(w, m.session_kickoff)
    assert outcome == "error"
    assert_delivered(w, status="unverified")
    w.queue_effect = lambda args, w=w: append_user(w, "Take over the review")
    outcome, value, _ = run_codex(w, m.session_kickoff, "Take over the review")
    assert (outcome, value) == ("ok", "delivered") and w.queue_calls == [KICKOFF, "Take over the review"]
    assert_delivered(w, "Take over the review")

    # Codex: a refusal before acceptance falls back to the verified pane path, once.
    refusal = (root / "scripts/fixtures/codex-queue/synthetic-refused-unknown-thread.stderr").read_text()
    w = codex_world(backend)
    w.queue_answer = (1, "", refusal)
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered"), value
    assert w.queue_calls == [KICKOFF] and [t for _, t in w.rt.typed] == [KICKOFF] and len(enters(w)) == 1
    assert_delivered(w)
    # ...and when that pane path also refuses before typing, nothing was attempted: no record at all.
    w = codex_world(backend)
    w.queue_answer = (1, "", refusal)
    w.queue_effect = lambda args, w=w: setattr(w.rt, "text", "operator draft")   # typed after readiness
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert outcome == "error" and "nothing was typed or submitted" in value, value
    assert not w.rt.typed and delivery(w) is None and not w.record().get("kickoff_sent_at")

    # Codex: the queued text lingers in the composer. Our own bounded Enters could not
    # submit it, so the repeat submits that exact pending text once, without retyping.
    w = codex_world(backend)
    enter = drop_enter(w)
    def linger(args, w=w): w.rt.text = KICKOFF
    w.queue_effect = linger
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert outcome == "error" and "still unsubmitted" in value, value
    assert_delivered(w, status="unverified")
    presses = len(enters(w))
    enter["drop"] = False
    outcome, value, _ = run_codex(w, m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered"), value
    assert w.queue_calls == [KICKOFF] and not w.rt.typed
    assert len(enters(w)) == presses + 1
    assert_delivered(w)

    # --- Pane agents: typed but unconfirmed is recovered only from the exact composer ----
    w = World(backend, "claude", [(0, CLAUDE_READY)])
    enter = drop_enter(w)
    outcome, value, _ = w.run(m.session_kickoff)
    assert outcome == "error" and ("unsubmitted" in value or "unverified" in value), value
    assert [t for _, t in w.rt.typed] == [KICKOFF]
    assert_delivered(w, status="unverified")
    presses = len(enters(w))
    enter["drop"] = False
    outcome, value, _ = w.run(m.session_kickoff)
    assert (outcome, value) == ("ok", "delivered"), value
    assert [t for _, t in w.rt.typed] == [KICKOFF] and len(enters(w)) == presses + 1   # never retyped
    assert_delivered(w)

    w = World(backend, "claude", [(0, CLAUDE_READY)])
    enter = drop_enter(w)
    assert w.run(m.session_kickoff)[0] == "error"
    presses = len(enters(w))
    w.rt.text = None                                                    # the operator cleared the composer
    enter["drop"] = False
    outcome, value, _ = w.run(m.session_kickoff)                        # empty and no evidence: unverified
    assert outcome == "error" and "already attempted (unverified)" in value, value
    assert len(w.rt.typed) == 1 and len(enters(w)) == presses
    assert_delivered(w, status="unverified")
    outcome, value, _ = w.run(m.session_kickoff, "Operator chosen replacement")
    assert (outcome, value) == ("ok", "delivered") and len(w.rt.typed) == 2
    assert_delivered(w, "Operator chosen replacement")

# A crash between pending and the outcome leaves the record pending, and a repeat treats it like unverified.
w = World("tmux", "claude", [(0, CLAUDE_READY)])
with patch.object(m, "CFG", w.cfg):
    m._write_kickoff_delivery("w", {"message_sha256": digest(KICKOFF), "launch": m._launch_identity(w.record()),
                                     "status": "pending", "at": m.now()})
outcome, value, _ = w.run(m.session_kickoff)
assert outcome == "error" and "already attempted (pending)" in value and not w.rt.typed, value
assert delivery(w)["status"] == "unverified"

# A record from an earlier launch of the same name is not this launch's evidence.
w = World("tmux", "claude", [(0, CLAUDE_READY)])
earlier = m._launch_identity(dict(w.record(), started_at="2020-01-01T00:00:00Z"))
assert earlier != m._launch_identity(w.record())
with patch.object(m, "CFG", w.cfg):
    m._write_kickoff_delivery("w", {"message_sha256": digest(KICKOFF), "launch": earlier,
                                     "status": "submitted", "at": m.now()})
outcome, value, _ = w.run(m.session_kickoff)
assert (outcome, value) == ("ok", "delivered") and len(w.rt.typed) == 1
assert_delivered(w)

# Pi keeps its direct delivery and is recorded like any other kickoff.
w = World("tmux", "pi", [(0, "")])
outcome, value, _ = w.run(m.session_kickoff)
assert (outcome, value) == ("ok", "delivered") and [t for _, t in w.rt.typed] == [KICKOFF], value
assert_delivered(w)

# --- launch --kickoff chains the same path and propagates its failure ----------------
import os, shutil, subprocess, tempfile
from unittest.mock import Mock
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    main, linked, home = tmp / "main", tmp / "linked", tmp / "home"
    home.mkdir()
    subprocess.run(["git", "init", "-q", str(main)], check=True)
    subprocess.run(["git", "-C", str(main), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "--allow-empty", "-qm", "fixture"], check=True)
    subprocess.run(["git", "-C", str(main), "worktree", "add", "-qb", "linked", str(linked)], check=True)
    (linked / "scripts/hooks").mkdir(parents=True)
    for rel in ("scripts/nogg", "scripts/hooks/agy-guard"):
        shutil.copy2(root / rel, linked / rel)
    (linked / ".agents").mkdir()
    (linked / ".agents/hooks.json").write_text((root / "templates/antigravity/hooks.json").read_text())
    settings = home / ".gemini/antigravity-cli/settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({"trustedWorkspaces": [], "toolPermission": "request-review"}))
    profile = tmp / "custom.agy.toml"
    profile.write_text('model = "test-model"\napproval = "auto"\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NOGG_", "NOGGING_"))}
    env["HOME"] = str(home)
    calls = []
    def tmux(*args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, "", "")
    def launch(**kwargs):
        return m.session_launch("lead", "SPEC-test", str(linked), True, None, profile=str(profile), agent="agy", **kwargs)
    with patch.dict(os.environ, env, clear=True), patch.object(m, "CFG", {**m.CFG, "session_state_dir": str(tmp / "sessions")}), \
         patch.object(m, "bead_records", return_value=[{"id": "SPEC-test", "labels": []}]), \
         patch.object(m, "unmet_dependencies", return_value=[]), patch.object(m, "tmux", side_effect=tmux), \
         patch.object(m, "tmux_sessions", return_value=set()), patch.object(m, "tmux_has_session", return_value=False), \
         redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        chained = Mock(return_value="delivered")
        with patch.object(m, "session_kickoff", chained):
            launch()
            assert chained.call_count == 0, "bare launch sends nothing"
            launch(kickoff=True)
        assert chained.call_count == 1 and chained.call_args.args[0].startswith("sf-lead-spec-test"), chained.call_args
        failing = Mock(side_effect=RuntimeError("Antigravity was not ready for input within 120s"))
        with patch.object(m, "session_kickoff", failing):
            try:
                launch(kickoff=True)
            except RuntimeError as exc:
                assert "was not ready for input" in str(exc)
            else:
                raise AssertionError("a failed kickoff must fail the launch")
        assert failing.call_count == 1

print("session kickoff delivery: ok")
PY
