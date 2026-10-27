## ADDED Requirements

### Requirement: The installer renders and explains the loop scheduler timer

`init` and `update` SHALL render `systemd/nogg-loops-<slug>.service` and
`systemd/nogg-loops-<slug>.timer` with the same per-repository slug and
absolute path as the other units. The service SHALL be `Type=oneshot` with
`WorkingDirectory` set to the repository and an `ExecStart` of
`<abs path>/scripts/nogg loop tick`. The timer SHALL fire every minute with
`Persistent=false` and SHALL be `WantedBy=timers.target`. The next-steps output
SHALL print the `systemctl --user enable --now` line for the timer, and enabling
it SHALL remain the operator's explicit choice. `remove` SHALL print the matching
disable line. `--no-systemd` SHALL skip both units, as it skips the others. The
`loop` launch prompt SHALL be delivered by the existing verbatim
`launch-prompts` copy. The loop modules SHALL be part of the payload, and the
scheduled-loops guide SHALL be among the installed reference docs. The
installer SHALL NOT write or overwrite `.nogging/loops.json` or `.nogging/loops/`.

#### Scenario: The loop units target the installing repository

- **WHEN** `init` runs in `/srv/project-a`
- **THEN** `systemd/nogg-loops-project-a.service` runs `/srv/project-a/scripts/nogg loop tick` from `/srv/project-a`, and `systemd/nogg-loops-project-a.timer` fires every minute without catch-up

#### Scenario: The enable line is printed

- **WHEN** `init` finishes without `--no-systemd`
- **THEN** its next steps contain `systemctl --user enable --now` for the loop timer

#### Scenario: --no-systemd skips the loop units

- **WHEN** `init --no-systemd` runs
- **THEN** no loop unit is rendered and the loop prompt, modules and guide are still installed

#### Scenario: Update preserves loop definitions

- **WHEN** `update` runs in a repository that has `.nogging/loops.json` and `.nogging/loops/night-work.md`
- **THEN** both files are byte-for-byte unchanged
