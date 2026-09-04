## ADDED Requirements

### Requirement: doctor's tool-presence checks reflect the invoking process's PATH

`scripts/specforge doctor` SHALL determine whether `git`, `python3`, `bd`,
`dolt`, and `codex` are available by resolving each name against the
invoking process's own `PATH` directly (e.g. `shutil.which`), and SHALL NOT
re-derive `PATH` through a login shell or any other mechanism that can reset
it from system profile scripts.

#### Scenario: A tool on the caller's PATH is detected even when a login shell would hide it

- **WHEN** a tool is available via the invoking process's `PATH`, but a login
  shell's profile scripts would reset `PATH` and hide it
- **THEN** `doctor` still reports the tool as present
