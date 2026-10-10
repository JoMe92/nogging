## ADDED Requirements

### Requirement: Launch preflight rejects an incompatible runtime helper before side effects

Session launch SHALL verify helper existence, executability and argument compatibility before tmux creation. Doctor SHALL report missing or incompatible helpers as failures. A process that fails after successful preflight SHALL leave a failed session record and durable redacted diagnostic log naming the underlying startup error.

#### Scenario: Version skew

- **WHEN** the wrapper cannot accept a flag the launcher emits
- **THEN** launch fails naming the incompatible contract and creates no pane or session record

#### Scenario: Immediate runtime exit

- **WHEN** a validated wrapper exits immediately with an error
- **THEN** the recorded failure and log preserve its underlying error even if its pane no longer exists
