## ADDED Requirements

### Requirement: A standalone bootstrap script provisions the whole supported toolchain

Nogging SHALL provide `scripts/bootstrap`, a standalone shell script runnable
via `curl | bash` without requiring Node or any other Nogging dependency to
already be present. On a supported platform (Debian/Ubuntu-family Linux,
x86_64 or aarch64, per `docs/compatibility.md`), running it with nothing
pre-installed SHALL result in a working target repository — Node, `bd`,
Dolt, the Claude Code / Codex / OpenSpec CLIs, `git`, `tmux`, and `gh`
present at the versions `docs/compatibility.md` documents as validated, and
the Nogging payload installed via `init`.

#### Scenario: A fresh, supported machine reaches a working install

- **WHEN** `scripts/bootstrap` runs on a supported platform with none of the
  toolchain pre-installed
- **THEN** every tool `docs/compatibility.md` documents as required ends up
  installed at a version satisfying its documented baseline
- **AND** the target repository has the Nogging payload installed and
  `scripts/nogg doctor` reports it healthy

#### Scenario: An unsupported platform is refused up front

- **WHEN** `scripts/bootstrap` runs on a platform outside the supported set
- **THEN** it prints the supported-platform statement and exits non-zero
- **AND** it installs nothing

### Requirement: Bootstrap orchestrates each tool's own official, pinned installer

`scripts/bootstrap` SHALL install `bd` and Dolt via each project's own
official install script, referenced at an exact pinned release tag rather
than a "latest" alias, and SHALL install the Node-ecosystem CLIs
(`@anthropic-ai/claude-code`, `@openai/codex`, `@fission-ai/openspec`, and
`@earendil-works/pi-coding-agent` when `--with-pi` is given) via
`npm install -g <package>@<pinned-version>`. It SHALL NOT implement its own
binary download or checksum verification for `bd` or Dolt.

#### Scenario: bd and Dolt install from a pinned release tag

- **WHEN** `scripts/bootstrap` installs `bd` or Dolt
- **THEN** it fetches that project's own install script from a URL naming
  an exact release tag
- **AND** that URL does not resolve to a "latest" alias

#### Scenario: Node-ecosystem CLIs install at the pinned version

- **WHEN** `scripts/bootstrap` installs Claude Code, Codex, or the OpenSpec
  CLI
- **THEN** the `npm install -g` command names an exact pinned version for
  that package

### Requirement: Bootstrap is idempotent and version-aware

Re-running `scripts/bootstrap` on a machine where every tool already
satisfies its pinned baseline SHALL change nothing and SHALL report each
tool as already satisfied, rather than reinstalling unconditionally. A tool
present but outside the satisfying range SHALL be upgraded to the pin.

#### Scenario: A second run on an already-provisioned machine is a no-op

- **WHEN** `scripts/bootstrap` runs a second time on a machine it already
  fully provisioned, with nothing changed in between
- **THEN** it makes no installation changes
- **AND** it reports every tool as already satisfying its pin

#### Scenario: An out-of-range tool is upgraded to the pin

- **WHEN** `scripts/bootstrap` finds a tool installed at a version outside
  the documented baseline's satisfying range
- **THEN** it installs the pinned version over it

### Requirement: Bootstrap's version pins cannot silently drift from the documented baseline

A test SHALL verify that every version `scripts/bootstrap` pins matches the
corresponding entry in `docs/compatibility.md`'s version table, and SHALL
fail when any pin disagrees with the documented baseline.

#### Scenario: A pin mismatch fails the test

- **WHEN** `scripts/bootstrap`'s pinned version for a tool does not match
  `docs/compatibility.md`'s documented baseline for that tool
- **THEN** the pin-consistency test fails, naming the mismatched tool
