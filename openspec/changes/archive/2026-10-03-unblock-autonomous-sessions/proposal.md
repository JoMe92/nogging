# Unblock autonomous sessions

## Source

Three issues filed against `JoMe92/nogging`, triaged together by the
Orchestration Agent as "Group A" — small, independently diagnosed blockers
that each stop a `--full-access` / unattended session from making progress at
all, as opposed to a feature request or a larger design question:

- [#15](https://github.com/JoMe92/nogging/issues/15) — autonomous Lead
  sessions block indefinitely on `EnterWorktree`'s permission-root relocation
  prompt
- [#16](https://github.com/JoMe92/nogging/issues/16) — unattended Lead
  sessions hang on the first Bash-approval prompt because the `trusted`
  profile's `defaultMode` is `acceptEdits`, not `auto`
- [#17](https://github.com/JoMe92/nogging/issues/17) — a Codex session in a
  worktree cannot reach the shared checkout's `.git`/`.beads` because the
  `workspace-write` sandbox only covers `--cd`'s target

## Why

All three were hit live, running real autonomous/unattended delivery
sessions, and each one stops a session from doing *any* work — not a
degraded experience, a hang that needs a human to notice and intervene. The
whole point of the `trusted` + `autonomous` pairing (`--full-access`) and of
the Codex agent path is that a session can run genuinely unattended; these
three gaps each defeat that for a different reason:

- #15 and #16 both hit on the **very first** qualifying tool call of a fresh
  `--full-access` Lead session — before any real work happens.
- #17 hits as soon as a Codex Lead or specialist session in a worktree runs
  the `git commit`/`push` or `bd`/`scripts/nogg` command that Nogging's own
  workflow asks it to run routinely.

Each issue's reporter already diagnosed the root cause and proposed (and, for
#15 and #17, locally verified) a fix. This change's job is to verify those
fixes independently against current tool behaviour, decide exactly where each
belongs in Nogging's own spec and code, and make them official.

## Research performed

Verified independently during this planning session, not taken on the
issues' word alone:

- **#15** — fetched `https://code.claude.com/docs/en/worktrees.md` directly.
  Confirmed verbatim: *"When Claude enters a path outside the repository's
  `.claude/worktrees/` directory, Claude Code asks for your approval first...
  An `EnterWorktree` permission rule or choosing 'don't ask again' doesn't
  suppress this prompt; only `bypassPermissions` mode skips it."* This is
  documented, intentional hardening added in Claude Code v2.1.206 (before
  that version, Claude could enter any existing worktree path without
  asking). Nogging's `trusted` profile deliberately uses `acceptEdits`/`auto`
  rather than `bypassPermissions` specifically to avoid a blanket bypass, so
  this prompt is unsuppressible for every `--full-access` Lead session that
  lets the model use `EnterWorktree`. The same docs page confirms a plain
  Bash `cd` is a completely different mechanism — it does not register the
  session as "isolated in a worktree" and so is not gated by this check (or
  by the related worktree-isolation Bash/Edit checks, which Nogging does not
  need from Claude Code since it has its own `PreToolUse` boundary guard).
- **#16** — fetched `https://code.claude.com/docs/en/permission-modes`.
  Confirmed `auto` is a distinct, named mode from `acceptEdits`, available as
  an explicit `defaultMode`/`--permission-mode` value since Claude Code
  v2.1.228, and that *"In the Manual and `acceptEdits` permission modes, when
  auto mode is available, Claude Code adds **Yes, and switch to auto mode**
  to a Bash command's permission prompt"* (requires v2.1.247+) — matching the
  issue's described prompt exactly. The installed Claude Code on the
  delivery host is v2.1.260, comfortably above both thresholds.
- **#17** — ran `codex --help` and `codex exec --help` against the installed
  `codex-cli 0.158.0` directly (newer than the 0.154.0 the issue verified
  against). Confirmed verbatim: `--add-dir <DIR>` — *"Additional directories
  that should be writable alongside the primary workspace."* This is a plain
  CLI flag, not only a config key, and matches the flag style
  `scripts/session-launch`'s `codex)` branch already uses for `--cd`,
  `--sandbox`, `--ask-for-approval`.

See `design.md` for the two material risks this research also surfaced (an
availability dependency for #16's fix, and a scope decision on which docs
tables to update) and how this change handles each.

## What Changes

- **`.nogging/launch-prompts/autonomous.md`** instructs the session to enter
  its allocated worktree with a plain Bash `cd`, and explicitly not with the
  `EnterWorktree` tool.
- **`.nogging/launch-profiles/trusted.json`** sets
  `permissions.defaultMode` to `"auto"` instead of `"acceptEdits"`.
- **`scripts/session-launch`**'s `codex)` branch passes `--add-dir
  <shared-checkout-root>` unconditionally, alongside `--cd <worktree>`, at
  every authority level.
- Matching spec deltas land in the `agent-worktrees`, `launch-profiles`, and
  `codex-onboarding` capabilities (one new requirement each — nothing here
  removes or weakens an existing requirement).
- `docs/operating-model.md`, `docs/running-work-in-sessions.md`, and
  `docs/using-with-codex.md` are reconciled with the new behaviour where they
  currently describe the old one.

## Out of scope

- Session-monitoring / usage-limit auto-resume (GitHub #19–#23) and the
  OpenSpec-progress-tracking gap (#24) are separate, larger planning
  questions — triaged but deliberately not folded into this change.
- No new `doctor` check is added for the model/provider availability
  dependency `auto` mode has (see `design.md`, Risk 1). That stays a
  candidate follow-up discovery, not a task here, to keep this change scoped
  to the three issues the Product Owner selected.
