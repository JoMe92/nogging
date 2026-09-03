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

`.codex/rules/specforge.rules` SHALL deny, for a Codex session, exactly the
command classes the Claude launch floor (`FLOOR_DENY`) denies in *every* session
regardless of profile: `sudo`, recursive force-delete (`rm -rf`, `rm -fr`),
`dd`, filesystem-format (`mkfs` and its variants), `shutdown`, `reboot`,
`systemctl`, `chown`, and outbound network fetch (`curl`, `wget`). A Codex
session running under this floor SHALL NOT be able to run those commands, at any
authority level, and `session launch --agent codex` SHALL NOT pass
`--ignore-rules`.

Remote-operation denial for a *restricted* Codex session (`git push`, remote
Dolt/Beads sync) SHALL be provided by the network-off workspace-write sandbox
(`sandbox_workspace_write.network_access=false`), not by the execpolicy
`.rules` file.

#### Scenario: The floor denies destructive shell from a Codex session

- **WHEN** a Codex session started under the SpecForge floor attempts `sudo` or a recursive force-delete
- **THEN** the command is denied by the execpolicy rules

#### Scenario: The floor denies outbound fetch from a Codex session

- **WHEN** a Codex session started under the SpecForge floor attempts `curl` or `wget`
- **THEN** the command is denied by the execpolicy rules

#### Scenario: The floor denies a push from a Codex session

- **WHEN** a Codex session at the `restricted` authority level attempts `git push`
- **THEN** the command fails — the launch set `sandbox_workspace_write.network_access=false`, so there is no route to a remote
- **AND** `.codex/rules/specforge.rules` checked against `git push` with `codex execpolicy check` matches no rule (the floor does not itself forbid it)

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

### Requirement: A trusted Codex session can complete an integration

The `trusted` / `--full-access` authority level for `session launch --agent
codex` SHALL enable network access
(`sandbox_workspace_write.network_access=true`), so a trusted Codex Lead session
can `git push` its change branch and `git push origin develop` to finish an
integration without a pull request — matching the Claude `trusted` path. The
`restricted` level SHALL keep network access disabled.

#### Scenario: A full-access Codex launch enables network

- **WHEN** a session is launched with `--agent codex --full-access` (or `--profile trusted`)
- **THEN** the launch sets `sandbox_workspace_write.network_access=true`

#### Scenario: A restricted Codex launch disables network

- **WHEN** a session is launched with `--agent codex` at the default authority level
- **THEN** the launch sets `sandbox_workspace_write.network_access=false`

### Requirement: A helper links the repo Codex prompts into CODEX_HOME

Because Codex reads custom prompts only from `$CODEX_HOME/prompts/`,
`scripts/specforge` SHALL provide `codex-prompts-link [--unlink]` that
idempotently symlinks every `.codex/prompts/*.md` in the repository to
`${CODEX_HOME:-$HOME/.codex}/prompts/specforge-<basename>.md`, repointing a
stale SpecForge symlink, leaving a correct one, and reporting (not overwriting) a
real file that is not a SpecForge symlink. `--unlink` SHALL remove only the
`specforge-*` symlinks the helper created. The installer's `init` / `update`
SHALL NOT perform this linking automatically.

`scripts/specforge doctor` SHALL print an informational line — never a failure —
when `codex` is on `PATH`, `.codex/prompts/*.md` exist in the repository, and at
least one is not linked into `${CODEX_HOME:-$HOME/.codex}/prompts/`, naming the
`codex-prompts-link` helper.

#### Scenario: The helper links each repo prompt

- **WHEN** `./scripts/specforge codex-prompts-link` runs with an empty `$CODEX_HOME/prompts/`
- **THEN** `$CODEX_HOME/prompts/specforge-plan.md`, `specforge-discovery-review.md` and `specforge-sync-now.md` are symlinks to the repo files

#### Scenario: The helper is idempotent and reversible

- **WHEN** `codex-prompts-link` is run twice, then `codex-prompts-link --unlink`
- **THEN** the second run changes nothing
- **AND** `--unlink` leaves `$CODEX_HOME/prompts/` with no `specforge-*` symlinks

#### Scenario: doctor notes unlinked prompts without failing

- **WHEN** `codex` is on `PATH`, the repo has `.codex/prompts/*.md`, and none are linked into `$CODEX_HOME/prompts/`
- **AND** `doctor` runs
- **THEN** it prints a NOTE naming `codex-prompts-link`
- **AND** it does not exit non-zero because of that NOTE
