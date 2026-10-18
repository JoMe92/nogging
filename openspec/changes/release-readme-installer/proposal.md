## Why

`develop` carries 258 commits since `v2.2.0`. The Product Owner wants the next
release to be the first one a newcomer can pick up without help. Three gaps
stand in the way (request of 2026-10-17):

- **The README is written for people who already know Nogging.** It opens
  with the OpenSpec/Beads/Git authority model, then status, platforms, two
  diagrams and the two-phase model. The first command appears about 70 lines
  down. The quick start mixes the newcomer install with the maintainer
  planning flow. Nothing shows how a day of work goes: plan a change, launch
  a Lead, watch it, close it out.
- **The installer talks past a first-time user.** A reviewed `init --no-beads`
  in a scratch repository printed 121 lines. About 100 of them are a flat
  `create <path>` list. `.codex/rules/nogging.rules` is reported twice, once
  as `create` and once as `unchanged`. The next steps list the optional
  sync timer and the always-on orchestrator before the required `bd init`.
  The verdict repeats the tracker gap as a raw
  `bd list --status … --json: Error: no beads database found`. A ready repo
  is told to run `./scripts/nogg plan-begin` in the shared checkout, which
  bypasses the planning worktree flow. `update` repeats 102 `unchanged`
  lines and the same timer hints every time. A preserved file is reported
  three times. No step checks for `openspec`, `node`, `tmux` or an agent CLI
  before files are written. `scripts/bootstrap` prints its closing summary
  only in wizard mode, runs `doctor` again after `init` already ran it, and
  its platform refusal still says "unsupported for 2.0.x".
- **The release itself is not prepared.** `CHANGELOG.md` has an empty
  `[Unreleased]` section, although `develop` changed behaviour since
  `v2.2.0`. Install pins live in `README.md`, `docs/installation.md` and
  `scripts/bootstrap` (`NOGGING_TAG`). Three tests also hard-code `v2.2.0`.
  `docs/releasing.md` step 4 does not name `scripts/bootstrap`.

## What Changes

- **A newcomer README.** The order is: what Nogging is (2–3 sentences), a
  Quick Guide, installing (fresh machine through `scripts/bootstrap`,
  existing repository through `npx … init`), then daily use (plan a change,
  launch a Lead, watch and steer sessions, close out). Safety, status,
  platforms, concepts, architecture, documentation and maintainer topics come
  after that or are linked to `docs/`. The banner, the badge, the tagline,
  the pinned-tag rule and a shorter safety warning stay. The CI job table
  moves to `CONTRIBUTING.md`. A new structure and link test guards the order,
  and every relative link and anchor must resolve.
- **Installer preflight.** `init` and `update` first check Node, Git, Bash,
  Python, OpenSpec, `bd`, Dolt and the optional tools (tmux or herdr,
  systemd user services, an agent CLI). Each missing or too-old tool gets a
  concrete fix hint. The preflight is advisory: it never blocks, never
  installs and never uses the network.
- **Grouped installer output.** `init`, `update` and `remove` start with a
  one-line header (version, command, target). Changes are grouped by file
  class with counts, and each path appears at most once. Unchanged files
  become a count. A new `--verbose` option lists every file. Preserved
  `.nogging-new` files appear once, in a *Needs your review* block.
- **Explicit next steps and a readable verdict.** Numbered next steps end
  `init`, `update` and `remove`, required items first and optional items
  marked as optional. A ready repository is pointed at `/plan` or
  `./scripts/nogg worktree plan`. The verdict keeps its machine-read first
  line, folds duplicate gaps, never prints raw internal commands, and adds a
  fix hint for each gap. The `npx … doctor` wrapper ends with the same
  verdict.
- **Bootstrap polish.** Before installing, `scripts/bootstrap` prints the plan:
  each tool is present, will be installed or will be upgraded. It runs
  `doctor` once and shows only its findings. It ends with the same plain-text
  closing summary in both modes: what was installed, read-only login status
  and next steps that match the CLI. The stale platform wording is fixed.
- **One consistent install surface.** `docs/installation.md`, CLI help,
  bootstrap usage and the README agree on commands, flags and
  prerequisites, and a test enforces it. Pin checks read the version from
  `package.json`, so a release bump edits no test. `docs/releasing.md` step 4
  names `scripts/bootstrap`.
- **Release preparation for `v3.0.0`.** First a changelog backfill covers
  everything user-visible since `v2.2.0`. It marks three **BREAKING**
  behaviour changes, each with a migration note. The release prep then
  follows `docs/releasing.md` steps 2–5. It cuts `[Unreleased]` to
  `## [3.0.0]`, bumps `package.json` and `package-lock.json`, and moves every
  install pin to `v3.0.0`. Design Decision 7 explains why the release is a
  major one.

## Non-Goals

- Tagging, pushing the tag, the GitHub Release, release artifacts and the
  tagged smoke test (`docs/releasing.md` steps 6–11). These stay with the
  Orchestration Agent and the Product Owner.
- New runtime dependencies. The CLI stays zero-dependency Node and the
  bootstrap stays POSIX `sh`.
- Changing what `init`, `update` or `remove` write, the `.nogging-new` and
  `--force` behaviour from #165, or `init`'s idempotence.
- Making the preflight a gate, or having the installer install system tools.
  `scripts/bootstrap` stays the only provisioning path.
- Reformatting `scripts/nogg doctor` lines. Many suites parse its
  `OK`/`FAIL`/`WARN`/`NOTE` lines, so they keep their format.
- Rewriting the reference docs under `docs/` beyond the links and the
  install-surface wording named here.
- Changing repository visibility, publishing to npm, or signing an
  acceptance report.

## Impact

- Docs: `README.md`, `CONTRIBUTING.md`, `docs/installation.md`,
  `docs/releasing.md`, `docs/acceptance.md` (step 3 expected verdict) and
  `CHANGELOG.md`.
- Code: `bin/cli.js`, `bin/lib/install.js`, `bin/lib/remove.js`,
  `bin/lib/systemd.js`, `bin/lib/fsops.js`, new `bin/lib/preflight.js` and
  `bin/lib/report.js` (both listed in `package.json` `files`), and
  `scripts/bootstrap`.
- Release metadata: `package.json`, `package-lock.json` and the
  `NOGGING_TAG` pin.
- Tests: new `scripts/readme-structure.test.sh`,
  `scripts/installer-preflight.test.sh`, `scripts/installer-output.test.sh`,
  `scripts/installer-next-steps.test.sh`, `scripts/bootstrap-summary.test.sh`,
  `scripts/changelog-format.test.sh`,
  `scripts/install-surface-consistency.test.sh` and
  `scripts/release-pins.test.sh`. Some existing README and installer suites
  are adjusted where a moved heading or an output line changes.
  `scripts/acceptance.sh` and `scripts/release-smoke-test` keep parsing the
  same verdict line.

This planning artifact authorizes no tag, push of a tag, GitHub Release or
human acceptance sign-off.
