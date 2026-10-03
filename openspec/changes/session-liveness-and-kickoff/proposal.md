# Session liveness and kickoff tooling

## Source

Four issues filed together against `JoMe92/nogging`, all from the same
`moviemakery2k` delivery run, all about the gap between "a session's tmux
process is alive" and "a session is actually doing something useful right
now":

- [#38](https://github.com/JoMe92/nogging/issues/38) — a Lead session
  launched without `--full-access` hangs silently in manual mode, with no
  warning at launch and no distinguishable state once it is.
- [#39](https://github.com/JoMe92/nogging/issues/39) — `session launch`
  deliberately never sends a first turn, but nothing says so; an operator or
  the Orchestration Agent has every reason to think it already started.
- [#41](https://github.com/JoMe92/nogging/issues/41) — nothing cross-
  references a running session's assigned Bead/change against Beads' own
  completion state, so a session whose work is already done, or already
  correctly self-blocked, looks identical to one still working.
- [#42](https://github.com/JoMe92/nogging/issues/42) — sessions pause
  between Beads despite `autonomous.md` saying to work "in order," and a
  bare `Enter` does not submit a pane with stale pre-filled text — only
  clearing the input line first and resending does.

## Why

All four were hit live across one 9-session delivery batch and all four
produce the same operator-visible symptom — a session sitting idle that
needs a human to notice and intervene — for four different, independently
fixable reasons. None of them is a request for a new capability from
scratch: this project already ships real session-liveness machinery
(`scripts/nogg session watch`, its per-agent `classify()` adapters, `session
send --verify`) from the archived `session-observability` change. This
change extends that machinery to close the specific gaps the incident
exposed, rather than building a parallel mechanism.

## Research performed

Read the current implementation directly, not only the issues' own
descriptions:

- `scripts/nogg`'s `CLAUDE_ADAPTER` (`classify()`'s pattern table) has no
  entry at all for Claude Code's permission-mode status line (`⏸ manual mode
  on` / `⏵⏵ auto mode on` / etc.) — #38's "no detectable state" claim is
  exactly right; `idle` only matches a bare `❯` prompt, which does not
  distinguish "genuinely between turns" from "sitting in manual mode with
  nothing to approve it."
- `session_send(name, message, verify=False)` always injects new literal
  text at the current cursor position (`tmux send-keys -l`) and only then
  submits — it has no "clear what's already there first" mode. Separately,
  `_pane_input_pending`, the function `verify`'s retry depends on, is
  structurally **Claude-blind today**: its docstring says plainly "claude has
  no such structural signal yet, so this is always False for it." So `send
  --verify`'s documented retry-on-unsubmitted behavior silently never
  triggers for the one agent #39/#42 are both about — a real, separate gap
  this change also closes, not only the two issues' own literal asks.
- #42's own reproduction (`tmux send-keys ... Enter` with no text, against a
  pane with stale pre-filled text, twice, no effect) never went through
  `session_send`/`_submit_pane_input` at all — it was raw `tmux send-keys`
  run by hand. Confirmed by reading `_submit_pane_input`: it always sends
  `Enter` (twice, for Claude's known multi-line-paste quirk) and never
  inspects or clears existing pane input first, so a hypothetical bare
  `session send <name> ""` would have hit the same wall.
- `session-observability`'s existing `classify()` states
  (`working`/`waiting_background`/`idle`/`needs_input`/`limit`/`stalled`/
  `ended`/`unknown`) have nothing resembling #41's "this session's own
  assigned work is already done" — confirmed by reading the full state enum
  and its scenarios; that cross-reference against Beads/PR state genuinely
  does not exist anywhere in the codebase yet.

## What changes

All of it extends the existing `session-observability` capability (one
already-shipped command surface), plus one prompt-wording change and one
`session launch` output change:

- **`.nogging/launch-prompts/autonomous.md`**: add an explicit "do not stop
  between Beads" sentence, immediately after the per-Bead cycle description.
  Closes #42's first mechanism.
- **`scripts/nogg session kickoff <name> [--message "..."]`** (new) and a
  **`--kickoff`** flag on `session launch` that chains it. Composes the
  canonical first-turn instruction from the session's own record
  (`role`, `bead_id`) when no `--message` is given. `session launch`'s own
  success output always names the missing step when `--kickoff` was not
  passed. Closes #39.
- **`scripts/nogg session nudge <name> [--message "..."]`** (new): clears
  the pane's input line first (`C-u`), then sends — either the given
  `--message`, or, with none given, whatever text was already sitting
  unsent in the pane (read back, not re-typed by the operator). Also fixes
  `_pane_input_pending`/`send --verify`'s Claude-blind detection by giving it
  a real, agent-generic "is there pending input, and what does it say"
  reader instead of the codex-only structural signal. Closes #42's second
  mechanism.
- **A new `awaiting_manual_approval` classification state** in `classify()`
  (Claude-only; reads the permission-mode status line), plus a loud,
  one-line warning printed by `session launch` itself when a `lead`/
  `specialist:*` role resolves to the bare restricted default with no
  `--profile`/`--prompt`/`--full-access` given. Closes #38.
- **`scripts/nogg session sweep`** (new): for every running session, resolves
  its `bead_id`'s `openspec:change:` label and reports `change-complete`
  (every Bead in that change `closed`, PR `MERGED` if one exists),
  `bead-blocked` (its own or a dependency Bead is `blocked`), `has-unsent-input`
  (pane shows pending text — the same reader `nudge` uses), or `active`.
  Detection only; it never stops or nudges a session itself. Closes the core
  of #41.
- **`scripts/nogg doctor`**: surfaces every running session `sweep` would
  flag as `awaiting_manual_approval`, `change-complete`, or `bead-blocked`,
  in one pass, as `NOTE` lines — the single-command version of the nine-way
  manual `tmux capture-pane` audit the incident needed.

## Out of scope

- Auto-stopping, auto-nudging, or otherwise acting on a `sweep`/`doctor`
  finding without an operator or the Orchestration Agent deciding to. This
  change is detection and tooling only, exactly as #41 itself scopes it.
- Whether Claude Code's own idle-suggestion-text UI should be reported
  upstream as a harness issue — noted in #41/#42 as a separate, non-Nogging
  question.
- `harden-trusted-session-authority` (already planned separately, GitHub
  #40) and the dependency-aware launch refusal (GitHub #37, planned
  separately next) — adjacent, independently scoped.
