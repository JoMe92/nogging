# Harden trusted session authority

## Source

[#40](https://github.com/JoMe92/nogging/issues/40) — shipped `trusted.json`
uses `permissions.defaultMode: "auto"`, and a `--full-access` Lead session
still hit roughly 6 interactive approval prompts across 9 sessions in one
delivery run, contradicting `--full-access`'s own documented promise of a
genuinely unattended session.

## Why

This is not a new defect — it is the **exact, already-known, already-accepted
risk** recorded in this project's own `design.md` for the archived
`unblock-autonomous-sessions` change (which put `"auto"` in `trusted.json` to
fix #16):

> **Risk — `auto` mode has an availability dependency `acceptEdits` does
> not.** ... When auto mode is requested but unavailable, Claude Code does
> not error — it silently starts the session in Manual mode instead, which is
> *more* blocking than `acceptEdits` was, not less. ... Accepted as a known
> limitation for this change: no `doctor` check is added to detect and warn
> on this ... Left as a candidate follow-up discovery rather than a task
> here.

#40 is that follow-up arriving from real, live operation: a downstream
project (`moviemakery2k`) ran 9 `--full-access` Lead sessions and had to
manually resolve interactive prompts on at least 6 of them via `tmux
send-keys`, including the exact "Yes, and switch to auto mode" escalation
that only appears **when a session is not already in auto mode** — direct
evidence that some of those sessions silently fell back to Manual, invisibly,
exactly as the risk predicted.

Independently of the fallback risk, `auto` mode is also structurally weaker
than `bypassPermissions` for a session Nogging has already decided should run
genuinely unattended: per Claude Code's own documentation, `auto` routes
protected-path writes and other sensitive actions through a second,
classifier-model review rather than allowing them outright, and that
classifier can still deny an action with nobody present to retry it from
`/permissions`. `bypassPermissions` has no such gate and no model/account
availability dependency — the tradeoff the original change deliberately
avoided ("to avoid a blanket bypass of every other check") turns out, in
practice, to cost exactly the unattended reliability `--full-access` promises.

## Research performed

Verified directly against current primary documentation during this planning
session (not taken from any issue's own claims alone):

- Fetched `https://code.claude.com/docs/en/permission-modes` directly.
  Confirmed: `permissions.defaultMode: "auto"` and `"bypassPermissions"` are
  silently ignored **only** when set in `.claude/settings.json` or
  `.claude/settings.local.json` — "the other values apply from any settings
  file." A profile delivered via `--settings <path>` (exactly how
  `scripts/nogg session launch` passes every profile, including `trusted`) is
  **not** one of the two excluded files, so this is not the mechanism behind
  #40's symptoms. (An earlier research pass in this same conversation
  incorrectly concluded `--settings`-delivered `"auto"` was silently ignored;
  this was wrong — it conflated the `defaultMode` restriction with a
  different, narrower restriction on the `autoMode.environment`/`allow`/
  `deny` *classifier-configuration* block, confirmed separately via
  `https://code.claude.com/docs/en/auto-mode-config`, which **is** readable
  from `--settings`. Corrected here before it reached the spec.)
- Confirmed the real mechanism instead: auto mode has a model/provider
  availability requirement (`https://code.claude.com/docs/en/permission-modes`:
  "auto mode is unavailable when the session doesn't meet the availability
  requirements ... or when Anthropic has temporarily turned it off
  server-side" → silent fallback to Manual, no error, no warning) — exactly
  the risk this project's own prior design.md already named and deferred.
- Confirmed the protected-paths behavior difference directly from the same
  page's table: `bypassPermissions` → "Allowed"; `auto` → "Routed to the
  classifier"; and confirmed `bypassPermissions` activation via `--settings`
  needs `skipDangerousModePermissionPrompt: true` as a companion key (same
  page: "the first time you start an interactive session with this mode
  enabled, Claude Code shows a warning dialog ... If you accept: Claude Code
  sets `skipDangerousModePermissionPrompt` to `true`"), which this repository
  already discovered and applies for `orchestrator.json` (`TASK-ORC-001`,
  this project's own Beads history) but never carried over to `trusted.json`
  when `unblock-autonomous-sessions` separately changed its `defaultMode`.
- Cross-checked `.nogging/launch-profiles/trusted.json` and `orchestrator.json`
  directly: `trusted.json` has neither `bypassPermissions` nor
  `skipDangerousModePermissionPrompt`; `orchestrator.json` has both and is
  live, working production evidence that the `--settings`-delivered pairing
  functions correctly in this project's own tmux-pane launch path.

## What changes

- `.nogging/launch-profiles/trusted.json`: `permissions.defaultMode` becomes
  `"bypassPermissions"`; add top-level `"skipDangerousModePermissionPrompt":
  true`. The existing `deny` list (`sudo`, `rm -rf`/`-fr`, `dd`, `mkfs`,
  `shutdown`, `reboot`, `systemctl`, `curl`, `wget`, `WebFetch`) is unchanged
  and becomes the profile's sole safety boundary, exactly as it already is for
  `orchestrator.json`.
- `scripts/nogg doctor`: a new check flags an installed `trusted.json` (or any
  profile a project customized) whose `defaultMode` is more cautious than
  documented, or that sets `bypassPermissions` without
  `skipDangerousModePermissionPrompt` — catching both config drift and the
  specific pairing mistake this change itself fixes.
- `docs/security-model.md`: document the shipped `defaultMode`, why it is
  `bypassPermissions` rather than `auto` (the classifier's availability
  dependency and protected-path gating, not merely "more permissive"), and
  that the `deny` list is the real, mode-independent boundary — so a project
  that deliberately wants the classifier's extra review for its own `trusted`
  copy knows what it is trading away by customizing the profile.
- Spec delta on `launch-profiles`: replace the existing "does not block on a
  first-time Bash approval prompt" requirement (written against `auto`) with
  one stating the actual, stronger guarantee now shipped, plus a new
  requirement for the `doctor` drift check.

## Out of scope

- Switching the `restricted` profile's `defaultMode`. Restricted sessions are
  interactive-by-design (`no-autonomous-claim.md`); this change only concerns
  unattended `--full-access` authority.
- The separate, still-open `agent-commit-identity` Tier 2 work and any other
  in-flight change. This is a small, independent profile/doctor/docs fix.
- Everything about *detecting a session's current state* (manual vs. working
  vs. done) — #38, #39, #41, #42 are planned as their own change
  (`session-liveness-and-kickoff`), since they are about visibility/tooling
  across every profile, not about which authority `trusted` itself grants.
