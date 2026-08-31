# Harden the OpenSpec write boundary

## Why

The concept conversation of 2026-08-31 (`docs/source/konversation-export.md`,
sections 3, 8 and 10) settled three enforcement decisions that the repository
does not yet implement faithfully:

- Discoveries should ride on **native Beads primitives** (a `discovery` label
  plus a human-readable note), not a bespoke JSON metadata block. The current
  `AGENTS.md` and `docs/architecture.md` still mandate a fenced
  `specforge-discovery` JSON block.
- The write boundary "execution agents never write `openspec/`" is only proven
  at the *result* by a commit-msg invariant that forces a real Beads issue ID
  into every execution commit. Today the commit-msg hook checks Conventional
  Commit shape only; nothing requires a Beads ID, and the planning/sync
  exemption is undocumented.
- The boundary must also be enforced at the *tool* by a Claude Code
  `PreToolUse` hook that blocks `Edit`/`Write` into `openspec/` unless the
  planning lock is held. `.claude/settings.json` currently has no such hook, so
  a non-planning session relies on prompt text alone.

## What changes

- **Discovery signalling:** replace the fenced `specforge-discovery` JSON
  convention with the native `discovery` Beads label plus a required
  human-readable note. Update `AGENTS.md`, `docs/architecture.md`, and the
  discovery-reading logic in `scripts/specforge`.
- **Execution commit invariant:** extend `scripts/hooks/commit-msg` to require a
  real Beads issue ID token (for example `[SPEC-abc]`) in the commit subject of
  execution commits, and to explicitly exempt commits whose `SPECFORGE_WRITER`
  is `planning` or `sync`.
- **Tool-level boundary:** add a `PreToolUse` hook to `.claude/settings.json`
  matching `Edit|Write` that exits non-zero when the target path is under
  `openspec/` and `.specforge/locks/planning.lock` does not exist.
- Document the three enforcement layers and their interaction in the docs.

## Impact

- Affected specs: `write-boundary` (new capability).
- Affected code (implementation deferred to execution): `scripts/hooks/commit-msg`,
  `scripts/specforge` (discovery read path), `.claude/settings.json`,
  `AGENTS.md`, `docs/architecture.md`.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
- Behavioural change for contributors: execution commits without a Beads ID will
  be rejected locally once the hook lands.
