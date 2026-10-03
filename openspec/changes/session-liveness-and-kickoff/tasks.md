# Tasks — session liveness and kickoff tooling

- [ ] TASK-SLK-001 In `.nogging/launch-prompts/autonomous.md`, immediately
      after the per-Bead cycle description (claim, implement, validate,
      commit, note, close), add: "Immediately continue to the next ready
      Bead in the same change after closing one — do not end your turn, wait
      for confirmation, or pause between Beads. Keep going without stopping
      until every Bead in the named change is closed or blocked, or the PR
      is open and green." Do not change `no-autonomous-claim.md` (interactive
      sessions wait for the operator by design). Closes GitHub issue #42's
      first mechanism.

- [ ] TASK-SLK-002 In `scripts/nogg` (Python), add a pending-input-text
      reader: capture the pane (reuse the existing tmux-capture helper
      `watch`/`classify` already use), take its last non-empty line, and for
      a Claude session strip a leading `❯` plus whitespace, returning the
      remainder (empty string if the line was bare `❯` or blank). Replace
      `_pane_input_pending`'s Claude branch (today hardcoded `False`) with
      "the reader returns a non-empty string" instead of the unconditional
      `False`; leave the Codex branch (`needs_input`/`Pasted Content`)
      unchanged. This single reader is shared by TASK-SLK-003 and
      TASK-SLK-005 below — implement it once.

- [ ] TASK-SLK-003 Add `scripts/nogg session nudge <name> [--message TEXT]`:
      refuse with a clear error (no tmux interaction) if the named session is
      not `running`. Otherwise send `tmux send-keys -t <name> C-u` first,
      then: with `--message`, send that text via the same literal-injection +
      submit path `session_send` already uses; with no `--message`, read the
      pane's pending text with TASK-SLK-002's reader *before* clearing it —
      if empty, print that there was nothing to nudge and send nothing
      further (the `C-u` already ran but clearing an empty line is a no-op);
      if non-empty, resend exactly that text after clearing. Closes GitHub
      issue #42's second mechanism.

- [ ] TASK-SLK-004 Add `scripts/nogg session kickoff <name> [--message
      TEXT]`: refuse with a clear error if the named session is not
      `running`. With `--message`, send it verbatim via `session_send`. With
      no `--message`: require a `bead_id` on the session record (refuse with
      a clear error naming the session if absent — this excludes
      `orchestrator` sessions, which have none); resolve the Bead's
      `openspec:change:` label via `bd show <bead_id> --json`; compose and
      send an instruction naming the Bead ID and the change by name,
      directing the session to claim it and proceed through that change's
      `tasks.md` in order. Add a `--kickoff` flag to `session launch` that
      calls this immediately after a successful launch. When `session
      launch` returns without `--kickoff`, its existing success output (the
      `launched`/`bead=`/`log=`/`attach=` lines) gains one more line:
      `kickoff: this session will not act until you send it a first message
      — run \`nogg session kickoff <name>\` or attach and type one
      yourself.` Closes GitHub issue #39.

- [ ] TASK-SLK-005 In `classify()`'s `Adapter` dataclass, add a
      `manual_mode` pattern field. For `CLAUDE_ADAPTER`, set it to match the
      literal `⏸ manual mode on` status-bar text. In `classify()`, after the
      existing precedence order would resolve to `idle`, additionally check
      `manual_mode`: if it matches, return `awaiting_manual_approval`
      instead of `idle`. Add `awaiting_manual_approval` alongside the other
      named states wherever the full enum is documented/asserted. Separately,
      in `session_launch`, when `role_meta == "lead"` or
      `role_meta.startswith("specialist:")` and the caller passed none of
      `profile`, `prompt`, or `full_access` (check the raw arguments, not the
      resolved pair), print one line after the existing launch-output lines:
      `⚠ <name> launched in restricted/manual mode — it will not act without
      a human attached to approve each step; pass --full-access (or an
      explicit --profile/--prompt) for unattended operation.` Closes GitHub
      issue #38.

- [ ] TASK-SLK-006 Add `scripts/nogg session sweep`: for every session
      `session list` would show as `running`, resolve its `bead_id`'s
      `openspec:change:` label and the full set of Beads materialized under
      that label (`bd list --label openspec:change:<name> --json`). Report,
      per session, one of: `change-complete` (every Bead in that set is
      `closed`, and if `gh pr list --head <branch> --json state` for the
      session's worktree branch returns a PR, its `state` is `MERGED`),
      `bead-blocked` (the session's own Bead or any Bead in the same set has
      `status: blocked` — name the blocking Bead ID), or `active` (neither).
      Alongside that state, on the same line, report `has-unsent-input: yes`
      or `no` using TASK-SLK-002's reader (non-empty pending text), and an
      `idle for Nm` figure derived from the newest file mtime under the
      session's worktree plus its log file's mtime, whichever is more
      recent. Detection only — `sweep` never stops, nudges, or otherwise
      changes any session or Bead. Closes the core of GitHub issue #41.

- [ ] TASK-SLK-007 In `scripts/nogg doctor`, call TASK-SLK-006's sweep logic
      internally (not a shell-out to the `sweep` subcommand — share the
      Python function) and print one `NOTE` per running session whose state
      is `awaiting_manual_approval` (TASK-SLK-005), `change-complete`, or
      `bead-blocked` (TASK-SLK-006), naming the session and the reason.
      `doctor` does not report `has-unsent-input` or the idle-duration
      figure — those stay `sweep`-only detail, per `design.md` Decision 4.

- [ ] TASK-SLK-008 Update the `session-observability` spec delta (see
      `specs/session-observability/spec.md` in this change) and run
      `scripts/nogg validate`. Add/extend `scripts/nogg.test.sh` and
      `scripts/session-observability.test.sh` cases covering: the pending-
      text reader against a fixture pane with trailing text vs. a bare
      prompt; `nudge` with and without `--message`, against both an empty
      and a non-empty pane, asserting the `C-u` is sent before any text;
      `kickoff` refused on a non-running session and on a bead-less session
      with no `--message`, and composing the expected message otherwise;
      `--kickoff` chaining on `launch`; the launch-time warning firing only
      for `lead`/`specialist:*` with no explicit profile/prompt/full-access,
      and never for `orchestrator`; `classify()` returning
      `awaiting_manual_approval` for a fixture pane showing `⏸ manual mode
      on` at an otherwise-idle prompt, and plain `idle` for a working-mode
      status line; `sweep` reporting `change-complete`/`bead-blocked`/
      `active` against fixture Beads data; `doctor` surfacing exactly the
      three flagged states and nothing else. Run `scripts/test` and confirm
      it passes.
