## Why

Source: [GitHub #241](https://github.com/JoMe92/nogging/issues/241), reproduced
several times on 2026-10-18 (supply-doc, Codex gpt-6-luna and Claude Code 2.1.302
Leads) and recorded as a discovery on SPEC-22a8 (TASK-HPS-007).

A Lead session mounts `openspec/` read-only (the per-session fence, see
`tool-agnostic-write-boundary`). When upstream `develop` gains commits that
touch `openspec/` (a `tasks.md` tick, an archived change), the Lead's own
`git fetch && git rebase origin/develop` cannot write them:

- git fails with `fatal: cannot create directory at 'openspec/changes/...':
  Read-only file system`;
- the failed checkout leaves roughly 60 upstream files written as modified or
  untracked, `HEAD` unchanged and **no rebase state** (`.git/rebase-*` absent), so
  neither `git rebase --abort` nor `--continue` has anything to act on;
- the Lead reports "many pre-existing modifications" and stops, and the
  orchestrator had to run `git reset --hard HEAD && git clean -fd` from an
  unfenced session — a blind command that would also have destroyed any real
  work in the same tree.

Product Owner intent: a Lead must be able to bring its branch up to date without
a human or the orchestrator doing it by hand, and a half-applied checkout must
be detected and recoverable without ever discarding someone else's work.

## What Changes

- New `nogg worktree rebase [<record>] [--continue|--abort]`: the **writer side**
  (an unfenced process, which can write `openspec/`) fetches `origin/develop` and
  rebases a registered implementation worktree onto it, behind hard refusals
  (clean tree only, no live foreign session, no merge commits, no protected or
  detached branch), a backup ref of the previous tip and a durable journal.
- A conflict never strands the Lead: a conflict touching `openspec/` aborts the
  whole rebase and restores the exact previous state; a conflict only in code
  pauses a real git rebase that the Lead resolves and finishes with
  `worktree rebase --continue` (or ends with `--abort`).
- A fenced Lead asks for it through the **existing host-side sandbox broker**
  (the channel `task-done` already uses). The broker accepts exactly one more
  closed action — rebase/continue/abort of a registered implementation worktree —
  and never a path, command or replacement text. The Lead process itself never
  runs git against the read-only paths.
- `doctor` and `recover` detect a **half-applied checkout** (no git operation in
  progress, dirty paths that are byte-identical to the upstream tip) and print an
  exact, path-scoped, non-destructive recovery hint; `nogg worktree repair
  <record>` does it (dry-run by default, `--apply` snapshots first) and refuses to
  touch any path that is not provably reproducible from upstream.
- A `pre-rebase` git hook and the session launch prompts stop a fenced session
  from starting the raw rebase that causes the damage, and point at the supported
  command.
- Operator guidance and a changelog entry, last.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `agent-worktrees`: supervised rebase of an implementation worktree, its
  refusals, conflict policy and the non-destructive half-applied repair.
- `tool-agnostic-write-boundary`: the broker's rebase action, the `pre-rebase`
  guard and the launch-prompt rule.
- `run-recovery`: `doctor` and `recover` report a half-applied checkout and a
  stale rebase journal.

All three receive only ADDED requirements. The ready-to-archive and active
changes (`harden-planning-sessions` modifies one `agent-worktrees` requirement)
touch neighbouring requirements, so modifying the same headers here would make
changes conflict on archive.

## Impact

- `scripts/nogg`: the rebase engine, `worktree rebase|repair`, the fenced client
  path, the half-applied classifier and its `doctor`/`recover` lines.
- `scripts/openspec-sandbox`: one more closed broker action and a `--contract`
  feature; its existing task-done action is unchanged.
- `scripts/hooks/pre-rebase`, `scripts/install-hooks` and the payload manifest.
- `.nogging/launch-prompts/no-autonomous-claim.md` and `autonomous.md`.
- New focused suites under `scripts/*.test.sh` using real git fixtures (a bare
  origin, a seeded repository, linked worktrees), each failing first on current
  develop. No suite uses the test-mode `_is_legacy_mock` bypass; any suite that
  reaches `session launch` sources `scripts/lib/test-agents.sh` for its agent
  stubs.
- `docs/running-work-in-sessions.md`, `docs/failure-recovery.md`,
  `docs/operating-model.md`, `docs/architecture.md`, `CHANGELOG.md` (Unreleased).

Out of scope: rewriting an already-pushed branch (the Lead still hands the
force-push to a trusted session), merge-based integration, planning-worktree
rebases (a planner's `openspec/` is writable), changing the read-only fence,
auto-resolving conflicts, a live acceptance on real mounts (not possible in CI;
the docs give the host-side recipe), and any human sign-off. Planning does not
implement, claim execution Beads or push.
