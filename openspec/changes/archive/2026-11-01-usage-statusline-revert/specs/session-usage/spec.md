## MODIFIED Requirements

### Requirement: Missing usage sources name their remediation

When a usage window is unknown because an opt-in source is absent, the report SHALL carry an advisory hint naming the remedy, without changing any admission decision. For Claude without the statusline capture the hint SHALL be one line that names `nogg usage install-statusline`, states its effect (a capture wrapper installed as the `statusLine` in the Claude settings, previewable with `--dry-run`) and links the documentation section on why Claude usage is unknown by default. It SHALL be shown by `nogg usage`, the unknown-admitted launch warning and `doctor`.

#### Scenario: Claude statusline not installed

- **WHEN** `nogg usage --agent claude` runs with no statusline capture cache
- **THEN** each window is unknown (missing usage source) and the output names `nogg usage install-statusline`, states that it installs a capture wrapper as the Claude `statusLine`, and links the documentation section
- **AND** the gate decision is unchanged

#### Scenario: Hint reaches doctor

- **WHEN** `doctor` runs with no Claude capture cache
- **THEN** its quota NOTE names `nogg usage install-statusline`, states its effect and links the documentation section

## ADDED Requirements

### Requirement: Claude usage capture is previewable and reversible

`nogg usage install-statusline --dry-run` SHALL print the intended change to the Claude settings file (the wrapper path, any composed existing command and a diff of the settings text) and SHALL write nothing, including no wrapper, settings, backup or directory. A real install that changes the settings SHALL first back up the existing settings file and SHALL record the previous `statusLine` value, or its absence. `nogg usage uninstall-statusline` SHALL restore only the `statusLine` key from that record (removing the key when there was none), preserve every other setting, back up the settings file before changing it, and remove the wrapper and the record. It SHALL be a no-op reporting `not_installed` when the capture is not installed, SHALL refuse without changes on a malformed settings file or when no previous value can be determined, and SHALL accept `--dry-run` and `--json`.

#### Scenario: Dry run changes nothing

- **WHEN** `nogg usage install-statusline --dry-run` runs against scratch settings with an existing statusline
- **THEN** it prints the wrapper path, the composed command and a settings diff
- **AND** the settings file, the wrapper location and every directory are byte-for-byte unchanged

#### Scenario: Install then uninstall restores the previous statusLine

- **WHEN** capture is installed over a `statusLine` object with extra keys and an unrelated setting is edited afterwards, then `nogg usage uninstall-statusline` runs
- **THEN** the original `statusLine` object is back exactly and the edited unrelated setting is preserved
- **AND** the install and uninstall backups exist and the wrapper and restore record are gone

#### Scenario: No prior statusline

- **WHEN** capture was installed with no previous `statusLine` and is then uninstalled
- **THEN** the `statusLine` key is removed and all other settings are unchanged

#### Scenario: Not installed

- **WHEN** `nogg usage uninstall-statusline` runs and the statusline does not reference the wrapper, or runs a second time
- **THEN** it reports `not_installed`, exits 0 and changes nothing

#### Scenario: Install made before the restore record existed

- **WHEN** uninstall runs for a capture installed without a restore record and the wrapper still names its composed command
- **THEN** the composed command is restored as a command statusline, or the key is removed when none was composed
