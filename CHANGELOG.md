# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/). Entries
before `v1.6.0` are not retroactively reconstructed here; see the Git tags
and GitHub Releases for that history.

## [Unreleased]

## [2.0.0-rc.2] - 2026-09-14

A major version bump: the Nogging rename changes technical identifiers
(CLI command, state root, commit trailer) that a `v1.x` installation
relied on — see the compatibility note under Changed. Supersedes
`v2.0.0-rc.1`, which shipped without the `update` migration added below
and could not upgrade a real v1.x install.

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
