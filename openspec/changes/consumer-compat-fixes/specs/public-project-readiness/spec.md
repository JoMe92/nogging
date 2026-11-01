## ADDED Requirements

### Requirement: Shipped files carry neutral placeholders

Files that Nogging ships into a consumer project (library scripts, test fixtures and templates) SHALL carry only neutral placeholders where they need an author address, a fixture identity or an example path: addresses on the persona roster domain (`nogging.bot`) and unexpanded path placeholders. They SHALL NOT carry a `nogging.local` address or a concrete home directory, so a consumer's release scan does not report them and the consumer does not have to edit them after an update. The usage author SHALL be `Nogging Usage <usage@nogging.bot>` in both the Dolt store and the usage sync.

#### Scenario: The usage store and sync author with the neutral address

- **WHEN** the usage store initialises or commits, or the usage sync creates its commit
- **THEN** the recorded author address is `usage@nogging.bot`

#### Scenario: Fixtures use the neutral address

- **WHEN** `scripts/pre-rebase-guard.test.sh`, `scripts/worktree-workflow.test.sh` and `scripts/agent-routing.test.sh` create their fixture repositories
- **THEN** the fixture identity is a roster-domain address, and the three suites still pass

#### Scenario: The permissions template names no home directory

- **WHEN** `templates/claude/orchestrator-permissions.example.json` is scanned for absolute host paths
- **THEN** it holds none, and its documented placeholders are `HOME` and `<repo>`
