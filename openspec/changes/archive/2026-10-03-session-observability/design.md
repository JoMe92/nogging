# Design — session observability

## Decision 1 — adapters are data, not free-text keyword matching

The hand-rolled predecessor's false-positive problem (every Claude pane
permanently showing `Auto-update failed: no write permission to npm prefix`,
tripping a bare `failed` keyword match) is a direct consequence of two
choices this design reverses: matching 80 lines of scrollback instead of the
visible screen, and matching free-text keywords instead of per-agent
structural signals. The fix is an `Adapter` as a plain data record — an
`ignore` pattern list applied first, then ordered pattern lists per state —
not a single global regex table:

```python
@dataclass
class Adapter:
    name: str
    ignore: list[re.Pattern]        # benign chrome, stripped before classifying
    working: list[re.Pattern]
    waiting_bg: list[re.Pattern] = field(default_factory=list)
    needs_input: list[re.Pattern] = field(default_factory=list)
    limit: list[re.Pattern] = field(default_factory=list)
    idle: list[re.Pattern] = field(default_factory=list)
```

Classification reads only the last ~15 lines of the pane (not full
scrollback), strips ignored lines first, then checks states in a fixed
precedence order: `limit` > `needs_input` > `working` > `waiting_background` >
`idle`, else `unknown`.

### Adapter patterns (from production observation, #23)

**`claude`**:

| State | Pattern |
| --- | --- |
| ignore | `Auto-update failed`, `Tip:` |
| working | `esc to interrupt` |
| waiting_background | `\d+ shells?( still running)?`, `\d+ monitors?` |
| needs_input | `Do you want to proceed`, `Allow this`, `❯ 1\. Yes` |
| limit | `usage limit reached`, `rate limit` (case-insensitive) |
| idle | `❯\s*$` |

**`codex`** (verified against this host's installed codex-cli 0.158.0 panes,
patterns confirmed in #23's write-up against 0.148-0.158):

| State | Pattern |
| --- | --- |
| working | `Working \(` |
| idle | `Ask Codex to do anything` |
| needs_input (`undelivered_input`) | `Pasted Content` visible while otherwise idle — the lost-message failure mode itself |

Both tables ship as the literal starting pattern sets (implementation may
refine after a short live-session dry run), not as a sketch to redesign from
scratch — re-deriving them would re-risk the same false-positive class this
change exists to fix.

## Decision 2 — usage-limit detection is a pattern in the adapter, not a separate feature

#20's "recognize the usage-limit message" is not implemented as a standalone
mechanism. It is the `limit` row in each adapter's pattern table (Decision 1)
plus one shared timestamp parser: resolve a bare `HH:MM`/`H:MM AM/PM` against
the host's current local date, rolling to the next day when the parsed time
is earlier than the current time (a session that starts late at night and
hits a limit whose reset is technically "tomorrow"). The parsed, absolute
timestamp is carried in the `limit` event (`limit until=<ISO8601>`) so a
caller never re-parses prose.

**Documented, not just handled**: switching to a cheaper/faster model does
**not** clear a genuine account-wide usage-limit hit (confirmed twice in
production per #20). `resume-when-ready` dismisses a residual "switch model?"
prompt by keeping the current model, never by switching, and
`docs/nogging/failure-recovery.md` states this plainly so a future operator
does not spend a session-cycle on the same false start.

## Decision 3 — `watch` emits on transition only, with a stall detector

A session whose pane is unchanged for `--stall-after` (default 15m) while its
last known state was `working` emits a `stalled` event — distinct from
`blocked`, since nothing in the pane says anything is wrong, the session has
simply stopped producing output. Nogging already writes a pipe-pane log per
session (`scripts/session-log-writer`); the stall check reads that log's
mtime/size rather than hashing the pane on every poll, since the data already
exists.

## Decision 4 — Layer 2 for Claude is additive, never required

`session launch` wires `Stop` and `Notification` hooks into the per-session
effective-settings file (the same file `selectable-launch-profile` already
generates per session), each invoking `scripts/nogg session emit <event>`,
which appends one JSON line to `<name>.events.jsonl`:

```json
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "scripts/nogg session emit turn_end"}]}],
  "Notification": [{"hooks": [{"type": "command", "command": "scripts/nogg session emit needs_input"}]}]
}}
```

`watch` prefers `<name>.events.jsonl` over pane-scraping for a Claude session
once that file exists and has at least one line, and falls back to Layer 1
otherwise (an older session record predating this change, or a session whose
settings file could not be wired for some reason). This is strictly additive
— no existing hook entry in a profile's settings file is removed or
reordered — and it is Claude-only in this change; Decision 5 covers why Codex
Layer 2 is not included now.

## Decision 5 — Codex Layer 2 is a verification task, not an assumption

`codex queue --thread <THREAD> --message <TEXT>` and `codex agents` both
exist on the installed codex-cli (0.158.0) and read, on paper, like exactly
the structured channel #23 wanted in place of `tmux send-keys` for Codex
steering — `queue` in particular would remove the lost-message failure mode
at its root rather than detecting and retrying around it. But whether
`--thread` resolves a session `scripts/nogg` launched inside its own tmux
socket (rather than a bare `codex` process) was not observable during
planning (no live Codex session running). TASK-SOB-006 verifies this
directly; if it resolves, `session send --agent codex` uses `codex queue` as
its primary path with `tmux send-keys` kept as the fallback for a build or
configuration where it does not; if it does not resolve, `codex send` stays
on the Layer-1 pane-based implementation with no functional regression
either way.

## Decision 6 — capability placement

A new `session-observability` capability holds `watch`, `send`, `emit`, and
`resume-when-ready` as the primary spec surface — this is genuinely new,
cross-agent behavior, not a Claude-specific extension of `claude-sessions`
(which is explicitly scoped to tmux/metadata/log supervision, Claude-only, by
its own Purpose). Two small MODIFIED deltas land where the new behavior
touches existing requirements: `claude-sessions` gains a note that the
events file, where present, supplements (never replaces) the existing log
file; `agent-neutral-launch` gains a note that `session launch` additionally
wires the two Claude hooks described in Decision 4.

## Non-goals

- No new daemon or long-running background process — `watch` is a foreground
  command run under whatever already supervises the operator (a terminal, a
  `Monitor`-style host tool, a systemd unit, plain `tail -f` of its own
  output), exactly as #23 specifies.
- No auto-remediation beyond `resume-when-ready`'s one specific, narrow
  action (wait out a confirmed account-wide limit, then resume exactly what
  the operator asked for). `watch` itself never restarts, kills, or
  reconfigures a session — it emits events; the decision stays with whoever
  is watching them.
