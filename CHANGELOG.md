# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/). Entries
before `v1.6.0` are not retroactively reconstructed here; see the Git tags
and GitHub Releases for that history.

## [Unreleased]

## [2.1.0] - 2026-10-03

### Added

- `scripts/nogg session watch`: agent-neutral session-state observability for
  Claude Code and Codex sessions (`working` / `waiting_background` / `idle` /
  `needs_input` / `limit` / `stalled` / `ended`), via per-agent adapters
  (patterns as data, not free-text keyword matching) plus an optional Claude
  `Stop`/`Notification` hook events layer. Usage-limit messages are recognized
  and resolved to an absolute reset timestamp. `scripts/nogg session
  resume-when-ready` waits out a detected limit and nudges the session to
  continue without switching models. `scripts/nogg session send --verify`
  confirms a message was actually submitted, not left sitting in an input box.
- Opt-in multi-machine Beads sync: `"multi_machine": true` in
  `.nogging/config.json` makes a `trusted`/orchestrator session `bd dolt pull`
  at session start and `bd dolt push` before ending if it wrote a Bead;
  `doctor` reports unpushed local Dolt state. Default stays off.
- Cloud session (Claude Code on the web) branch discipline: the managed
  instruction block states the assigned `claude/*` branch is never a PR
  source; an optional `SessionStart` hook template bootstraps `bd`/Dolt and
  git hooks in a fresh cloud container; `check-branch-name` gives a
  cloud-specific hint.
- `scripts/nogg task-done <bead-id>` ticks a closed Bead's `tasks.md` line
  immediately; `doctor` reports a change ready to archive once every mapped
  Bead is closed; `/plan`'s sequence gained a conditional archive step.
- `scripts/bootstrap`: a standalone, pinned-version bootstrap installer for
  the whole supported toolchain (Node via `nvm`, Claude Code, Codex, the
  OpenSpec CLI, `bd`, Dolt, `git`/`tmux`/`gh`) on Debian/Ubuntu Linux, runnable
  via `curl | bash` with no prerequisite but a shell. Idempotent; a
  pin-consistency test keeps it from drifting against `docs/compatibility.md`.
- A per-persona commit identity roster (Planner, Lead, Orchestrator, Sync, and
  each specialist) in `.nogging/config.json`'s `personas` key. A session's
  worktree carries its persona's `user.name`/`user.email`, isolated per
  worktree via `extensions.worktreeConfig`; the Lead Agent delegation protocol
  credits an incorporated specialist's work with a `Co-authored-by:` trailer.
  Tier 1 only (plain git identity) in this release — real GitHub `[bot]`
  identities via a registered GitHub App remain a documented, opt-in
  follow-up.

### Fixed

- `EnterWorktree`'s relocation-approval prompt blocked every autonomous Lead
  session on its first worktree entry; the autonomous launch prompt now
  instructs a plain `cd` instead, which Claude Code does not gate the same way.
- The `trusted` launch profile's `defaultMode` is now `auto`, not
  `acceptEdits`: an unattended `--full-access` session no longer hangs on its
  first qualifying Bash command waiting for an operator to approve it.
- A Codex session's `workspace-write` sandbox now includes the shared
  checkout (`--add-dir`) at every authority level, so a session running from
  an implementation/planning worktree can reach the shared `.git`/`.beads` it
  needs for `git commit`/`push` and `bd`/`scripts/nogg`.

## [2.0.2] - 2026-09-16

Documentation-only release: no installed CLI behavior changes.

### Removed

- The README's "Brand" section (palette hex table, typography note, the
  nogging timber-framing etymology, voice guidance). Brand-design detail an
  end user of the tool doesn't need — it already lives, more completely, in
  the private `JoMe92/rooftree` companion repo. `docs/brand/` itself (the
  actual logo/banner/social-card/diagram image assets the README embeds) is
  unaffected.

## [2.0.1] - 2026-09-15

Documentation-only release: no installed CLI behavior changes.

### Added

- Four diagrams in the README (communication model, tool map, quick start,
  daily workflow), rendered from the Nogging Claude Design project.
- A CI status badge and a "Tests and CI" section documenting every
  `nogging-validate.yml` job.
- A "Brand" section in the README with the palette sampled from the shipped
  brand assets.
- `docs/README.md`, a categorized index of the `docs/` folder (Concepts /
  Using Nogging / Releasing and maintaining).

### Changed

- Moved the brand asset directory to `docs/brand/` (was `brand/`).
- Moved product-planning and internal audit/status documents
  (`docs/product-identity/`, `docs/security/`,
  `docs/public-release-readiness-report.md`) to the new private
  `JoMe92/rooftree` companion repository; they are not something an end user
  of the public tool needs.
- `docs/architecture.md` is now linked from the README documentation table.

### Fixed

- The Quick start and Install sections were still pinned to the pre-rename
  `v1.6.0` tag despite `v2.0.0` having been tagged and released; bumped to
  the current tag.
- `docs/compatibility.md` still described "Nogging 1.6.x" and linked a
  superseded acceptance report as "latest".

## [2.0.0] - 2026-09-14

A major version bump: the Nogging rename changes technical identifiers
(CLI command, state root, commit trailer) that a `v1.x` installation
relied on — see the compatibility note under Changed. Released from
release candidate `v2.0.0-rc.2` (`v2.0.0-rc.1` was pushed, found unable
to upgrade a real v1.x install, and superseded by rc.2's `update`
migration fix) with no further code changes.

### Changed

- **BREAKING**: renamed the project from Agentsembli SpecForge to
  **Nogging**. The CLI command is now `nogg` (was `specforge`), the state
  root is `.nogging/` (was `.specforge/`), the commit trailer/env var are
  `Nogging-Writer`/`NOGGING_WRITER` (were `SpecForge-Writer`/`SPECFORGE_WRITER`),
  generated systemd units use the `nogg-` prefix (were `specforge-`), and the
  canonical repository is `JoMe92/nogging` (was `JoMe92/agentsembli-specforge`).
  See `docs/product-identity/` for the full provenance chain.

### Added

- Full brand identity assets and a rewritten, user-first `README.md`.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, a refreshed `SECURITY.md` route,
  issue forms, and a pull-request template.
- CLI release-lifecycle commands: report the installed version, update to a
  pinned tag, roll back, and uninstall while preserving target-owned state.
- A documented compatibility policy and matrix (Node 18/20/22, Python
  3.9/3.11/3.13, Git, Bash, OpenSpec, Beads, Dolt, tmux, systemd, and every
  supported Claude/Codex/Pi path).
- A public security and threat-model guide.
- CI hardening: least-privilege workflow permissions, action revisions
  pinned to full SHAs, Dependabot for npm and Actions, and dependency,
  secret, and package-content gates — each verified to fail against an
  intentionally bad fixture and pass on the real repository.
- This changelog, a release-consistency check, checksum/SBOM generation,
  and an exact-tag install smoke test (`scripts/release-check`,
  `scripts/release-artifacts`, `scripts/release-smoke-test`); see
  `docs/releasing.md`.

### Fixed

- `recover`'s stale-claim check failed to parse Beads' `Z`-suffixed
  timestamps on Python 3.9/3.10 (`datetime.fromisoformat` only accepted the
  `Z` suffix from Python 3.11), so an old claim was silently never reported
  as stale on those versions.
- `update` refused outright against a real v1.x install (`no .nogging/config.json
  — run init first`) because it never recognized the legacy `.specforge/`
  state root. `init`/`update` now migrate `.specforge/` to `.nogging/` in
  place (config, launch-profiles, launch-prompts, locks, state) the first
  time either runs against a legacy install.

### Removed

- Minimized the published npm package payload: internal research notes,
  acceptance history, and generated/cache artifacts are no longer packed.
