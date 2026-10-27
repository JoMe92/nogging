## MODIFIED Requirements

### Requirement: Install pins follow the package version

Every pinned install reference in `README.md`, `docs/installation.md`,
`docs/_data/install.yml` and the `NOGGING_TAG` pin in `scripts/bootstrap`
SHALL equal `v` followed by the `version` in `package.json`. Every other
reference to `github:JoMe92/nogging` or `raw.githubusercontent.com/JoMe92/nogging/`
in a Markdown page under `docs/` SHALL carry either that tag or a documented
`<tag>` or `<new-tag>` placeholder. An install reference to `main`, to
`develop` or without any tag is not allowed anywhere. Tests SHALL derive the
expected tag from `package.json` rather than hard-coding a release. The
release procedure SHALL name every file that carries a pin.

#### Scenario: A release bump misses a pin

- **WHEN** `package.json` is bumped to a new version and one pinned reference still names the previous tag
- **THEN** the pin test fails and names the file and the stale tag

#### Scenario: A version bump needs no test edit

- **WHEN** a release bumps `package.json`, `package-lock.json` and every pinned reference together
- **THEN** every pin-checking test passes without being edited

#### Scenario: A docs page names the installer without a tag

- **WHEN** a Markdown page under `docs/` writes `npx github:JoMe92/nogging init` with no `#<tag>` or `#vX.Y.Z`
- **THEN** the pin test fails and names the page and the line

#### Scenario: The site's install data drifts from the release

- **WHEN** `docs/_data/install.yml` names a tag other than the `package.json` version
- **THEN** the pin test fails and names the file and the stale tag
