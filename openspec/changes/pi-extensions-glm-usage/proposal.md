## Why

On 2026-10-27 the Product Owner (Jonas) asked for a home for Pi extensions
inside Nogging, because Pi is to become the central coding tool over the
coming weeks and months. The first extension reads the Z.ai (GLM) coding-plan
usage and shows it in Pi's footer. Today Nogging has no place for such work:
the only Pi extension is the mandatory guard in `.pi/extensions/`, which Pi
auto-loads in every trusted project.

The same reading matters beyond the footer. Pi with GLM is now the first
choice for implementation Leads (`configurable-agent-routing`), and the
Product Owner's rule is that an agent is used only when its usage is known
and fits. `nogg usage` cannot see GLM quota at all, so every Pi launch is
admitted blind under `on_unknown: "warn"`.

## What Changes

- Add a home for optional Nogging Pi features under `.pi/nogging/`: one
  directory per extension under `extensions/`, shared helpers under `lib/`,
  tests and fixtures beside each extension, and a README with the
  conventions. Pi never auto-discovers this tree. Extensions are plain
  TypeScript that Pi loads without a build step. They use only Node built-ins
  and relative imports, take Pi types through `import type` and add no npm
  dependency. The mandatory guard stays where it is.
- Add an offline test runner, `scripts/pi-extensions.test.sh`. It runs every
  extension test with Node's built-in test runner and type stripping, with
  no Pi, no network and no build step. It also lints the conventions. It
  skips with a pass when Node cannot load TypeScript, like the guard test.
- Make each extension opt-in in two ways. For supervised sessions, list it in
  the new `pi_extensions` config key, and `session launch --agent pi` loads
  it with `--extension`. For standalone Pi, `nogg pi-ext install <name>` runs
  Pi's own `pi install` on the main checkout's copy. `nogg pi-ext list` and
  `nogg pi-ext remove <name>` complete the set. `validate`, `doctor` and launch
  refuse an unknown or missing enabled extension.
- Ship `.pi/nogging/` to consumer repositories with `init` and `update`,
  enabled nowhere by default.
- Add the first extension, `glm-usage`. It reads the API key only through
  Pi's model registry, polls the Z.ai quota endpoint at most every three
  minutes, and shows both windows in the footer: the 5-hour window and the
  weekly one, each as percent free with time to reset. It adds a
  `/glm-usage` command. On an error it keeps the last value and marks it
  stale. A missing key makes no request. It writes a key-free snapshot to
  Nogging's usage cache, which concurrent Pi sessions share so they do not
  each poll.
- Teach `nogg usage --agent pi` and the launch usage gate to read that
  snapshot. When the snapshot is stale or missing, they run one bounded
  probe that gets the key from `pi auth print-api-key` and never stores or
  prints it. Pi usage becomes known for the usage gate, so
  `configurable-agent-routing` sees real `usage-denied` and `usage-unknown`
  outcomes for Pi without any change to routing itself.
- Document all of it on a new docs-site page, `docs/pi-extensions.md`, and
  update the Pi, usage-limits, configuration and command pages.

## Capabilities

### New Capabilities

- `pi-extensions`: the `.pi/nogging/` home and its conventions, the offline
  test runner, the opt-in activation paths (supervised config and personal
  install), diagnostics and packaging.
- `glm-usage`: the first extension. It covers key handling, polling, the
  footer and command, error, stale and missing-key behaviour, and the shared
  snapshot.

### Modified Capabilities

- `session-usage`: Pi quota comes from the Z.ai coding-plan observation, with
  a bounded probe and named remediation, instead of always being unknown.

## Impact

New files: `.pi/nogging/**`, `scripts/pi-extensions.test.sh`, a Z.ai quota
module beside `scripts/nogg_usage.py`, `docs/pi-extensions.md`. Changed code:
`scripts/nogg` (`pi-ext`, launch, `validate`, `doctor`), `scripts/session-launch`
(the Pi branch), `scripts/nogg_usage.py`, `scripts/test` (probe disabled by
default), `bin/lib/manifest.js`, `package.json`, `templates/nogging-config.json`.
Docs: `docs/using-with-pi.md`, `docs/usage-limits.md`, `docs/configuration.md`,
`docs/commands.md`, `docs/README.md`, `AGENTS.md` (Pi tool note), `CHANGELOG.md`.

Existing installs need no migration. Without `pi_extensions`, a Pi launch is
byte-for-byte as before apart from the usage gate, which now reports known Z.ai
windows where it used to report unknown. The endpoint is undocumented and may
change. When it does, the extension shows the error and `nogg usage` reports
unknown, never zero.

This change does not modify `configurable-agent-routing`, the guard extension,
or the shipped model-selection table, and it adds no Pi CI job.
