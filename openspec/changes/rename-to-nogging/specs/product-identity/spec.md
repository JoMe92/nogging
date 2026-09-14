## Purpose

Defines the public Nogging identity — display name, renamed technical
identifiers, the legacy-name provenance chain, the accepted OpenSpec-spec
wording divergence, and the README/brand presentation bar.

`rename-agentsembli-specforge` was archived first (see
`openspec/changes/archive/2026-09-14-rename-agentsembli-specforge/`), so the
baseline `openspec/specs/product-identity/spec.md` already holds the
Agentsembli SpecForge requirements this change supersedes. Three of the four
baseline requirements are `MODIFIED` here under their same titles; the
identifier-compatibility requirement is `REMOVED` outright because this
rename reverses it (it renames technical identifiers instead of preserving
them); two genuinely new requirements are `ADDED`.

## MODIFIED Requirements

### Requirement: Nogging is the canonical public identity

The project SHALL use **Nogging** as its public display name and
`JoMe92/nogging` as its canonical repository. Current public metadata,
documentation, support and security routes, the CLI, and release assets
SHALL resolve to that identity.

#### Scenario: A new user discovers the project

- **WHEN** a user reaches the canonical repository without prior context
- **THEN** the Nogging purpose, installation, support, security, and
  provenance are complete and internally consistent

### Requirement: Legacy identity remains provenance, not an active destination

Historical references MAY identify the former `JoMe92/specforge` and
`JoMe92/agentsembli-specforge` repositories and the `specforge` command, but
maintained public entry points SHALL route to `JoMe92/nogging` and the `nogg`
command. Both prior repositories SHALL remain private, archived, or otherwise
unavailable for public installation unless the owner explicitly approves a
safe redirect.

#### Scenario: User follows an old installation instruction

- **WHEN** a user encounters a maintained transition notice for either prior
  identity
- **THEN** it identifies Nogging as the successor and gives a pinned new
  command/repository reference

### Requirement: Visibility and final identity acceptance remain human actions

This rename SHALL NOT itself change repository visibility, publish to npm,
or constitute trademark clearance. Those remain separate, explicit owner
decisions, same as the two prior naming rounds.

#### Scenario: Mechanical checks finish

- **WHEN** every automated rename and release check passes
- **THEN** the repository remains private and the acceptance report remains
  unsigned until the owner acts
- **AND** the owner checklist sequences public visibility, Private
  Vulnerability Reporting enablement and verification, then final sign-off

#### Scenario: The rename completes

- **WHEN** every task in this change is done and verified
- **THEN** the repository remains private
- **AND** no automated step has claimed public availability, npm publication,
  or legal clearance for "Nogging"/"nogg"

## REMOVED Requirements

### Requirement: The first renamed release preserves installed identifiers

Reason: reversed by this change. Unlike the preceding Agentsembli SpecForge
rename, Nogging renames the running technical surface too — see the ADDED
"Technical identifiers are renamed alongside the display name" requirement
below.

## ADDED Requirements

### Requirement: Technical identifiers are renamed alongside the display name

Unlike the preceding Agentsembli SpecForge rename, this identity change
SHALL rename the running technical surface, not only the display name: the
CLI and package SHALL be named `nogg`; the state/configuration root SHALL be
`.nogging/`; the commit trailer SHALL be `Nogging-Writer` with env var
`NOGGING_WRITER`; the entry script SHALL be `scripts/nogg`; generated systemd
units SHALL use the `nogg-` prefix, including the orchestrator singleton
session `nogg-orchestrator-<slug>`. The Beads issue-ID prefix (`SPEC-`) SHALL
NOT change.

#### Scenario: A fresh install uses the new identifiers

- **WHEN** a repository installs Nogging for the first time
- **THEN** it gets the `nogg` command, a `.nogging/` state root, and
  `Nogging-Writer`/`NOGGING_WRITER` commit conventions with no `specforge`-named
  path or command

#### Scenario: This delivery machine's existing installation is migrated, not broken

- **WHEN** the rename lands on a machine already running a `specforge`-named
  sync service and holding `.specforge/state/` data
- **THEN** the old service is stopped, the state is carried over under
  `.nogging/`, and the new `nogg-`-prefixed service is installed, enabled, and
  verified ticking before the old unit files are removed

### Requirement: Existing OpenSpec capability specs may retain historical wording

The ~17 OpenSpec capability specs that predate this change (`installer`,
`claude-sessions`, `codex-onboarding`, `pi-onboarding`, `beads-sync`,
`sync-safety`, `write-boundary`, `tool-agnostic-write-boundary`,
`branch-discipline`, `run-recovery`, `run-hygiene`, `specialist-agents`,
`orchestration-agent`, `launch-profiles`, `workflow-commands`,
`agent-neutral-launch`, `acceptance`) MAY continue to reference `specforge`,
`.specforge/`, or `SPECFORGE_WRITER` literally in their requirement text.
This divergence between spec prose and the renamed running system SHALL be
treated as an accepted, documented decision rather than a defect, until a
future change touches one of those capabilities for an unrelated reason.

#### Scenario: A reader finds "specforge" in a capability spec after the rename

- **WHEN** someone reads an unrenamed capability spec after Nogging ships
- **THEN** this requirement, or a document it points to, explains that the
  wording is historical and the running identifiers are `nogg`/`.nogging/`

### Requirement: The public README presents the Nogging brand and is complete

`README.md` SHALL present the Nogging identity using the supplied brand
assets (a banner image near the top and the "Structure for what's next."
tagline), and SHALL cover: purpose, the two-phase planning/execution model,
a working quick start using the `nogg` command, install instructions, the
non-negotiable-boundaries table, and how to run tests — with every internal
link resolving.

#### Scenario: A new visitor reads the README

- **WHEN** a visitor opens `README.md` on the renamed repository
- **THEN** the banner and tagline appear near the top
- **AND** every documented command uses the `nogg` CLI, matching what is
  actually installed
