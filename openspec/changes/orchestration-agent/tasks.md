# Tasks

Detail and rationale for every task are in `design.md`. Task titles are kept
short so `materialize` can use them as Bead titles.

## Verification first

- [x] TASK-ORC-001 Verify hands-on in a `tmux -L specforge` session: `claude --continue` resumes a prior conversation non-interactively; a `bypassPermissions` settings file with an empty deny list suppresses all prompts in a piped pane; the process registers with Remote Control and re-registers after a restart. Record mismatches as discoveries and adjust TASK-ORC-005 / TASK-ORC-007.

## Authority level

- [x] TASK-ORC-002 Ship `.specforge/launch-profiles/orchestrator.json` — `bypassPermissions`, empty `allow`/`deny`, `additionalDirectories: ["/"]`, `specforge_floor: false`, `specforge_openspec_readonly: false`; header comment: Claude-only, no `.codex.toml`/`.pi.toml`, keys honoured only for `--role orchestrator`.
- [x] TASK-ORC-003 `scripts/specforge`: `normalize_role()` accepts `orchestrator`; `session_launch()` allows `--bead` to be omitted for `--role orchestrator` (record `bead_id: null`), still required for every other role.
- [x] TASK-ORC-004 `scripts/specforge` `session_launch()`: read `specforge_floor` / `specforge_openspec_readonly` from the profile only when the role is `orchestrator`; when `false`, skip the `merge_floor()` union and the per-session `openspec/**` deny rules respectively. Ignore the keys for every other role. Record `floor_lifted`; render `FULL-ACCESS` in `session list`.

## Always-on lifecycle

- [ ] TASK-ORC-005 Add the `orchestrator` subcommand group to `scripts/specforge`: `run` (idempotent supervisor — acquire the lock, adopt or create `sf-orchestrator-<slug>`, `claude --continue` when a conversation exists else launch with the prompt + effective settings, refresh the record, block until exit, release the lock, exit non-zero), `status`, `stop`, `restart`.
- [x] TASK-ORC-006 Add `.specforge/locks/orchestrator.lock` — same JSON shape and staleness rule as the planning lock, independent of it; `run` refuses and names the holder when a fresh lock is held by a live process; `--force` reclaim consistent with `plan-end --force`.

## Persona

- [x] TASK-ORC-007 Write `.specforge/launch-prompts/orchestrator.md` per design.md: orchestrate-only by default; explicit `/orchestrate takeover {plan|code}` is one task then back (takeover-plan commits with the `SpecForge-Writer: planning` trailer, takeover-code with the `[<bead-id>]` token); one sub-session at a time unless it provisions worktrees; never sign an acceptance report; never echo a credential.
- [ ] TASK-ORC-008 Write `.claude/commands/orchestrate.md` — how the operator reaches the always-on session (`orchestrator status`, `session attach`, Remote Control), the `takeover {plan|code} <description>` single-task format, a pointer to the operating-model section, and a note that Codex/Pi pendants are not shipped in v1.

## Installer

- [ ] TASK-ORC-009 Add `templates/systemd/specforge-orchestrator.service.tmpl` and a `bin/lib/manifest.js` `systemd` entry rendering `systemd/specforge-orchestrator-{slug}.service` (`Type=simple`, `ExecStart=… orchestrator run`, `Restart=always`, `WantedBy=default.target`). Verify the profile/prompt ride the existing verbatim dirs. `init`/`update` print the `systemctl --user enable --now` line and the `loginctl enable-linger` hint.
- [ ] TASK-ORC-010 Extend `scripts/specforge doctor`: report the orchestrator service state, linger on/off, and whether a FULL-ACCESS orchestrator session is live. Absence/inactivity never fails `doctor`; only `enabled` + linger off rates a NOTE.

## Docs

- [ ] TASK-ORC-011 Update the docs per design.md: `docs/operating-model.md` (Roles + a new Orchestration section), `docs/architecture.md` (the command floor is no longer absolute — the narrow `--role orchestrator` exception, safeguards named), `docs/running-work-in-sessions.md` (the `orchestrator` subcommands + linger), and the persona/boundary in `AGENTS.md`, `templates/agents-block.md`, `CLAUDE.md`, `templates/claude-block.md`.

## Tests

- [ ] TASK-ORC-012 Extend `scripts/session.test.sh` (orchestrator launches Bead-less, listed FULL-ACCESS, floor lifted only for `--role orchestrator` + the `orchestrator` profile, a `lead` session on that profile still floored) and `scripts/cli.test.sh` (packed install renders the unit and ships the profile/prompt). Add `scripts/orchestrator.test.sh` for the lock and the idempotent adopt path, tmux/`claude` stubbed.
