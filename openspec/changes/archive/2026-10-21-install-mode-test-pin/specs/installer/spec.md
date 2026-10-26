## ADDED Requirements

### Requirement: Installed files keep the executable bit they have in the package

`init` and `update` SHALL give every file they copy from the package the
executable bit that the packaged source file has, whether or not the file is
named in an installer allow-list. This SHALL hold for a newly created file, an
updated file, a `--force` overwrite, and the `<file>.nogging-new` side file
written for a locally modified file. An explicit installer entry that marks a
file executable SHALL keep forcing the executable mode. A file that is not
executable in the package SHALL keep the mode the platform gives a new file.
The `<file>.orig` backup of a `--force` overwrite SHALL keep the mode of the
local file it backs up. A locally modified file SHALL keep its own mode and
content.

A managed file whose content already equals the packaged content but whose
executable bit is missing SHALL gain the bit on the next `update` or `init`,
and the run SHALL report that repair rather than `unchanged`. Dry-run SHALL
report the same action and SHALL NOT change the file.

#### Scenario: A helper added by a newer release is created executable

- **WHEN** `update` runs from a package that ships an executable helper in a repository installed by an older release that lacks the helper
- **THEN** the helper is created and is executable
- **AND** the same holds when the older install has no installed-files manifest and is resolved through a release baseline

#### Scenario: A stale helper is updated without losing the bit

- **WHEN** `update` replaces an unmodified executable helper whose content is stale
- **THEN** the helper has the new content and is executable

#### Scenario: A repository left non-executable by an earlier update is repaired

- **WHEN** a managed executable helper has the packaged content but mode `0664`, and `update` runs from the same distribution
- **THEN** the helper becomes executable
- **AND** the run reports a repair for that path, not `unchanged`
- **AND** a second `update` reports it `unchanged`

#### Scenario: Dry-run does not repair

- **WHEN** `update --dry-run` runs against the same non-executable helper
- **THEN** the report names the repair and the file mode is unchanged

#### Scenario: Side files follow the same rule

- **WHEN** an executable file is locally modified and `update` writes `<file>.nogging-new`, or `update --force` overwrites it
- **THEN** `<file>.nogging-new` and the force-overwritten file are executable
- **AND** the `.orig` backup has the mode of the local file it replaced
- **AND** without `--force` the modified file keeps its own mode and content

#### Scenario: Every executable packaged file installs executable

- **WHEN** `init` runs from the packed distribution
- **THEN** every verbatim, directory-copied and documentation file that is executable in the package is executable in the target
- **AND** no file the installer lists as executable is installed non-executable

### Requirement: Doctor's helper check passes after an upgrade from a release that lacks the helper

After `update` from any release whose install lacks a session helper that the
new release ships, `scripts/nogg doctor` SHALL NOT report that helper as
missing or not executable.

#### Scenario: v2.2.0 to the current release

- **WHEN** a v2.2.0-shaped install without `scripts/session-pty-recorder` is updated from the packed current distribution
- **THEN** the doctor session-helper check for `scripts/session-pty-recorder` does not FAIL
