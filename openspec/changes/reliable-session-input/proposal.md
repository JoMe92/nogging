## Why

Source: [GitHub issue #160](https://github.com/JoMe92/nogging/issues/160).
Kickoff and ordinary send can report success while the instruction remains in
Claude's composer. This fleet also repeatedly observes unsent Codex queue
messages and Antigravity kickoff failures at the first-turn readiness gate.

## What Changes

- Send tmux text with explicit bracketed paste, preserving multiline content
  and isolating buffers between simultaneous sessions.
- Wait a configurable interval before one Enter, then verify delivery by
  default for Claude, Codex and Antigravity. Retry Enter only for positively
  identified pending text belonging to this operation; never blindly resend.
- Verify Codex queue delivery against fresh evidence from the exact thread.
  Exitcode zero means queue acceptance, not proven submission. Recover an
  exact pending composer with a bounded submit, without typing the text twice.
- Wait for startup readiness before kickoff. For Antigravity, accept a valid
  current Stop event or stable backend/composer evidence; timeouts identify
  what is missing instead of requiring repeated speculative kickoffs.
- Preserve TASK-HSS-005's bounded clearing and exact-message checks. Explicit
  Beads dependencies on SPEC-culj gate changes to shared nudge helpers.
- Cover both backends with deterministic tests, update operator guidance and
  record an unsigned live acceptance on the delivery host.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-observability`: default verified delivery, Codex queue evidence,
  startup-ready kickoff and bounded retries with explicit unknown outcomes.
- `session-backends`: safe tmux paste and removal of unconditional double
  Enter, while policy remains above the backend seam.

## Impact

- `scripts/nogg`: readiness, send, nudge integration, submit verification,
  Codex queue handling and kickoff orchestration.
- `scripts/lib/session_backend_tmux.py`: temporary paste buffers and stdin
  transport; `scripts/lib/session_backend.py` documents transport semantics.
- New pure `scripts/lib/session_codex_delivery.py` evidence reader, shipped
  through `bin/lib/manifest.js`; no new dependency or network service.
- New task-specific test suites and synthetic, labelled runtime fixtures;
  related existing assertions updated only where the behavior changes.
- Session, Codex, Antigravity and recovery guides plus an unsigned acceptance
  report. No authority changes, trust-dialog acceptance or human sign-off.

Antigravity startup and Codex queue failures are in scope. General runtime
hook repair, automatic trust grants, Pi delivery changes, model switching and
orchestrator restart (#161) are out of scope. Planning does not implement,
claim execution Beads or push.
