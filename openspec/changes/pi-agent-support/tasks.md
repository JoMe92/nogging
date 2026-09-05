# Tasks

## Verification first

- [x] TASK-PIA-001 Install the `pi` CLI and verify hands-on: the built-in tool name(s) for shell execution and for file write/edit, the exact `tool_call` event payload shape (field names, sync vs async return), whether `--approve` and `defaultProjectTrust` behave as pi.dev's docs describe, and whether `.pi/prompts/*.md` and repo-local `AGENTS.md` are picked up as documented. Record any mismatch as a discovery and adjust the remaining tasks before writing code against it.

## Launch mechanics

- [x] TASK-PIA-002 Add a `pi` branch to `scripts/session-launch`: `cd` into `$cwd`, pass the prompt file via `--append-system-prompt`, pass `--approve` for a non-interactive supervised launch, and forward a model/provider pair when the resolved launch profile names one. Extend `session launch --agent` to accept `pi`.
- [x] TASK-PIA-003 Resolve `restricted` / `trusted` authority for `--agent pi`: both levels always keep the guard extension active (never pass a flag that would suppress or bypass it); `trusted` additionally uses the autonomous prompt. Reject a Claude or Codex profile file passed with `--agent pi`, mirroring the existing cross-agent profile rejection.

## The floor

- [x] TASK-PIA-004 Write `.pi/extensions/specforge-guard.ts`: block the SpecForge command-floor patterns (sudo, rm -rf/-fr, dd, mkfs and variants, shutdown, reboot, systemctl, chown, curl, wget, git push --force/-f/--force-with-lease, git reset --hard, git clean -fdx, git filter-branch) on the shell tool, and block a write/edit tool call under `openspec/` unless `.specforge/locks/openspec.readonly` says the boundary is open. Use the tool name(s) confirmed in TASK-PIA-001.
- [x] TASK-PIA-005 Add a `scripts/pi-guard.test.sh` that runs the extension's matching logic directly (not through a live `pi` process) against the floor command list and a set of openspec/non-openspec write paths, covering both the allow and the block side of each rule.

## Reporting and docs

- [x] TASK-PIA-006 Extend `scripts/specforge doctor`: report whether `pi` is on `PATH` (informational, absence never fails doctor, matching the existing Codex-availability pattern), and print a NOTE when `pi` is present but the project is not yet trusted for `.pi/extensions/` (name the fix: run once with `--approve` or `/trust`).
- [ ] TASK-PIA-007 Ship `.pi/prompts/{plan,discovery-review,sync-now}.md` carrying the same persona and step text as `.claude/commands/` and `.codex/prompts/`. Add `.pi/prompts` and `.pi/extensions` to `bin/lib/manifest.js` `verbatimDirs` and to `package.json` `files`.
- [ ] TASK-PIA-008 Restructure `AGENTS.md` *Tool notes* to add a **Pi** subsection: write boundary = the guard extension (not a hook, not execpolicy); specialists = out-of-process `session launch --agent pi --role specialist:<type>`; operator entry points = `.pi/prompts/`; state plainly that Pi's `restricted` level has no network or filesystem sandbox, floor-only.
- [ ] TASK-PIA-009 Write `docs/using-with-pi.md`: prerequisites (`pi` CLI + provider auth), what the installer places under `.pi/`, how `/plan` / `/discovery-review` / `/sync-now` map, the out-of-process specialist model, and the explicit limitation that `restricted` is floor-only with no sandbox. Link it from `docs/installation.md` and `docs/operating-model.md`.

## Tests

- [ ] TASK-PIA-010 Extend `scripts/session.test.sh`: `session launch --agent pi` records `pi` as the agent, is visible in `session list`, resolves `restricted`/`trusted` per TASK-PIA-003, and rejects a Claude/Codex profile file. Extend `scripts/cli.test.sh`: a packed install places `.pi/prompts/*.md` and `.pi/extensions/specforge-guard.ts`, and a fresh install's `AGENTS.md` carries the Pi *Tool notes* subsection.
