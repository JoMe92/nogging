# Design

## Context

The write boundary keeps execution agents out of `openspec/`. `docs/architecture.md`
describes four layers:

1. `PreToolUse` guard — `scripts/hooks/pre-tool-use-openspec-guard`, wired in
   `.claude/settings.json`, matcher `Edit|Write`, exit 2 blocks the call when the
   path is under `openspec/` and `.specforge/locks/planning.lock` is absent.
   **Claude Code only.**
2. `pre-commit` — rejects staged `openspec/` paths unless `SPECFORGE_WRITER` is
   `planning`/`sync`. Git, tool-agnostic.
3. `commit-msg` — execution commits need a real Beads-ID token. Git, tool-agnostic.
4. CI `invariants` job — re-runs the `commit-msg` rule over a PR's commit range.

`plan-begin` calls `lock("planning", …)`, which writes
`.specforge/locks/planning.lock` (`{pid, host, created_at}`) and treats a lock
older than `planning_lock_ttl_seconds` (7200) as free. `plan-end` unlinks it.

`sync()` (the 30 s timer) writes `openspec/changes/<c>/execution-log.md` and
flips `- [ ]` → `- [x]` in `tasks.md`, then `git add` + `git commit -m … -m
"SpecForge-Writer: sync"` with `SPECFORGE_WRITER=sync`. It holds the sync lock
for the pass.

Codex (v0.148.0) has hooks for `SessionStart` / `UserPromptSubmit` / `PreCompact`
/ `PostCompact` only — **no per-tool-call hook**. Its pre-exec controls are the
sandbox (`--sandbox read-only|workspace-write|danger-full-access`,
`--sandbox-state-readable-root <path>`, `--add-dir`) and execpolicy `.rules`.
The sandbox can mark a subtree read-only inside a writable workspace.

## Goals / Non-goals

- Goal: outside a planning session, an execution agent of **any** tool cannot
  create, modify, or delete a file under `openspec/changes/` or
  `openspec/specs/`.
- Goal: the block is anchored in the filesystem / OS, not only in a Claude Code
  hook.
- Goal: `plan-begin` opens the trees, `plan-end` closes them.
- Goal: the mechanical sync writer and ordinary developer git operations
  (`switch` / `merge` / `checkout` / `pull`) keep working with no ceremony.
- Goal: a stale `planning.lock` stops permitting writes (W6).
- Non-goal: removing the `PreToolUse` guard — it stays as the fast Claude Code
  early signal (a blocked call the model sees immediately, before the sandbox
  would surface an EACCES).
- Non-goal: changing the `pre-commit` / `commit-msg` rules or the CI job.
- Non-goal: the Codex launch dispatch itself (`agent-neutral-launch`) or the
  installer `.codex/` merge (`codex-onboarding`).
- Non-goal: locking `openspec/project.md` or `openspec/config.yaml` (rarely
  touched, and not the execution-drift surface); the lock is scoped to
  `changes/` and `specs/`.

## Decisions

### The lock is a sentinel plus per-session read-only roots (recommended)

Two mechanisms were considered:

**(a) Blanket `chmod`.** `plan-end` runs `chmod -R a-w openspec/changes
openspec/specs`; `plan-begin` restores `u+w`. Simple and maximally visible, but
it **fights git**: `git checkout` / `switch` / `merge` cannot overwrite a `0444`
file in a `0555` directory, so every branch operation that touches `openspec/`
would fail. Workable only with `sync()` and a `post-checkout`/`post-merge` git
hook both lifting the lock around their writes — fragile.

**(b) Sentinel + read-only sandbox roots (recommended).** `plan-end` writes
`.specforge/locks/openspec.readonly` (a sentinel, `{closed_at, by}`);
`plan-begin` removes it. Enforcement:

- **Claude Code sessions** — the existing `PreToolUse` guard (now also honouring
  staleness, below) blocks the edit before it happens.
- **Any launched execution session (Claude or Codex)** — `session launch` for a
  non-planning role adds `openspec/` to the session's read-only authority:
  Claude → `deny` rules for `Edit`/`Write`/`MultiEdit` under `openspec/**` in the
  effective-settings file; Codex → `--sandbox workspace-write` plus
  `--sandbox-state-readable-root <repo>/openspec`. The OS/sandbox then refuses
  the write. A planning-role session (or one launched while `planning.lock` is
  held and fresh and the sentinel is absent) does not get the read-only root.
- **The `pre-commit` hook** (Layer 2) is unchanged and remains the git-level
  backstop for an edit made some other way (a plain editor, `sed -i`).

Mechanism (b) does not touch file modes, so `git switch` / `merge` / `checkout`
and the `sync()` writer work with no changes. `sync()` needs no special handling
— it writes `openspec/` files directly as the `sync` writer, which the sentinel
does not gate (the sentinel is advisory to the guards, not a mode change).

The spec is written behaviourally so a future implementer may still choose (a)
with the git-hook plumbing if a stricter guarantee is wanted; the requirement is
"an execution agent cannot persist the change", not "the files are mode 0444".

### `plan-begin` / `plan-end` toggle the boundary

- `plan-begin`: acquire the planning lock (unchanged) **and** remove
  `.specforge/locks/openspec.readonly` if present, so `openspec/` is writable
  for the session.
- `plan-end`: release the planning lock (unchanged) **and** write
  `.specforge/locks/openspec.readonly`.
- `plan-begin --force` / `plan-end --force` behave as today for the planning
  lock and toggle the sentinel the same way.
- A fresh install starts with the sentinel present (created by
  `scripts/install-hooks` or first `doctor` run) so `openspec/` is read-only
  until the first `plan-begin`.

### `PreToolUse` guard honours staleness (W6)

The guard currently tests `[[ ! -e .specforge/locks/planning.lock ]]`. It is
upgraded to also treat a lock whose `created_at` is older than
`planning_lock_ttl_seconds` (read from `.specforge/config.json`) as absent — the
same staleness rule `lock()` already applies. It also blocks when
`.specforge/locks/openspec.readonly` is present regardless of the planning lock,
so `plan-end` takes effect immediately even if a stale planning lock lingers.

### `doctor` reports the boundary state

`scripts/specforge doctor` gains a line: `openspec write boundary: OPEN
(planning session active, lock age Ns)` / `LOCKED` / `LOCKED (stale planning
lock present — run plan-end --force)`. Read-only; no exit-code change beyond the
existing checks.

### Docs

`docs/architecture.md` "The OpenSpec write boundary": the pre-edit block is
re-described as a **tool-agnostic filesystem/sandbox guard** (the sentinel + the
per-session read-only root + the staleness-aware `PreToolUse` fast path), with
`pre-commit` / `commit-msg` / CI unchanged below it. The interaction table gains
a "Codex session" column or note. `docs/failure-recovery.md` gains a
"`openspec/` stuck read-only / stuck writable" entry pointing at the sentinel
and `plan-begin` / `plan-end --force`.

## Risks / open questions

- **`--sandbox-state-readable-root` semantics** must be verified against the
  installed Codex: does a readable root inside a `workspace-write` workspace
  actually deny writes to that subtree? If not, the fallback is
  `--add-dir <every writable subdir except openspec>` or an execpolicy `.rules`
  deny on `apply_patch`/write paths under `openspec/` (needs a check that
  `.rules` can gate the patch tool, not only shell commands).
- A forgotten `plan-end` leaves `openspec/` writable. Mitigation: `doctor`
  surfaces it; a launched execution session still gets the read-only root
  because it keys off *its own role*, not only the sentinel; and the stale-lock
  expiry eventually re-closes the `PreToolUse` path.
- The sentinel is local state (under `.specforge/locks/`, gitignored). It is not
  synced and is safe to delete — deleting it just re-opens `openspec/` for the
  `PreToolUse` fast path until the next `plan-end` (the per-session read-only
  root is unaffected).
- `sync()` writes `openspec/` while the sentinel is present — that is correct
  (`sync` is a trusted writer); the sentinel gates *guards*, not the writer. If
  mechanism (a) is ever adopted, `sync()` must lift/restore the mode.
- Interaction with `agent-neutral-launch`: the read-only-root wiring lives in
  the launch path that change reworks; sequence this change after it, or share
  the `session_launch()` edit.
