# Tasks — session observability

- [ ] TASK-SOB-001 Add the `Adapter` data shape (`design.md` Decision 1) and
      ship the `claude` and `codex` pattern tables verbatim as specified.
      Implement classification: strip `ignore` matches from the last ~15
      pane lines, then check states in precedence order
      (`limit` > `needs_input` > `working` > `waiting_background` > `idle`,
      else `unknown`). Add a fixture-based test per agent using recorded pane
      captures (no live agent required), including the specific
      `Auto-update failed` false-positive regression case.

- [ ] TASK-SOB-002 Add `scripts/nogg session watch [--all-running | <name>...]
      [--interval 30] [--stall-after 15m] [--format lines|jsonl]`. Poll each
      named session (default: every live session from `session list`),
      classify via TASK-SOB-001's adapters keyed off the session record's own
      `agent` field, and emit one event per state transition plus `stalled`
      (pane/log unchanged for `--stall-after` while last known state was
      `working`) and `ended` (tmux session gone). `--format jsonl` emits the
      structured shape from `design.md`; the default is human-readable lines.

- [ ] TASK-SOB-003 Add usage-limit parsing (`design.md` Decision 2): extend
      the `limit` pattern match to extract the stated `HH:MM`/`H:MM AM/PM`
      and resolve it to an absolute ISO 8601 timestamp against the host's
      current local date, rolling to the next day when the parsed time
      precedes the current time. Carry it in the `limit` event as
      `until=<ISO8601>`. Add the "switching models does not clear this"
      note to `docs/nogging/failure-recovery.md` and
      `docs/nogging/using-with-codex.md`.

- [ ] TASK-SOB-004 Add `scripts/nogg session resume-when-ready <name>
      [--message "..."]`. Use `watch` to detect the `limit` state and read
      its parsed `until` timestamp; sleep until then (falling back to a
      bounded poll cadence if the timestamp could not be parsed — never a
      tight spin-loop). Once the state is no longer `limit`, if a residual
      "switch model?" prompt is on screen, dismiss it by keeping the current
      model. Send the resume instruction via TASK-SOB-005's `session send`
      (default message: a generic "the usage limit has reset, continue
      exactly where you left off per your original instructions"; `--message`
      overrides it). Log the action the same way other `scripts/nogg` session
      actions are recorded.

- [ ] TASK-SOB-005 Add `scripts/nogg session send <name> "<message>"
      [--verify]`. Sends the message via the agent-appropriate key-injection
      sequence (Claude Code: paste plus a second bare `Enter`, per the known
      quirk). With `--verify`, capture the pane after sending and confirm the
      message was actually submitted (not left sitting in the input box, the
      `codex` adapter's `needs_input`/`undelivered_input` signal from
      TASK-SOB-001); retry the submit step once if not.

- [ ] TASK-SOB-006 Verify `codex queue --thread <THREAD> --message <TEXT>`
      against a session `scripts/nogg session launch --agent codex` actually
      started (not a bare `codex` process) — does `--thread` accept that
      session's name or UUID and deliver the message. If it resolves, make it
      `session send`'s primary path for `--agent codex`, keeping the
      Layer-1 pane-based send as the fallback. If it does not resolve,
      record why in a Bead note and leave `codex send` on the Layer-1
      implementation with no further action required by this task.

- [ ] TASK-SOB-007 Add Claude Layer 2 (`design.md` Decision 4): `scripts/nogg
      session emit <event>` appends one structured JSON line (timestamp,
      session name from the environment, event) to `<name>.events.jsonl`.
      `session launch` (Claude only) adds the `Stop` and `Notification` hook
      entries shown in `design.md` to the per-session effective-settings
      file it already generates, without removing or reordering any existing
      hook entry. `watch` prefers this file over pane-scraping for a Claude
      session once it has at least one line.

- [ ] TASK-SOB-008 Run `scripts/test`. Manually verify end to end: launch a
      real session, drive it into each adapter state where practical
      (working, idle, a permission prompt for `needs_input`), confirm
      `watch --format jsonl` emits exactly one event per transition and
      nothing while steady-state; confirm the `Auto-update failed` banner
      alone, with background shells running, classifies as
      `waiting_background`, never `attention`/`unknown`.
