## ADDED Requirements

### Requirement: Cloud sessions are instructed to push the worktree branch, not their assigned branch

The managed instruction block (`templates/claude-block.md`, and `AGENTS.md`'s
own `### Claude Code` tool notes, mirrored by `templates/agents-block.md`)
SHALL state that a cloud session's assigned `claude/*` branch is never a pull
request source: a Bead's work happens in the worktree `nogg worktree
implement`/`worktree plan` allocated, on its conformant `<type>/<slug>`
branch, and that is the branch a cloud session pushes and opens its pull
request from.

#### Scenario: The rule is present in the installed instruction block

- **WHEN** `templates/claude-block.md` or `AGENTS.md`'s Claude Code tool
  notes are read
- **THEN** they state that the `claude/*` assigned branch is never a pull
  request source
- **AND** they name the worktree-allocated branch as the one to push

### Requirement: The branch-name check names the cloud-session fix

`scripts/check-branch-name` SHALL print an additional, specific hint when the
rejected branch name matches `claude/*`, naming `nogg worktree implement`'s
branch as what to push instead — distinct from the generic convention
reminder every other rejection gets, since a cloud session hitting this in CI
has no interactive operator to ask what to do next.

#### Scenario: A claude/* branch gets the cloud-specific hint

- **WHEN** `scripts/check-branch-name` is run against a branch name starting
  with `claude/`
- **THEN** it fails
- **AND** its output includes the hint naming `nogg worktree implement`'s
  branch as the one to push

#### Scenario: A non-cloud branch does not get the cloud hint

- **WHEN** `scripts/check-branch-name` is run against a rejected branch name
  that does not start with `claude/`
- **THEN** it fails with the existing generic convention message
- **AND** it does not print the cloud-specific hint
