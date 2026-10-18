## Why

Sources: [GitHub #235](https://github.com/JoMe92/nogging/issues/235) and
[GitHub #236](https://github.com/JoMe92/nogging/issues/236), plus the Codex
discovery notes on Bead SPEC-t374 (TASK-RSI-009 acceptance, 2026-10-18).

- **#235.** `session launch --bead supply-doc-v0zu.1` fails: tmux rewrites `.`
  in a session name to `_`, but Nogging keeps addressing the dotted name, so
  `pipe-pane -t` parses it as `session.pane` and fails. The record is marked
  `failed`, `session stop` reports "nothing to do", and the renamed tmux session
  keeps running the agent outside supervision.
- **#236.** A kickoff reported as sent can sit unsubmitted in the composer. The
  reporter ran a vendored copy that may predate the reliable-session-input fixes
  (#207, #216, #218), so what is already fixed on current develop had to be
  separated from what still fails. Reproduced against develop at `2822000`:
  Claude's collapsed paste, clipped composer and startup readiness are fixed and
  covered; three Codex failures still reproduce or are recorded from live runs.

## What Changes

- Session names are made backend-safe by one shared helper (`.` and `:` become
  `_`). Generation, both backends' name guard and every later target use the same
  name, and the record stores it. herdr pane and tab labels follow it.
- Any failure after the backend session or pane was created and before the
  session is running and settled removes what Nogging created, on tmux and
  herdr, so no unsupervised orphan survives a failed launch.
- Codex's collapsed `[Pasted Content N chars]` composer placeholder counts as the
  operation's own pending paste when the composer was verified empty first, so
  `session kickoff`, `send` and `nudge` of a ~1000-character message are no
  longer refused with the text already in the box.
- A Codex kickoff waits until the startup turn has finished (rollout evidence of
  the exact thread), and Enter for Codex is only pressed once the turn is not
  running, so the first-turn acknowledgement can no longer swallow the Enter.
- `codex queue` is no longer called for a busy Codex session, where its
  acceptance is observed to be lost. The send waits boundedly for idle, then
  proves delivery with a fresh receipt, or refuses naming the busy state.
- A tmux session launched from a caller that cannot see the pane PID (a fenced
  Codex Lead using the host socket) no longer ends with null
  `session_pid_start`/`session_pid_ns`: identity comes from a wrapper receipt,
  and a planning launch with no provable identity is refused and cleaned up
  instead of producing a planner that can never take the planning lock
  (HPS-007 step 4). Diagnostic-first: it must reproduce before it is fixed.
- Operator guidance, a changelog entry and an unsigned host acceptance report.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-backends`: backend-safe session names on tmux and herdr, no orphan
  backend session after a failed launch, and a provable process identity for a
  planning session launched across PID namespaces.
- `session-observability`: Codex collapsed-paste placeholder, Codex startup-turn
  readiness with turn-gated Enter, and the busy-session rule for `codex queue`.

Both capabilities receive only ADDED requirements. The still-unarchived
`reliable-session-input` change MODIFIES neighbouring requirements, so
modifying the same headers here would make the two changes conflict on archive.

## Impact

- `scripts/nogg`: name generation, the `_session_launch` failure path, the Codex
  composer classification, readiness, delivery and queue functions.
- `scripts/lib/session_backend.py`, `session_backend_tmux.py`,
  `session_backend_herdr.py`: shared name helper, guards, start-failure cleanup.
- `scripts/lib/session_codex_delivery.py` (already shipped via
  `bin/lib/manifest.js`): a pure turn-state reader beside the receipt reader.
- New focused suites under `scripts/*.test.sh`, each failing first on current
  develop and each running the real delivery or launch code.
- `docs/running-work-in-sessions.md`, `docs/using-with-codex.md`,
  `docs/failure-recovery.md`, `CHANGELOG.md` (Unreleased) and one unsigned
  acceptance report.

Out of scope: changing `reliable-session-input`'s approved behaviour, Antigravity
and Pi delivery, a Codex-side fix for `codex queue`, automatic trust grants,
orchestrator restart (#161), and any human sign-off. Planning does not
implement, claim execution Beads or push.
