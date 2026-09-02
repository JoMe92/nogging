# A tool-agnostic OpenSpec write boundary

## Why

The "execution agents never write `openspec/`" boundary is enforced in depth by
four layers today, but **Layer 1 — the pre-edit block — is Claude Code only**
(`scripts/hooks/pre-tool-use-openspec-guard`, a `PreToolUse` hook). Codex has no
per-tool-call hook, so an execution session run with Codex has no pre-edit
block at all: it falls back to Layers 2–4 (`pre-commit`, `commit-msg`, the CI
`invariants` job), which only stop the *commit*, not the working-tree edit.

Two further weaknesses affect Claude Code too:

- The `PreToolUse` guard checks only that `.specforge/locks/planning.lock`
  *exists*. A **stale** lock (older than `planning_lock_ttl_seconds`, e.g. after
  a crashed planning session) blocks `plan-begin` but still permits `openspec/`
  edits — an asymmetric hole (crash-resilience discovery **W6**).
- Nothing in the working tree makes the boundary *visible*: an operator cannot
  tell from the filesystem whether `openspec/` is currently writable.

This change makes the pre-edit block **tool-agnostic and filesystem-anchored**:
`plan-begin` opens `openspec/` for writing, `plan-end` closes it, and a launched
execution session — Claude or Codex — runs with `openspec/` as a read-only path
regardless of which agent it is.

## What Changes

- **`plan-begin` / `plan-end` toggle a working-tree write lock** on
  `openspec/changes/` and `openspec/specs/`. Outside a planning session those
  trees are read-only to an unprivileged process; `plan-begin` restores
  writability, `plan-end` re-locks.
- **The mechanical sync writer and ordinary git operations keep working.**
  `sync()` lifts and restores the lock around its own writes; `git switch` /
  `merge` / `checkout` are unaffected (see design — the recommended mechanism is
  a sentinel file plus per-session read-only roots, not a blanket `chmod` that
  fights git).
- **A launched execution session runs with `openspec/` read-only** in its
  effective authority: Claude via `deny` entries in the effective-settings file,
  Codex via a read-only sandbox root. A planning-role session does not get this.
- **The `PreToolUse` guard honours lock staleness** — a `planning.lock` older
  than its TTL no longer permits `openspec/` writes (closes W6).
- **`scripts/specforge doctor` reports the boundary state**: planning session
  active / `openspec/` locked / stale lock present.
- **`docs/architecture.md` "The OpenSpec write boundary"** is updated: the
  pre-edit block is now a tool-agnostic filesystem guard with the `PreToolUse`
  hook as a fast Claude Code early signal on top; the layer count and the
  interaction/limitations tables are revised.

## Capabilities

### New Capabilities

- `filesystem-write-boundary`: outside a planning session, an execution agent of
  any tool cannot persist a change to `openspec/changes/` or `openspec/specs/`;
  the mechanical sync writer and git branch operations are unaffected.

### Modified Capabilities

<!-- none -->

## Impact

- New/changed code (implementation deferred to execution): `scripts/specforge`
  (`plan-begin`, `plan-end`, `sync`, `doctor`, a write-lock helper),
  `scripts/hooks/pre-tool-use-openspec-guard` (staleness check),
  `scripts/session-launch` / `session_launch()` (read-only `openspec/` for an
  execution session).
- Modified: `scripts/specforge.test.sh`, `docs/architecture.md`,
  `docs/failure-recovery.md`.
- Behavioural change: a planning session must run `plan-begin` before editing
  `openspec/` (already the documented flow) and `plan-end` after; a forgotten
  `plan-end` leaves `openspec/` writable until the next `plan-begin`/`plan-end`
  or a stale-lock expiry.
- Part of the Codex-support epic — complements `agent-neutral-launch` (which
  adds `session launch --agent codex`); `codex-onboarding` documents the
  resulting model in `AGENTS.md`. Resolves crash-resilience discovery W6.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
