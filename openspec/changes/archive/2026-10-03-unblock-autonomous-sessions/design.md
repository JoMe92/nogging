# Design — unblock autonomous sessions

## Decision 1 — #15 is a prompt-wording fix, not a code fix

`EnterWorktree`'s relocation prompt is Claude Code's own intentional, hard-
coded safety check (confirmed against current docs; added in v2.1.206), and
nothing in Nogging's permission profiles can suppress it short of granting
`bypassPermissions` — which Nogging deliberately withholds from `trusted` to
avoid a blanket bypass of every other check. There is therefore no settings-
level fix. The only lever is **which tool the agent chooses** to enter the
worktree `scripts/nogg worktree implement` already allocated for it: a plain
`cd <path>` inside a Bash call is not an "enter a worktree" action in Claude
Code's model at all, so it is never gated by this check.

This means the fix is entirely in `.nogging/launch-prompts/autonomous.md`'s
wording — add an explicit instruction, directly beside the existing worktree-
allocation bullet, to `cd` into the allocated path with Bash and never call
`EnterWorktree` for it. `no-autonomous-claim.md` does not need the same
addition: that prompt's sessions wait for explicit operator direction before
claiming or starting any Bead, so they do not autonomously allocate and enter
a worktree in the first place.

## Decision 2 — #16's fix is a one-line config change, with one accepted risk

`permissions.defaultMode: "auto"` in `trusted.json` is the direct fix. Two
things worth being explicit about, both confirmed against current docs:

**Risk — `auto` mode has an availability dependency `acceptEdits` does not.**
Auto mode requires Claude Code ≥ v2.1.228 (met: this host runs v2.1.260) *and*
a supported model/provider tier (Opus 4.6+, Sonnet 4.6+, or a Fable model on
the Anthropic API; a narrower list on Bedrock/Vertex/Foundry). When auto mode
is requested but unavailable, Claude Code does not error — it silently starts
the session in Manual mode instead, which is *more* blocking than
`acceptEdits` was, not less. Nogging's own sessions currently run on the
Claude 5 family (Sonnet 5 / Opus 5), well above the threshold, so this does
not block adoption — but it means the fix is conditional on the operator's
model/account, not unconditionally safe the way a pure permission-narrowing
change would be. Accepted as a known limitation for this change: no `doctor`
check is added to detect and warn on this (would need to shell out to `claude
auto-mode defaults` or inspect account/model state, which is more than a
one-line fix). Left as a candidate follow-up discovery rather than a task
here.

**Non-risk — the existing `allow`/`deny` lists are unaffected.** Per the
docs, deny rules "block in every mode, including `bypassPermissions`", so
`trusted.json`'s floor-adjacent denies (`sudo`, `rm -rf`, `dd`, `mkfs`,
`shutdown`, `reboot`, `systemctl`, `curl`, `wget`, `WebFetch`) are unchanged.
Auto mode does drop a narrow class of broad *allow* rules on entry — "Blanket
`Bash(*)`... wildcarded interpreters... package-manager run commands" — which
could affect `trusted.json`'s `Bash(npx:*)` allow entry specifically. This is
not a safety regression: a dropped blanket allow rule means the action falls
through to the auto-mode classifier instead of being pre-approved, and
routine `npx` invocations fall under the classifier's own "installing
dependencies declared in lock files" default-allow bucket. Documented here so
it is not mistaken for an oversight if a future session notices the allow
rule no longer visibly gates an `npx` call.

## Decision 3 — #17's fix is the literal flag the reporter used, confirmed on a newer Codex

`--add-dir <DIR>` is confirmed directly against the installed `codex-cli
0.158.0` (`codex --help` and `codex exec --help` both list it, newer than the
0.154.0 the issue verified against) as "Additional directories that should be
writable alongside the primary workspace" — exactly the shared-checkout-root
grant the issue describes, and exactly the flag style
(`--cd`/`--sandbox`/`--ask-for-approval`) `scripts/session-launch`'s `codex)`
branch already uses, so this is additive in the same idiom rather than a new
pattern (no `-c key=value` override needed).

**Scope decision — applies to both `restricted` and `trusted`.** The need to
reach `.git`/`.beads` is orthogonal to network access: even a `restricted`
Codex session commits locally and runs local `bd`/`scripts/nogg` commands
(`discoveries`, status reads) inside its worktree — only pushing and remote
Dolt sync are (correctly) blocked by `network_access=false`. So `--add-dir`
is added unconditionally in the `codex)` branch, not gated by authority
level, matching the issue's own proposed fix.

**Scope decision — which docs table gets the note.** `docs/using-with-codex.md`
carries the level-by-level sandbox detail table (sandbox mode, approval
policy, network access, can-push) and is where this belongs.
`docs/running-work-in-sessions.md`'s table is a Claude-vs-Codex *comparison*
at a coarser grain and does not need the same sandbox-internals depth — left
unchanged, to avoid duplicating detail that would drift.

## Non-goals

- No change to the `restricted` profile's `defaultMode` or prompt. Both
  `acceptEdits`-vs-`auto` (#16) and `EnterWorktree`-vs-`cd` (#15) are
  specifically about **unattended** sessions; `restricted` sessions wait for
  an operator by design (`no-autonomous-claim.md`) and are not blocked by
  either prompt in the same way, since a human is expected to be present to
  answer them.
- No change to Pi. Neither #15 nor #16 applies (Pi is a different tool with
  its own extension-based guard, not Claude Code's permission system); #17 is
  Codex-specific (Pi has no equivalent sandboxed `--cd`/worktree model in
  this version).
