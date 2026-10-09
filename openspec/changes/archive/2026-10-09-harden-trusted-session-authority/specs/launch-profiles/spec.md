## MODIFIED Requirements

### Requirement: The trusted profile does not block on a first-time Bash approval prompt

The `trusted` profile SHALL set `permissions.defaultMode` to `bypassPermissions`
and SHALL set a top-level `skipDangerousModePermissionPrompt` key to `true`, so
that a genuinely unattended `--full-access` session can run any command not
named in the profile's `deny` list — including one that would otherwise
require an interactive approval, a classifier review, or a one-time
bypass-permissions disclaimer dialog — without an operator present to answer
it.

#### Scenario: A fresh full-access session does not hang on its first qualifying Bash command

- **WHEN** a session is launched with `--full-access` (the `trusted` profile)
- **AND** it runs a Bash command not named in the profile's `deny` list
- **THEN** the command proceeds without an interactive prompt, a classifier
  review, or a disclaimer dialog blocking the session

#### Scenario: The trusted profile's deny list is unaffected

- **WHEN** a session runs under the `trusted` profile
- **THEN** it still cannot run any command the profile's `deny` list names,
  regardless of the `defaultMode` value

#### Scenario: A fresh full-access session does not block on the bypass-permissions disclaimer

- **WHEN** a session is launched with `--full-access` for the first time in a
  given session directory
- **THEN** no interactive "accept responsibility" disclaimer dialog blocks the
  session, because the profile's `skipDangerousModePermissionPrompt: true` key
  is already in effect

## ADDED Requirements

### Requirement: `doctor` flags a misconfigured or drifted bypass-permissions profile

For every Claude launch-profile JSON file under `.nogging/launch-profiles/`,
`scripts/nogg doctor` SHALL report a `NOTE` (never a failure) when the file
sets `permissions.defaultMode` to `bypassPermissions` without also setting a
top-level `skipDangerousModePermissionPrompt: true`, and SHALL report a
separate `NOTE` when a shipped profile's filename (`trusted.json`,
`orchestrator.json`) carries a `defaultMode` other than the value
`docs/security-model.md` documents for it.

#### Scenario: Missing disclaimer-skip key is flagged

- **WHEN** a launch-profile JSON sets `permissions.defaultMode:
  "bypassPermissions"` and omits `skipDangerousModePermissionPrompt`
- **AND** an operator runs `scripts/nogg doctor`
- **THEN** its output includes a `NOTE` naming that profile file and the
  missing key

#### Scenario: A correctly paired profile is silent

- **WHEN** a launch-profile JSON sets both `permissions.defaultMode:
  "bypassPermissions"` and `skipDangerousModePermissionPrompt: true`
- **THEN** `scripts/nogg doctor` reports no `NOTE` for that file under this
  check

#### Scenario: A drifted shipped profile is flagged

- **WHEN** an installed `trusted.json` or `orchestrator.json` has a
  `defaultMode` other than what `docs/security-model.md` documents for it
- **AND** an operator runs `scripts/nogg doctor`
- **THEN** its output includes a `NOTE` naming the file and the mismatch
