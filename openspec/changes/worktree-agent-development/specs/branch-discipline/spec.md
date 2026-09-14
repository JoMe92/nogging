## MODIFIED Requirements

### Requirement: Working branches follow a named convention

The project SHALL define a branch-naming convention in which a working branch is
named `<type>/<slug>`, where `<type>` is a Conventional Commit type or `plan`.
A branch that advances an OpenSpec change SHALL use that change's
`openspec/changes/<slug>/` directory name as its `<slug>`. Work not scoped to a
single change SHALL use `chore/<topic>` or `plan/<topic>` with a free topic
slug. Planning branches MAY instead use the hierarchical form
`plan/<planning-id>/<description>`, where both path segments are non-empty
kebab-case slugs; this form identifies an isolated planning run and its subject.
The branches `main` and `develop` SHALL be exempt.

#### Scenario: Change branch matches a change directory

- **WHEN** a branch is named `feat/dark-mode-toggle`
- **AND** `openspec/changes/dark-mode-toggle/` exists
- **THEN** the branch satisfies the convention

#### Scenario: Change branch with no matching change is rejected

- **WHEN** a branch is named `feat/some-idea`
- **AND** no `openspec/changes/some-idea/` directory exists
- **THEN** the branch violates the convention

#### Scenario: Hierarchical planning branch is accepted

- **WHEN** a branch is named `plan/agent-runtime/parallel-execution`
- **THEN** the branch satisfies the convention without requiring an existing
  change directory

#### Scenario: Malformed hierarchical planning branch is rejected

- **WHEN** a branch is named `plan/agent-runtime/`
- **THEN** the branch violates the convention

#### Scenario: Unknown type is rejected

- **WHEN** a branch is named `wip/dark-mode-toggle`
- **THEN** the branch violates the convention

#### Scenario: Topic branch needs no change directory

- **WHEN** a branch is named `chore/upgrade-ci`
- **THEN** the branch satisfies the convention regardless of `openspec/changes/`

#### Scenario: Protected branches are exempt

- **WHEN** the branch is `main` or `develop`
- **THEN** the convention check does not apply

