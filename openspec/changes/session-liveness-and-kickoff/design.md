# Design — session liveness and kickoff tooling

## Decision 1 — `nudge` reads back pending text; it does not require the operator to retype it

#42's own evidence resent the *exact same* stale text after clearing the
line — the operator read it off the pane and retyped it. `session nudge
<name>` with no `--message` automates that read-back instead of requiring an
operator to eyeball and retype: capture the pane, take its last non-empty
line, strip a leading prompt marker (`❯` for Claude; Codex has its own
distinct idle shape and is handled by its existing `needs_input` adapter
path, not this new reader), and treat the remainder as the pending text. If
that remainder is empty, there is nothing to nudge — report so and send
nothing (a `C-u` with no message would be a no-op anyway, but the command
should say so rather than silently doing nothing). With an explicit
`--message`, `nudge` always clears first regardless of what the pane shows,
then sends that text — this is the "operator wants to override whatever is
sitting there" path.

This same pending-text reader replaces `_pane_input_pending`'s Claude branch,
which today unconditionally returns `False` for Claude ("no structural
signal yet" — true in the sense that there is no equivalent of Codex's
`Pasted Content` marker, but a non-empty-after-prompt pane line is a
perfectly good one that was simply never read). `send --verify`'s existing
retry-once behavior starts actually firing for Claude sessions as a direct
consequence, not as a separate task — this was a latent correctness gap
in already-shipped code, not a new feature.

## Decision 2 — `kickoff` composes from the session record; it never invents a Bead

`session kickoff <name>` with no `--message` needs the session's own
`bead_id` and `role` (both already in `<name>.json`) to compose anything
meaningful. For a `lead`/`specialist:*` session with a `bead_id`, the
composed message names that Bead and its `openspec:change:` label's change
by name, instructing the session to claim it and proceed through that
change's `tasks.md` in order — the same shape #39's own incident used by
hand. For a session with no `bead_id` (there is none today, since every
`session launch` role except `orchestrator` already requires one, and
`orchestrator` is never kicked off this way — it is a standing, always-on
persona, not a one-shot task session), `kickoff` with no `--message` refuses
with a clear error rather than guessing. `--message` always overrides the
composed default, for an operator who wants different phrasing or is kicking
off a planning/specialist session with its own framing (per #39's own
proposal).

`--kickoff` on `session launch` chains this immediately after a successful
launch, for the common case where the caller already knows the session
should start now. It remains opt-in: a bare `session launch` behaves exactly
as before, except its own success output now names the missing step and the
exact follow-up command — closing the silence #39 is about without removing
the deliberate checkpoint `no-autonomous-claim.md`-style interactive sessions
still rely on.

## Decision 3 — `awaiting_manual_approval` is a Claude-only classify addition, not a new top-level command

`classify()`'s existing precedence order (`limit` > `needs_input` >
`working` > `waiting_background` > `idle`, else `unknown`) already runs
against the last ~15 pane lines. Claude Code's permission-mode status line
(`⏸ manual mode on`, `⏵⏵ accept edits on`, `⏵⏵ auto mode on`, `⏵⏵ bypass
permissions on`) is reliably one of those last lines whenever the pane is
idle. Add `manual_mode` as a new `Adapter` field, checked only when the
existing order would otherwise return `idle`: if the pane's idle and the
status line reads `⏸ manual mode on`, report `awaiting_manual_approval`
instead of plain `idle`. This is additive — every existing scenario for
`working`/`needs_input`/etc. is unaffected, since the new check only
narrows what `idle` would have reported, and only for Claude (Codex has no
equivalent permission-mode status line to read).

The **loud launch-time warning** is a separate, independent half of the
same fix, at a different point in time (launch, not classification): inside
`session_launch`, when `role_meta in ("lead",) or role_meta.startswith(
"specialist:")` and the *caller's own, unresolved* `profile`/`prompt`/
`full_access` arguments are all absent (not the resolved pair — the point is
to warn exactly when nothing was explicitly asked for), print the one-line
`⚠` warning to the launching terminal's stdout, after the existing
`launched`/`bead=`/`log=`/`attach=` lines. `--role orchestrator` is
unaffected (it never reaches this branch; `normalize_role` keeps it
separate).

## Decision 4 — `sweep` is read-only detection; it reuses `bd show`/`gh pr`, not a new state store

`change-complete` and `bead-blocked` are derived, not persisted: for a
running session's `bead_id`, resolve its `openspec:change:` label (already
present on every materialized Bead), then `bd list --label
openspec:change:<name> --json` for every Bead in that change. `change-
complete` is every one of them `closed` **and**, if a PR exists for the
session's own worktree branch (`gh pr list --head <branch> --json state`,
best-effort — a session with no pushed branch yet simply has no PR to
check), that PR's `state` is `MERGED`. `bead-blocked` is the session's own
Bead, or any Bead in the same change, currently `status: blocked`. Neither
check mutates anything; a session's own worktree, branch, and Bead state are
read exactly as `doctor`'s other checks already read them elsewhere in this
file.

`has-unsent-input` reuses Decision 1's pending-text reader directly (a
boolean "is it non-empty", not the text itself, for this summary line) so
`sweep`/`doctor` and `nudge` agree on exactly what counts as "something
sitting unsent" — one reader, two call sites.

The **activity-timeout fallback** (#41 proposal item 3: newest worktree
file-mtime, surfaced as "idle for Nm") is added to `sweep`'s per-session line
unconditionally, alongside whichever of the above states applies (or
`active` when none do) — it is a second, independent signal shown next to
the Bead-aware one, not a replacement classification, exactly as #41's own
proposal frames it ("so an operator sees both signals together").

`doctor` calls the same `sweep` logic internally and prints a `NOTE` per
running session flagged `awaiting_manual_approval`, `change-complete`, or
`bead-blocked` — it does not duplicate the detection logic, and it does not
report `has-unsent-input` or the activity-timeout figure as `NOTE`s (those
stay `sweep`-only detail; `doctor`'s job is a short, actionable summary, not
`sweep`'s full report).

## Non-goals

- No auto-stop, auto-nudge, or auto-kickoff triggered by `doctor`/`sweep`
  findings. Every new command here is invoked explicitly; detection and
  action stay separate, per #41's own scoping.
- No change to the Codex or Pi paths for any of the four new/changed
  commands beyond what already exists (`codex_queue_send` is untouched;
  `nudge`'s pending-text reader is Claude-specific, Codex keeps its own
  `needs_input` structural signal via `Pasted Content`).
- No change to `harden-trusted-session-authority`'s `trusted.json`
  authority decision — #38's loud warning fires regardless of which
  profile ends up resolved; it is about *silence*, not about which
  authority is correct.
