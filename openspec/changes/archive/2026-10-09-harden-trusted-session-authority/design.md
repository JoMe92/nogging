# Design — harden trusted session authority

## Decision 1 — fix is `bypassPermissions` + `skipDangerousModePermissionPrompt`, not a retry of `auto`

Two credible fixes exist for "a `--full-access` session should never need a
human": keep `auto` and make its silent availability-fallback loud (a
`doctor`/launch-time check), or drop the classifier gate entirely and ship
`bypassPermissions`, matching what `orchestrator.json` already does. This
change takes the second path, for three reasons:

1. **`auto`'s weakness is not only the fallback.** Even when `auto` is
   genuinely active (confirmed via the status bar, not silently downgraded),
   Claude Code's own docs table (`permission-modes.md`, *Protected paths*)
   shows it still routes protected-path writes to a classifier rather than
   allowing them — a classifier that can deny with nobody present to retry
   it from `/permissions`. A loud fallback warning would catch the
   silent-Manual case but not this one; #40's own evidence includes prompts
   (`EnterWorktree`-adjacent, a file edit outside the worktree root) that are
   not explained by the fallback alone.
2. **The deny list is already the real, documented boundary**, independent of
   `defaultMode` ("deny rules ... block in every mode, including
   `bypassPermissions`" — Claude Code docs, confirmed also in this project's
   own `launch-profiles` spec). `trusted.json`'s existing deny list already
   covers the floor-adjacent destructive commands; `bypassPermissions` does
   not weaken it.
3. **This repository already runs this exact pairing successfully.**
   `orchestrator.json` has shipped `bypassPermissions` +
   `skipDangerousModePermissionPrompt: true`, delivered via the same
   `--settings <path>` mechanism `trusted` uses, verified hands-on
   (`TASK-ORC-001`) in a real tmux pane on this host. Adopting the same
   pairing for `trusted` is extending working, already-verified machinery,
   not a new mechanism.

**Rejected: keep `auto`, add only a loud-fallback check.** Insufficient on its
own per point 1; would also leave the classifier's cost/latency and
account/model dependency in place for every `--full-access` session going
forward, for a safety margin the project's own command floor and `openspec/`
boundary substantially duplicate at the tool level already.

**Accepted residual risk**: `bypassPermissions` genuinely has no classifier
reviewing actions beyond the deny list — "offers no protection against prompt
injection or unintended actions" (Claude Code docs, verbatim). This is the
same tradeoff `orchestrator.json` already accepts, now extended to `trusted`.
Unlike the orchestrator profile (unrestricted, god-mode, mitigated by the
single-instance lock and full visibility), `trusted` still carries the
project's own deny list and the fixed command floor every profile gets
unioned in — the mitigations are layered, not removed.

## Decision 2 — the `doctor` check targets config drift, not mode fallback

Since Decision 1 removes the model/account availability dependency entirely
(`bypassPermissions` has none), the `doctor` check this change adds is
narrower than what the original deferred discovery imagined: it is a static
check over the installed profile JSON, not a runtime classifier/account
probe.

`scripts/nogg doctor` gains a check that, for every Claude launch profile file
under `.nogging/launch-profiles/*.json` (not `.codex.toml`/`.pi.toml`
siblings, which carry no `defaultMode`):

- flags `defaultMode: "bypassPermissions"` present without
  `skipDangerousModePermissionPrompt: true` at the top level — the exact
  pairing mistake this change fixes, so a future edit that changes one key
  without the other is caught immediately rather than rediscovered live;
- flags a shipped-profile name (`trusted`, `orchestrator`) whose `defaultMode`
  no longer matches what `docs/security-model.md` documents for it — catching
  a project that drifted from the template on an `update` the same way other
  `doctor` checks already catch config drift elsewhere.

This is a `NOTE`, matching every other `doctor` advisory check — it does not
fail the command, and does not run for `restricted.json` (which intentionally
keeps its conservative default and is unaffected by this change).

## Non-goals

- No change to `restricted.json` or its prompt. Restricted sessions are
  interactive-by-design; this change is scoped to unattended `--full-access`
  authority only, per #40 and the original `unblock-autonomous-sessions`
  design's own framing.
- No change to the Codex or Pi `trusted` siblings. Neither has a
  `permissions.defaultMode` concept (Codex's sandbox/approval mapping and
  Pi's guard extension are unaffected by this Claude-specific setting); #40's
  evidence and reproduction are Claude-only.
- No new classifier-replacement safety mechanism. The accepted tradeoff in
  Decision 1 is deliberate: the deny list plus the command floor are the
  boundary, exactly as already documented and accepted for `orchestrator`.
