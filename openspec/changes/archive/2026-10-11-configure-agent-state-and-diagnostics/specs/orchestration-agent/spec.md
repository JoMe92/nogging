## ADDED Requirements

### Requirement: Interactive orchestrator sessions have a documented permission template

Nogging SHALL ship a Claude settings template for interactive Orchestration Agent sessions containing allow rules for the repository's sibling worktree path pattern and `scripts/nogg` commands, and a deny list that includes every command-floor entry. The documentation SHALL state that allow rules do not bypass the auto-mode classifier, that `autoMode` configuration is read only from user settings, and that the operator applies the template manually. The installer SHALL NOT write the template into any settings file. A test SHALL verify the template is valid JSON and that its deny list is a superset of the command floor.

#### Scenario: Floor drift is caught

- **WHEN** a command-floor entry is added that the template's deny list lacks
- **THEN** the template test fails

#### Scenario: Install leaves user settings untouched

- **WHEN** `nogg init` or `nogg update` runs
- **THEN** no user or project settings file gains the template's rules
