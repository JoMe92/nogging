---
name: nogging-planning
description: Running a planning session - the lane (fast, lite or full), the lite and full spec formats, task sizing, the Tests and Check fields, and the fixed order from plan-begin to worktree cleanup. Read it when you run a planning session, pick a lane, or write or size tasks.
---

# Planning: lanes, formats and the planning session

Only the Planning Agent writes `openspec/`, and only during a planning session
that holds the canonical `.nogging/locks/planning.lock`. The operator entry
point is `/plan` (`.claude/commands/plan.md`, `.codex/prompts/plan.md`,
`.pi/prompts/plan.md`); the supervised launch prompt is
`.nogging/launch-prompts/planning.md`. Those prompts carry the full step list
and win over this summary.

## The lane

`./scripts/nogg ceremony` prints the mode in effect. Under `always-full`
every task takes the full spec. Otherwise triage picks the lane, by fixed
rules and from stated facts only:
`./scripts/nogg triage "<description>" [--kind …] [--files <n>]`.

- **Fast** — a small bug, refactor, test or configuration change in one or two
  files. No change is written: `./scripts/nogg quick "<title>" --accept
  "<criterion>" …` creates one Bead with three to five acceptance criteria.
- **Lite** — three or more files, or facts missing. A lite change is a
  `proposal.md` with the completeness sections (goal, non-goals, acceptance
  criteria as WHEN/THEN scenarios, edge cases, constraints, affected areas,
  validation, risks) plus a short `tasks.md`. `./scripts/nogg validate` scores
  the sections and sends a spec under the minimum score back to the planner.
- **Full** — a feature, a pipeline, a public interface, anything touching
  security, or anything unclear: `proposal.md`, `design.md`, the spec deltas
  under `specs/` and `tasks.md`.

A missing kind or file estimate never gives the fast lane. A fast-lane Bead
that outgrows its limits comes back labelled `needs-spec`: triage it again as
lite or full.

## Writing tasks

- Write behaviour and how it is checked, not function names, internal
  identifiers or constants. File paths, command lines, flags and configuration
  keys are what a user sees and stay allowed.
- **Sizing.** A task is a vertical slice within `task_sizing.bead_prod_lines`
  (`./scripts/nogg task-sizing` prints the range). Every task line carries an
  estimate tag `[~N loc]` counting production lines, tests excluded. A task
  outside the range states its reason in the tag, for example
  `[~80 loc: security fix]`; a task above the maximum is split.
- **`Tests:`** names the scenarios to test and gives each a size: `small`
  (in process, under a second each), `medium` (local processes and temporary
  repositories, seconds each) or `large` (a packed install or a real
  multi-process flow, only where nothing smaller shows it). A documentation
  task says `Tests: none (<reason>)`. See `docs/nogging/testing-policy.md`.
- **`Check:`** names the suites or test files the task affects, never the full
  suite (bare `scripts/test`, a whole suite, `nogg test full`), which is CI's
  job. `validate` and `materialize` refuse such a `Check:` on a task that has
  no Bead yet.
- Wire Beads dependencies explicitly (`bd dep add`); never infer them from
  task order.

## Planning only: the fixed order

The Planning Agent first allocates `./scripts/nogg worktree plan
<planning-id> <description>` from updated `origin/develop` and works only in
that worktree. A supervised planner gets its worktree at launch:
`./scripts/nogg session launch --role planning --planning-id <planning-id>
--description <description>`. A bare launch stays idle; an optional `--bead`
is context only and is never claimed. After kickoff the planner runs
`plan-begin` itself. That takes the canonical planning lock in the main
checkout, owned by that session; nobody acquires it on its behalf. It writes
or revises OpenSpec, validates, commits with `NOGGING_WRITER=planning`,
materializes Beads (`./scripts/nogg materialize <change>`), wires Beads
dependencies explicitly, fast-forward integrates the plan into `develop`, and
then runs `./scripts/nogg plan-end` from the planning worktree (`plan-end`
always precedes worktree retirement) and, as the very last command, retires the
clean, integrated worktree with `./scripts/nogg worktree cleanup <record>` from
the surviving canonical checkout. If cleanup refuses, it does not retry, force
it or delete files: it reports the hand-off, `./scripts/nogg session stop
<name>`, then `./scripts/nogg worktree cleanup <record>` from the canonical
checkout, and stops. Validation names the change: `./scripts/nogg validate`
plus `openspec validate <change> --strict --no-interactive`, never a bare
`openspec validate`. The commit precedes `materialize` so a crash between them never leaves Beads
without a committed spec. Stop, cleanup and recovery never release another
session's planning lock.

A held planning lock never makes `openspec/` writable for an execution role.
If an active Bead loses its task mapping, stop and resolve the orphan
explicitly; do not delete it. Pending discoveries are reviewed at the start of
the session: `./scripts/nogg discoveries` lists them, `--ack` acknowledges.
