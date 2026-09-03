# codex-onboarding Specification

## Purpose
TBD - created by archiving change codex-onboarding. Update Purpose after archive.

## Requirements

### Requirement: The installer places a Codex payload without clobbering Beads' hooks

When SpecForge is installed into a target repository, the installer SHALL place
`.codex/rules/specforge.rules` and `.codex/prompts/{plan,discovery-review,sync-now}.md`,
and SHALL preserve every entry in an existing `.codex/hooks.json` (the file `bd
init` writes). Re-running the installer SHALL be idempotent for the `.codex/`
payload and SHALL NOT drop or duplicate a Beads hook entry.

#### Scenario: A fresh install delivers the Codex payload

- **WHEN** the installer runs in a repository with no `.codex/`
- **THEN** `.codex/rules/specforge.rules` exists
- **AND** `.codex/prompts/plan.md`, `.codex/prompts/discovery-review.md` and `.codex/prompts/sync-now.md` exist

#### Scenario: An existing Beads hooks file is preserved

- **WHEN** `.codex/hooks.json` already contains the `bd codex-hook` entries
- **AND** the installer runs
- **THEN** those entries are still present and unchanged afterward

#### Scenario: The Codex payload survives `npx github:`

- **WHEN** the toolkit is installed from a packed package (the payload a `npx github:` install ships)
- **THEN** the `.codex/rules/` and `.codex/prompts/` files are present in the installed repository

### Requirement: The Codex authority floor mirrors the Claude floor

`.codex/rules/specforge.rules` SHALL deny, for a Codex session, the same command
classes the Claude launch floor denies: pushing to a git remote, remote Dolt
sync, and destructive host commands (`sudo`, recursive force-delete, `dd`,
filesystem-format, `shutdown`, `reboot`), plus outbound network fetch. A Codex
session running under the base floor SHALL NOT be able to run those commands.

#### Scenario: The floor denies a push from a Codex session

- **WHEN** a Codex session started under the SpecForge floor attempts `git push`
- **THEN** the command is denied by the execpolicy rules

#### Scenario: The floor denies destructive shell from a Codex session

- **WHEN** a Codex session started under the SpecForge floor attempts `sudo` or a recursive force-delete
- **THEN** the command is denied

### Requirement: AGENTS.md is the single canonical instruction file

`AGENTS.md` SHALL contain the complete SpecForge operating model in tool-neutral
terms, plus a *Tool notes* section with a labelled subsection for Claude Code and
one for Codex describing each tool's write-boundary mechanism, specialist model,
and operator entry points. The `CLAUDE.md` SpecForge block SHALL be a pointer to
`AGENTS.md` plus only the detail that is genuinely Claude-Code-specific, and
SHALL NOT restate the hard rules.

#### Scenario: A non-Claude tool has everything it needs from AGENTS.md

- **WHEN** Codex reads `AGENTS.md` at session start
- **THEN** it has the hard rules, the planning-only protocol, the supervised-session rules, and a Codex-specific *Tool notes* subsection

#### Scenario: CLAUDE.md does not duplicate the model

- **WHEN** `CLAUDE.md` is inspected
- **THEN** its SpecForge block points to `AGENTS.md` and carries only the Claude-only detail (the `PreToolUse` hook)
- **AND** it does not restate the numbered hard rules

### Requirement: Codex specialist delegation is out-of-process and documented

Because Codex has no in-process subagent mechanism, `AGENTS.md` and
`docs/operating-model.md` SHALL state that a Codex specialist run is a separate
supervised session started with `scripts/specforge session launch --agent codex
--role specialist:<type> --bead <id>`, bound by every specialist boundary rule
(one already-claimed Bead, no `openspec/` writes, no claim/close/commit,
discoveries reported to the Lead Agent). The six `.claude/agents/*.md` SHALL
remain Claude-Code-only.

#### Scenario: The Codex delegation path is written down

- **WHEN** `AGENTS.md` *Tool notes* is read
- **THEN** it names `session launch --agent codex --role specialist:<type>` as the Codex specialist mechanism
- **AND** it states the specialist boundary rules still apply

### Requirement: doctor reports Codex availability and flags a stale external rule

`scripts/specforge doctor` SHALL report whether `codex` is on `PATH`, and the
absence of `codex` alone SHALL NOT make `doctor` exit non-zero. `doctor` SHALL
also print an informational line for any Codex execpolicy `prefix_rule` whose
command pattern references a filesystem path that does not resolve under the
current repository root, without treating it as a failure.

#### Scenario: Codex absent does not fail doctor

- **WHEN** `doctor` runs in a repository where `codex` is not installed and everything else is healthy
- **THEN** it reports `codex` as not installed
- **AND** it exits zero

#### Scenario: A stale external Codex rule is surfaced

- **WHEN** a `~/.codex/rules/*.rules` entry denies or allows a command whose pattern names a path outside this repository
- **AND** `doctor` runs
- **THEN** it prints an informational line naming that rule and its file
- **AND** the line does not count as a failure
