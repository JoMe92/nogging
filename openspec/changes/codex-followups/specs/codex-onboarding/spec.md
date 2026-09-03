## MODIFIED Requirements

### Requirement: The Codex authority floor mirrors the Claude floor

`.codex/rules/specforge.rules` SHALL deny, for a Codex session, exactly the
command classes the Claude launch floor (`FLOOR_DENY`) denies in *every* session
regardless of profile: `sudo`, recursive force-delete (`rm -rf`, `rm -fr`),
`dd`, filesystem-format (`mkfs` and its variants), `shutdown`, `reboot`,
`systemctl`, `chown`, and outbound network fetch (`curl`, `wget`). A Codex
session running under this floor SHALL NOT be able to run those commands, at any
authority level, and `session launch --agent codex` SHALL NOT pass
`--ignore-rules`.

Remote-operation denial for a *restricted* Codex session (`git push`, remote
Dolt/Beads sync) SHALL be provided by the network-off workspace-write sandbox
(`sandbox_workspace_write.network_access=false`), not by the execpolicy
`.rules` file.

#### Scenario: The floor denies destructive shell from a Codex session

- **WHEN** a Codex session started under the SpecForge floor attempts `sudo` or a recursive force-delete
- **THEN** the command is denied by the execpolicy rules

#### Scenario: The floor denies outbound fetch from a Codex session

- **WHEN** a Codex session started under the SpecForge floor attempts `curl` or `wget`
- **THEN** the command is denied by the execpolicy rules

#### Scenario: The floor denies a push from a Codex session

- **WHEN** a Codex session at the `restricted` authority level attempts `git push`
- **THEN** the command fails — the launch set `sandbox_workspace_write.network_access=false`, so there is no route to a remote
- **AND** `.codex/rules/specforge.rules` checked against `git push` with `codex execpolicy check` matches no rule (the floor does not itself forbid it)

## ADDED Requirements

### Requirement: A trusted Codex session can complete an integration

The `trusted` / `--full-access` authority level for `session launch --agent
codex` SHALL enable network access
(`sandbox_workspace_write.network_access=true`), so a trusted Codex Lead session
can `git push` its change branch and `git push origin develop` to finish an
integration without a pull request — matching the Claude `trusted` path. The
`restricted` level SHALL keep network access disabled.

#### Scenario: A full-access Codex launch enables network

- **WHEN** a session is launched with `--agent codex --full-access` (or `--profile trusted`)
- **THEN** the launch sets `sandbox_workspace_write.network_access=true`

#### Scenario: A restricted Codex launch disables network

- **WHEN** a session is launched with `--agent codex` at the default authority level
- **THEN** the launch sets `sandbox_workspace_write.network_access=false`

### Requirement: A helper links the repo Codex prompts into CODEX_HOME

Because Codex reads custom prompts only from `$CODEX_HOME/prompts/`,
`scripts/specforge` SHALL provide `codex-prompts-link [--unlink]` that
idempotently symlinks every `.codex/prompts/*.md` in the repository to
`${CODEX_HOME:-$HOME/.codex}/prompts/specforge-<basename>.md`, repointing a
stale SpecForge symlink, leaving a correct one, and reporting (not overwriting) a
real file that is not a SpecForge symlink. `--unlink` SHALL remove only the
`specforge-*` symlinks the helper created. The installer's `init` / `update`
SHALL NOT perform this linking automatically.

`scripts/specforge doctor` SHALL print an informational line — never a failure —
when `codex` is on `PATH`, `.codex/prompts/*.md` exist in the repository, and at
least one is not linked into `${CODEX_HOME:-$HOME/.codex}/prompts/`, naming the
`codex-prompts-link` helper.

#### Scenario: The helper links each repo prompt

- **WHEN** `./scripts/specforge codex-prompts-link` runs with an empty `$CODEX_HOME/prompts/`
- **THEN** `$CODEX_HOME/prompts/specforge-plan.md`, `specforge-discovery-review.md` and `specforge-sync-now.md` are symlinks to the repo files

#### Scenario: The helper is idempotent and reversible

- **WHEN** `codex-prompts-link` is run twice, then `codex-prompts-link --unlink`
- **THEN** the second run changes nothing
- **AND** `--unlink` leaves `$CODEX_HOME/prompts/` with no `specforge-*` symlinks

#### Scenario: doctor notes unlinked prompts without failing

- **WHEN** `codex` is on `PATH`, the repo has `.codex/prompts/*.md`, and none are linked into `$CODEX_HOME/prompts/`
- **AND** `doctor` runs
- **THEN** it prints a NOTE naming `codex-prompts-link`
- **AND** it does not exit non-zero because of that NOTE
