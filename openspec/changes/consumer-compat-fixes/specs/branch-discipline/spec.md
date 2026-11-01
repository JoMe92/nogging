## ADDED Requirements

### Requirement: The Beads issue ID token accepts a prefix of either case

The commit-message rule in `scripts/hooks/commit-msg` and the token reader `LIMBO_TOKEN_RE` in `scripts/nogg` SHALL accept a Beads issue ID token whose prefix is letters of either case followed by letters or digits, a dash, and a lower-case or digit suffix, so a project whose Beads IDs use a lower-case prefix can commit and is seen by `doctor` and `recover`. The two patterns SHALL accept exactly the same set of tokens. A placeholder whose suffix is not lower-case or digits, and an empty `[]`, SHALL remain refused.

#### Scenario: A lower-case prefix is accepted

- **WHEN** a non-writer commit has the subject `fix(x): y [myproject-5nql]`
- **THEN** the `commit-msg` hook accepts it

#### Scenario: An upper-case prefix is still accepted

- **WHEN** a non-writer commit has the subject `feat: y [SPEC-gjw]`
- **THEN** the `commit-msg` hook accepts it

#### Scenario: Placeholders are still refused

- **WHEN** a non-writer commit subject carries `[BEAD-XXX]`, `[bead-XXX]` or `[]`
- **THEN** the `commit-msg` hook refuses it and names the expected token

#### Scenario: A lower-case token is seen by the LIMBO check

- **WHEN** a commit on HEAD's history names `[myproject-5nql]` and the Bead with that ID is not closed
- **THEN** `doctor` and `recover` report it as LIMBO, as they do for an upper-case token
