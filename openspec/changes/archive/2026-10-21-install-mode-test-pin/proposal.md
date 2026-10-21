## Why

Two bugs in the shipped v3.0.0, each reported with a GitHub issue.

**#263: installed files lose the upstream executable bit.** `nogging update`
from v2.2.0 to v3.0.0 creates `scripts/session-pty-recorder` with mode `0664`
although the file is `100755` in the package. `./scripts/nogg doctor` then
FAILs (`session helper … is missing or not executable`), and re-running
`update` from the same distribution does not repair it. The cause is in
`bin/lib/install.js` and `bin/lib/fsops.js`: a mode is applied only to paths
listed in `manifest.executable`, and `scripts/session-pty-recorder` is
`verbatim` but not in that list. `scripts/session-log-writer` is listed, which
is why it kept `0755`. The same gap hides in every other verbatim or
directory-copied file that is executable upstream but not listed (the
`*.test.sh` files shipped to consumers today). The helper is used only by the
herdr backend, so the break is silent on tmux.

**#264: a test fixture breaks when the host selects herdr.** With
`"session_backend": "herdr"` in the host `.nogging/config.json`,
`scripts/worktree-workflow.test.sh` fails. The fixture copies the host config
into a scratch repo but installs only the tmux backend libraries, so the
scratch repo selects a backend it cannot load. Any repository that switches to
the herdr backend gets a red `scripts/test` gate with a healthy installation,
and the test ships to consumers, so they hit it too. The sweep for this change
(see design) found the same flaw in other suites that copy the host config.

## What Changes

- **Installer.** `init` and `update` keep the executable bit the file has in
  the package, for every file they copy, not only for names in
  `manifest.executable`: created files, updated files, `--force` overwrites and
  the `<file>.nogging-new` side file. A managed file whose content already
  matches upstream but lost the executable bit (the state v3.0.0 left behind)
  is repaired by the next `update`. A locally modified file stays untouched.
  `manifest.executable` stays as an explicit override.
- **Test fixtures.** Fixtures that copy the host `.nogging/config.json` pin the
  scratch repo's `session_backend` to `tmux` through one shared helper, instead
  of inheriting the host's choice, and the backend libraries they install match
  what the pinned config selects. A regression check runs the affected suites
  against a host config with `session_backend` set to `herdr`.
- **Changelog.** Each task adds a `### Fixed` entry under `## [Unreleased]` in
  `CHANGELOG.md`.

## Non-goals

- No change to `scripts/nogg doctor`, to the herdr backend or to the herdr
  libraries a fixture copies: the fixtures are not about herdr, so they are
  pinned, not taught to load it. Herdr coverage stays in the existing
  `session-backend-herdr`, `session-herdr*` and `doctor-herdr` suites.
- No change to the file classes, the manifest format or the digest and
  preserve/update/force rules. Only the file mode is added to them.
- No change to non-executable file modes: they keep following the umask.

## Impact

- Capabilities: `installer` (mode preservation), `test-isolation` (fixture
  backend pin).
- Code: `bin/lib/fsops.js`, `bin/lib/install.js`, possibly `bin/lib/manifest.js`
  comments; new `scripts/installer-file-mode.test.sh`; a shared fixture helper
  under `scripts/lib/`; the affected `scripts/*.test.sh`; `CHANGELOG.md`.
- Docs: none beyond the changelog, unless a doc states that only listed files
  are made executable.
