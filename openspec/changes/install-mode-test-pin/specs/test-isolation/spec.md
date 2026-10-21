## ADDED Requirements

### Requirement: Fixtures that copy the host configuration pin the session backend

A script test that copies the host repository's `.nogging/config.json` into a
scratch repository SHALL pin the scratch repository's session backend to
`tmux` through one shared helper, unless the test exists to exercise another
backend, in which case it SHALL select that backend explicitly and install the
libraries that backend needs. A fixture SHALL NOT inherit the host's
`session_backend` value, and a fixture SHALL NOT copy herdr libraries only to
make an inherited choice load. The helper SHALL change no other key of the
copied configuration.

The repository test runner SHALL pass for a host configuration with
`"session_backend": "herdr"`. A regression check SHALL prove this by running
the affected suites against a scratch checkout whose host config selects herdr,
offline, with no herdr binary, tmux server or live session, and SHALL fail if
a suite that copies the host configuration does not use the helper.

#### Scenario: Host config selects herdr

- **WHEN** the suites that copy the host config run against a host `.nogging/config.json` with `session_backend` `herdr`
- **THEN** they pass exactly as with the key absent
- **AND** each scratch repository's config says `tmux`

#### Scenario: Other keys are preserved

- **WHEN** the helper pins a host config that carries `personas`, `tier_overrides` and custom keys
- **THEN** the pinned copy carries the same values for every key except `session_backend`

#### Scenario: A new suite copies the host config raw

- **WHEN** a script test copies `.nogging/config.json` from the host without the helper and without declaring a backend
- **THEN** the regression check fails and names the suite

#### Scenario: Backend suites keep their own selection

- **WHEN** a suite exists to exercise the herdr backend
- **THEN** it keeps selecting herdr explicitly and is unaffected by the helper
