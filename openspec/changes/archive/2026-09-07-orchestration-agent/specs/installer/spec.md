## MODIFIED Requirements

### Requirement: File classes have distinct write strategies

The installer SHALL treat each installed path according to its class:

- **Tool files** (the `scripts/specforge` bridge, `scripts/install-hooks`, the
  test runner, the three write-boundary hooks, `.agents/skills`) SHALL be
  copied verbatim and overwritten on every `init` and `update`.
- **Scaffold files** (`openspec/config.yaml`, `openspec/project.md`,
  `.specforge/config.json`) SHALL be written only when absent and SHALL NOT be
  overwritten.
- **Foreign files** (`.claude/settings.json`, `.gitignore`, `CLAUDE.md`,
  `AGENTS.md`) SHALL be merged idempotently, preserving existing unrelated
  content, and SHALL be created when absent.
- **Rendered files** (the systemd sync service and timer, and the systemd
  orchestrator service) SHALL be generated with the target repository's
  absolute path and a per-repository unit name.

#### Scenario: Scaffold file is preserved

- **WHEN** `init` runs in a repository that already has `openspec/project.md`
- **THEN** the existing `openspec/project.md` is left unchanged

#### Scenario: Tool file is refreshed

- **WHEN** `update` runs after a new release changed `scripts/specforge`
- **THEN** the repository's `scripts/specforge` is replaced with the released version

#### Scenario: Foreign file keeps unrelated content

- **WHEN** the installer merges into a `.claude/settings.json` that already contains unrelated hooks and settings
- **THEN** those unrelated hooks and settings remain intact after the merge

## ADDED Requirements

### Requirement: The installer renders a per-repository orchestrator service

`init` and `update` SHALL render `systemd/specforge-orchestrator-<slug>.service`
with the target repository's absolute path as `WorkingDirectory`, an
`ExecStart` of `<abs path>/scripts/specforge orchestrator run`,
`Restart=always`, and `WantedBy=default.target`, using the same per-repository
slug as the sync unit. The `orchestrator` launch profile and prompt SHALL be
delivered by the existing verbatim `launch-profiles` / `launch-prompts`
directory copy.

#### Scenario: The orchestrator unit targets the installing repository

- **WHEN** `init` runs in `/srv/project-a`
- **THEN** `systemd/specforge-orchestrator-project-a.service` is generated with `WorkingDirectory=/srv/project-a` and `ExecStart=/srv/project-a/scripts/specforge orchestrator run`

#### Scenario: The orchestrator profile and prompt are installed

- **WHEN** `init` completes
- **THEN** `.specforge/launch-profiles/orchestrator.json` and `.specforge/launch-prompts/orchestrator.md` are present

### Requirement: The installer explains how to enable the always-on orchestrator

After writing files, `init` and `update` SHALL print the command to enable the
orchestrator service (`systemctl --user enable --now
specforge-orchestrator-<slug>`) and the `loginctl enable-linger <user>` hint
that makes it start at boot without a login, alongside the existing sync-unit
instruction. Enabling it SHALL remain the operator's explicit choice; the
installer only prints the lines.

#### Scenario: The enable lines are printed

- **WHEN** `init` finishes
- **THEN** its output contains the `systemctl --user enable --now specforge-orchestrator-<slug>` line and the `loginctl enable-linger` hint

### Requirement: doctor reports the orchestrator service without failing on its absence

`scripts/specforge doctor` SHALL report the orchestrator service state (not
installed, installed and disabled, enabled and inactive, or active), whether
user lingering is enabled, and whether a `FULL-ACCESS` orchestrator session is
currently running. The absence or inactivity of the service SHALL NOT make
`doctor` exit non-zero; only a service that is enabled while lingering is off
SHALL produce a NOTE naming the fix.

#### Scenario: A missing orchestrator service does not fail doctor

- **WHEN** `doctor` runs on a host where the orchestrator service was never enabled
- **THEN** it reports the service as not enabled
- **AND** it exits zero

#### Scenario: Enabled without linger is surfaced

- **WHEN** the orchestrator service is enabled but `loginctl` shows lingering off for the user
- **THEN** `doctor` prints a NOTE naming `loginctl enable-linger`
- **AND** it does not exit non-zero because of that NOTE
