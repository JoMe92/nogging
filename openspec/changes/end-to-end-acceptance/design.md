# Design

## Context

The pieces of SpecForge already have unit-level coverage: `scripts/test` runs
every `scripts/**/*.test.sh` offline with `bd` stubbed, `scripts/cli.test.sh`
exercises the installer, and `npx openspec validate --all` checks every change.
What is missing is a single run that proves the pieces compose:
`npx github:JoMe92/specforge init` → readiness verdict → planning session →
`proposal`/`design`/`tasks`/`specs` → `validate` → `materialize` →
`bd` execution with a specialist delegation → Conventional Commit with a
`[SPEC-…]` token on a convention-named branch → mechanical `sync` mirroring the
closure into `execution-log.md` and ticking the task box → `discoveries`
review → `doctor`/`audit` clean.

Section 12 of the concept conversation walks this exact path as narrative. The
`photo-import-filesystem` change in this repository is the shape of the example
but is heavier than an acceptance run needs.

Two hard constraints shape the design:

- The agent-driven steps (authoring intent, delegating to a specialist,
  deciding a discovery) cannot be asserted by a script — they need a runbook a
  person follows.
- The `npx github:` install path needs the repository pushed to
  `JoMe92/specforge` and a tag; that has not happened yet. The mechanical
  harness must therefore install from the local checkout, and the real
  `npx github:` invocation stays a manual runbook step.

## Goals / Non-goals

- Goal: a person can run one documented procedure and end with a dated report
  that says the toolkit works end to end, or names exactly what failed.
- Goal: the no-LLM subset of that procedure runs unattended in CI and fails the
  build on any regression in install, validate, materialize or sync.
- Goal: the example change is small, self-contained, and obviously not a real
  feature.
- Non-goal: fixing anything the run uncovers — findings become discoveries or
  new changes, not edits inside this change.
- Non-goal: shipping the example change as a real capability, or archiving it.
- Non-goal: re-implementing per-change validation; `scripts/specforge validate`
  and `npx openspec validate` stay the source of truth for a single change.
- Non-goal: automating the human sign-off, or gating release on it.
- Non-goal: materializing Beads for this change, or editing implementation
  files in this planning session.

## Decisions

### The runbook is the deliverable; the harness is a subset of it

`docs/acceptance.md` is the ordered procedure. Every step carries a tag:

- **[M] mechanical** — reproducible by `scripts/acceptance.sh`, no agent, no
  human judgement.
- **[A] agent-driven** — a person runs a session (or drives an agent) and
  records the outcome by hand.

`scripts/acceptance.sh` implements exactly the `[M]` steps in order. The runbook
and the script must not drift: a task in this change keeps them in step, and the
script prints the step tags it is covering so a reader can map them back.

### Mechanical harness structure

`scripts/acceptance.sh [--mechanical]`:

1. Create a throwaway repository (`mktemp -d`, `git init`, a user identity,
   `core.hooksPath` left at default so the boundary hooks bind).
2. Install SpecForge from the local checkout — `node "$root/bin/cli.js" init` —
   not `npx github:`, which is a manual runbook step until the repo is pushed.
3. Assert the readiness verdict. With `bd` and the Beads backend present the
   final line must be `SpecForge is ready`; under `--mechanical` (no backend)
   assert instead that the verdict names the uninitialized tracker as the only
   gap.
4. `scripts/specforge plan-begin`; copy `scripts/fixtures/acceptance/` into
   `openspec/changes/acceptance-example/`; `scripts/specforge validate`.
5. `scripts/specforge materialize acceptance-example`. With a real backend this
   creates one Bead per task; under `--mechanical` a stub `bd` (same technique
   as `scripts/specforge.test.sh`) records the create calls and the harness
   asserts one per task.
6. Simulate execution: mark the example's first task's Bead closed (real `bd`
   close, or stub), then run `scripts/specforge sync` twice. Assert the first
   run ticks exactly one `- [ ]` → `- [x]` and appends exactly one
   `execution-log.md` entry; assert the second run reports no changes and
   produces no diff.
7. `scripts/specforge doctor` and `scripts/specforge audit` exit clean.
8. `scripts/specforge plan-end`; remove the throwaway repository.

`scripts/acceptance.test.sh` is a thin wrapper that runs
`scripts/acceptance.sh --mechanical` and is picked up by `scripts/test`. It
skips with a PASS when `node` is absent, matching `scripts/cli.test.sh`.

### The canned example change

`scripts/fixtures/acceptance/` holds a complete but minimal change:
`proposal.md`, `design.md`, `tasks.md` with `TASK-ACCEPTX-001` and
`TASK-ACCEPTX-002`, and `specs/acceptance-example/spec.md` with one requirement
and one scenario. The task prefix is `ACCEPTX` (not `ACCEPT`) so fixture tasks
never collide with this change's own `TASK-ACCEPT-…` IDs in a
`task_map()` scan. It describes a throwaway "echo note" capability so no reader
mistakes it for real product intent.

### Acceptance report

`docs/acceptance-report-template.md` is copied to
`docs/acceptance/<date>-<host>.md` for each run. It records: the toolkit version
(`.specforge/config.json` `specforge_version` and the git SHA), each runbook
step with pass / fail / skipped and a note, deviations from the runbook, every
discovery filed during the run with its Bead ID, and a final
`Signed-off-by: <name> <date>` line left blank until a person completes it. The
report is committed; the sign-off is a separate human commit.

### CI

A new `acceptance` job in `.github/workflows/specforge-validate.yml` runs
`actions/setup-node`, then `scripts/acceptance.sh --mechanical`. It needs no
Beads backend and no secrets. The existing `script-tests`, `installer` and
`validate` jobs are unchanged; `scripts/acceptance.test.sh` also runs inside the
`script-tests` job via `scripts/test`, so the mechanical subset is covered even
if the dedicated job is dropped later.

### First real run

Implementation includes one full run of the `[A]` + `[M]` runbook on the
delivery Pi, producing the first `docs/acceptance/` report. Anything that fails
is filed as a discovery on its Bead (per `AGENTS.md` rule 4), not fixed here.
The real `npx github:JoMe92/specforge init` path is exercised in that run once
the repository is pushed and tagged; if it is not yet pushed, that step is
recorded as skipped with the reason.

## Risks / open questions

- The `[M]` subset can only prove the deterministic spine. A green CI job is
  necessary but not sufficient for acceptance — the `[A]` steps and the human
  sign-off are the rest.
- `materialize` under `--mechanical` depends on the same `bd` stub contract as
  `scripts/specforge.test.sh`; if that contract changes both must move together.
- The example change's Beads (real-backend runs) are created in whatever Beads
  workspace the run uses. On a throwaway repo that is a throwaway workspace; on
  a shared host the runbook must say to use an isolated one so acceptance Beads
  never mix with real work.
- `reliable-beads-sync` changes the sync failure-record shape and the discovery
  read path; the harness assertions on `sync` and `discoveries` output must be
  written against the post-`reliable-beads-sync` behaviour, so this change lands
  after it.
- Convention-named branches and the CI commit invariant come from
  `enforce-conventional-branching`; the runbook's commit step assumes them.
