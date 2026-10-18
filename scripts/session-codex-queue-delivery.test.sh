#!/usr/bin/env bash
# TASK-RSI-005: Codex queue outcomes, fresh receipts and exact-pending recovery
# in send/nudge (reliable-session-input Decision 6). The REAL composer
# classification, receipt reader and submit helpers run against a stateful
# substrate and a scratch transcript; no test-mode detection is involved.
set -euo pipefail
for name in $(compgen -e); do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_TMPDIR|TMUX_STUB_DIR|TMUX_STATEFUL_STUB) unset "$name" ;; esac
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d /tmp/nogg.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
export CODEX_HOME="$scratch/codex-home"
python3 - "$root" "$scratch" <<'PY'
import contextlib, io, json, pathlib, subprocess, sys, time as real_time
from importlib.machinery import SourceFileLoader
from types import SimpleNamespace
from unittest.mock import patch

root, scratch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(root / "scripts/lib"))
m = SourceFileLoader("codex_queue_delivery", str(root / "scripts/nogg")).load_module()
assert not m._is_legacy_mock(), "the real verification path must run, not the test-mode bypass"
fixtures = root / "scripts/fixtures/codex-queue"
REFUSED = (fixtures / "synthetic-refused-unknown-thread.stderr").read_text()
AMBIGUOUS = (fixtures / "synthetic-ambiguous-failure.stderr").read_text()

THREAD, OTHER = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
CWD = str(scratch / "work")
EMPTY = "› \x1b[2mAsk Codex to do anything\x1b[0m\n"
MSG = "Claim Bead SPEC-1 and implement\nits mapped task — “quoted”."
S = "Claim Bead SPEC-1 and implement its mapped task — “quoted”."
PEND = f"› {S}\n"

def rollout(thread, history=()):
    d = scratch / "codex-home/sessions/2026/10/17"
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"rollout-2026-10-17T00-00-00-{thread}.jsonl"
    meta = {"type": "session_meta", "payload": {"id": thread, "cwd": CWD, "timestamp": "2026-10-17T00:00:00.000Z"}}
    path.write_text("\n".join(json.dumps(r) for r in [meta, *history]) + "\n")
    return path

def user_record(text):
    return {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                  "content": [{"type": "input_text", "text": text}]}}

def append(path, record):
    with path.open("a") as fh:
        fh.write(json.dumps(record) + "\n")

class Clock:
    def __init__(self):
        self.now, self.events = 1000.0, []
    def monotonic(self): return self.now
    def sleep(self, seconds):
        self.now += seconds
        due = [e for e in self.events if e[0] <= self.now]
        self.events = [e for e in self.events if e[0] > self.now]
        for _, fn in due: fn()
    def at(self, delay, fn): self.events.append((self.now + delay, fn))
    def __getattr__(self, name): return getattr(real_time, name)

class Pane:
    """Stateful codex substrate: the pane text is data the test scripts drive."""
    def __init__(self, text=EMPTY):
        self.pane, self.typed, self.enters, self.keys = text, [], 0, []
        self.on_enter = lambda p: None
        self.capabilities = SimpleNamespace(capture_attributes=True, agent_status=True)
    def capture(self, ref, attributes=False): return self.pane
    def send_keys(self, ref, key, check=True):
        self.keys.append(key)
        if key == "enter":
            self.enters += 1
            self.on_enter(self)
    def send_text(self, ref, text):
        self.typed.append(text)
        self.pane = f"› {text.splitlines()[0]}\n" if "\n" not in text else "› " + text.replace("\n", "\n  ") + "\n"
    def agent_status(self, ref): return "idle"

def scenario(*, queue, pane=None, thread=THREAD, history=(), resolved=True, mode="send", message=MSG):
    """Run one delivery; returns (result, calls, pane, path, clock, out)."""
    clock, pane, calls = Clock(), pane or Pane(), []
    path = rollout(THREAD, history)
    rollout(OTHER)
    rec = {"name": "w", "agent": "codex", "working_dir": CWD}
    if resolved:
        rec["codex_thread_id"] = thread
    def fake_run(*args, **kw):
        assert args[:2] == ("codex", "queue") and "--thread" in args, args
        calls.append(args)
        r = queue(clock, pane, path, args)
        if isinstance(r, BaseException): raise r
        return SimpleNamespace(returncode=r[0], stdout=r[1], stderr=r[2])
    out, result = io.StringIO(), None
    with patch.object(m, "time", clock), patch.object(m, "run", fake_run), \
         patch.object(m, "backend_for_name", return_value=(pane, {})), \
         patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "load_session", return_value=(None, rec)), \
         patch.object(m, "tmux_has_session", return_value=True), \
         patch.object(m, "_capture_backend_status", return_value="idle"), \
         contextlib.redirect_stdout(out):
        try:
            if mode == "send": m.session_send("w", message)
            else: m.session_nudge("w", message)
            result = "ok"
        except RuntimeError as exc:
            result = str(exc)
    return result, calls, pane, path, clock, out.getvalue()

OK = (0, "Queued message fake-msg-id.\n", "")
def accepted_with(effect):
    def queue(clock, pane, path, args):
        effect(clock, pane, path); return OK
    return queue
def assert_unverified(result, calls, pane, enters):
    assert "accepted the queued message" in result and "not typed or queued again" in result, result
    assert f"thread {THREAD[:8]}" in result and "receipt scan:" in result, result
    assert "session nudge" in result and MSG not in result, result
    assert len(calls) == 1, calls
    assert pane.typed == [] and pane.enters == enters, (pane.typed, pane.enters)

for mode, line in (("send", "sent to w (codex queue)"), ("nudge", "nudged w (codex queue)")):
    # Fresh receipt: submitted with no Enter and no pane text, even with an empty composer.
    r, calls, pane, *_, out = scenario(mode=mode, queue=accepted_with(lambda c, p, path: append(path, user_record(MSG))))
    assert r == "ok" and line in out and len(calls) == 1 and pane.typed == [] and pane.enters == 0, (r, out)

    # CRLF-normalised receipt still counts; the receipt may arrive late (fake clock).
    def late(clock, pane, path):
        clock.at(4.0, lambda: append(path, user_record(MSG.replace("\n", "\r\n"))))
    r, calls, pane, *_, out = scenario(mode=mode, queue=accepted_with(late))
    assert r == "ok" and line in out and pane.enters == 0 and len(calls) == 1, (r, out)

    # Success is never printed without evidence.
    r, calls, pane, _p, clock, out = scenario(mode=mode, queue=accepted_with(lambda *a: None))
    assert_unverified(r, calls, pane, 0)
    assert "codex queue" not in out and clock.now - 1000.0 <= 15.5

    # Historical identical text and another thread's receipt are not evidence.
    r, calls, pane, *_ = scenario(mode=mode, history=[user_record(MSG)], queue=accepted_with(lambda *a: None))
    assert_unverified(r, calls, pane, 0)
    r, calls, pane, *_ = scenario(mode=mode, queue=accepted_with(
        lambda c, p, path: append(path.with_name(path.name.replace(THREAD, OTHER)), user_record(MSG))))
    assert_unverified(r, calls, pane, 0)

    # Accepted, unrelated assistant/tool text and a different user message do not count.
    r, calls, pane, *_ = scenario(mode=mode, queue=accepted_with(lambda c, p, path: append(path, user_record(MSG + " more"))))
    assert_unverified(r, calls, pane, 0)

    # Unknown composer (no prompt) and no receipt: unverified, no Enter, no fallback.
    def unknown(clock, pane, path): pane.pane = "something unidentifiable\n"
    r, calls, pane, *_ = scenario(mode=mode, queue=accepted_with(unknown))
    assert_unverified(r, calls, pane, 0)

    # Queue leaves the exact text pending: one delayed Enter, no retyping, no requeue.
    def pending(clock, pane, path):
        pane.pane = PEND
        pane.on_enter = lambda p: setattr(p, "pane", EMPTY)
    r, calls, pane, _p, clock, out = scenario(mode=mode, message=S, queue=accepted_with(pending))
    assert r == "ok" and line in out and pane.enters == 1 and pane.typed == [] and len(calls) == 1, (r, pane.enters)
    assert clock.now - 1000.0 >= 0.3, "Enter must wait for the submit delay"

    # A swallowed first Enter gets exactly one retry.
    def swallow(clock, pane, path):
        pending(clock, pane, path)
        pane.on_enter = lambda p: setattr(p, "pane", EMPTY) if p.enters >= 2 else None
    r, calls, pane, *_ = scenario(mode=mode, message=S, queue=accepted_with(swallow))
    assert r == "ok" and pane.enters == 2 and pane.typed == [] and len(calls) == 1

    # Still pending after the retry: unverified at the bound, never a third Enter.
    def stuck(clock, pane, path):
        pending(clock, pane, path); pane.on_enter = lambda p: None
    r, calls, pane, _p, clock, _o = scenario(mode=mode, message=S, queue=accepted_with(stuck))
    assert "still unsubmitted after one retry" in r, r
    assert len(calls) == 1 and pane.typed == [] and pane.enters == 2
    assert clock.now - 1000.0 <= 15.5

    # A receipt that lands while the buffer is pending wins and needs no Enter.
    def raced(clock, pane, path):
        pending(clock, pane, path); append(path, user_record(S))
    r, calls, pane, *_ = scenario(mode=mode, message=S, queue=accepted_with(raced))
    assert r == "ok" and pane.enters == 0

    # Sole collapsed paste marker counts as ours only from a clean baseline.
    def marker(clock, pane, path):
        pane.pane = "[Pasted Content]\n" + EMPTY
        pane.on_enter = lambda p: setattr(p, "pane", EMPTY)
    long_message = "Claim Bead SPEC-1 and implement\nits mapped task — “quoted”. " + "record evidence; " * 20
    r, calls, pane, *_ = scenario(mode=mode, message=long_message, queue=accepted_with(marker))
    assert r == "ok" and pane.enters == 1 and pane.typed == [], (r, pane.enters, pane.typed, pane.pane, calls)
    r, calls, pane, *_ = scenario(mode=mode, message=long_message, pane=Pane("› operator draft\n"), queue=accepted_with(marker))
    assert_unverified(r, calls, pane, 0)

    # Busy before send: the operator's draft is never touched; only a receipt confirms.
    draft = Pane("› operator draft\n")
    r, calls, pane, *_ = scenario(mode=mode, message=S, pane=draft, queue=accepted_with(
        lambda c, p, path: append(path, user_record(S))))
    assert r == "ok" and pane.enters == 0 and pane.keys == [] and pane.pane == "› operator draft\n"
    r, calls, pane, *_ = scenario(mode=mode, message=S, pane=Pane("› operator draft\n"), queue=accepted_with(lambda *a: None))
    assert_unverified(r, calls, pane, 0)
    assert pane.keys == []

    # Exact text already pending before the call is not provenance either.
    already = Pane(PEND)
    r, calls, pane, *_ = scenario(mode=mode, message=S, pane=already, queue=accepted_with(lambda *a: None))
    assert_unverified(r, calls, pane, 0)

    # Definitive pre-acceptance refusal (committed fixture): the verified pane route,
    # with the queue called exactly once.
    def refuse(clock, pane, path, args): return (1, "", REFUSED)
    def typed_and_submit(p):
        p.on_enter = lambda q: setattr(q, "pane", EMPTY)
    pane0 = Pane(); typed_and_submit(pane0)
    r, calls, pane, *_, out = scenario(mode=mode, message=S, pane=pane0, queue=refuse)
    assert r == "ok" and len(calls) == 1 and pane.typed == [S] and pane.enters == 1, (r, calls, pane.typed)
    assert "codex queue" not in out

    # A missing codex binary never ran, so nothing was accepted: fallback allowed.
    pane0 = Pane(); typed_and_submit(pane0)
    r, calls, pane, *_ = scenario(mode=mode, message=S, pane=pane0, queue=lambda *a: FileNotFoundError("codex"))
    assert r == "ok" and len(calls) == 1 and pane.typed == [S] and pane.enters == 1

    # Ambiguous failure and timeout are unverified: no fallback, no second queue call.
    r, calls, pane, *_ = scenario(mode=mode, queue=lambda *a: (1, "", AMBIGUOUS))
    assert "queue call timed out or failed ambiguously" in r and len(calls) == 1 and pane.typed == [] and pane.enters == 0
    r, calls, pane, *_ = scenario(mode=mode, queue=lambda *a: subprocess.TimeoutExpired("codex", 1))
    assert "queue call timed out or failed ambiguously" in r and len(calls) == 1 and pane.typed == [] and pane.enters == 0

    # Unresolved thread: the queue is never invoked; verified pane delivery is allowed.
    pane0 = Pane(); typed_and_submit(pane0)
    with patch.object(m, "resolve_codex_thread_id", return_value=None):
        r, calls, pane, *_ = scenario(mode=mode, message=S, pane=pane0, resolved=False, queue=lambda *a: OK)
    assert r == "ok" and calls == [] and pane.typed == [S] and pane.enters == 1

# The subprocess is bounded by the delivery deadline and receives only the exact thread.
seen = {}
def spy(clock, pane, path, args): seen["args"] = args; append(path, user_record(MSG)); return OK
orig = m._codex_queue_invoke
def bounded(thread_id, message, timeout):
    seen["timeout"] = timeout; return orig(thread_id, message, timeout)
with patch.object(m, "_codex_queue_invoke", bounded):
    scenario(queue=spy)
assert seen["args"][2:] == ("--thread", THREAD, "--message", MSG) and 0 < seen["timeout"] <= 15.0, seen

# Invalid timing refuses before any queue call or key.
r, calls, pane, *_ = (lambda: scenario(queue=lambda *a: OK))()
bad = dict(m.CFG, session_delivery_timeout_seconds=0)
with patch.object(m, "CFG", bad):
    r, calls, pane, *_ = scenario(queue=lambda *a: OK)
assert "session_delivery_timeout_seconds" in r and calls == [] and pane.keys == [] and pane.typed == []

# The refusal classifier uses the committed fixtures only.
assert any(rx.search(REFUSED) for rx in m.CODEX_QUEUE_REFUSALS)
assert not any(rx.search(AMBIGUOUS) for rx in m.CODEX_QUEUE_REFUSALS)
print("session Codex queue delivery: ok")
PY
