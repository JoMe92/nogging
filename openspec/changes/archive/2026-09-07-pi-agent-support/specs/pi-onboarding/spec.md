## ADDED Requirements

### Requirement: A project-local extension enforces the command floor and the write boundary

Because Pi ships no native sandbox or execution-policy mechanism, the
installer SHALL place `.pi/extensions/specforge-guard.ts`, a project-local
extension that intercepts the `tool_call` event to: deny a shell command
matching the SpecForge command-floor patterns (`sudo`, `rm -rf`/`rm -fr`,
`dd`, `mkfs` and variants, `shutdown`, `reboot`, `systemctl`, `chown`,
`curl`, `wget`, `git push --force*`, `git reset --hard`, `git clean -fdx`,
`git filter-branch`); and deny a file write or edit under `openspec/` unless
`.specforge/locks/openspec.readonly` reports the write boundary open. Neither
`session launch --agent pi` at any authority level, nor any launch profile,
SHALL pass a flag or setting that prevents this extension from loading.

#### Scenario: A floor command is blocked

- **WHEN** a Pi session (trusted for this project) attempts a shell command matching a command-floor pattern
- **THEN** the guard extension blocks the call and reports why

#### Scenario: An openspec/ write is blocked outside a planning session

- **WHEN** a Pi session attempts to write or edit a file under `openspec/` while the write boundary is closed
- **THEN** the guard extension blocks the call

#### Scenario: An openspec/ write succeeds during planning

- **WHEN** the write boundary is open (a planning session is active)
- **AND** a Pi session writes under `openspec/`
- **THEN** the guard extension allows the call

### Requirement: Pi's restricted level carries no sandbox, and this is stated plainly

Because Pi runs built-in tools with the full permissions of its own process
and provides no path or network restriction, `docs/using-with-pi.md`,
`AGENTS.md` *Tool notes*, and `scripts/specforge doctor` SHALL each state that
Pi's `restricted` authority level enforces the command floor and the
`openspec/` write boundary only, with no network or filesystem isolation —
distinct from, and weaker than, the `restricted` level for `claude` and
`codex`.

#### Scenario: The limitation is written down

- **WHEN** `docs/using-with-pi.md` is read
- **THEN** it states that Pi's `restricted` level has no network or filesystem sandbox

### Requirement: A non-interactive Pi launch grants project trust per run, never standing

`session launch --agent pi` SHALL pass `--approve` for the launched process
so `.pi/extensions/specforge-guard.ts` loads for that session, and SHALL NOT
set `defaultProjectTrust: always` in any shipped or generated configuration.

#### Scenario: A launched session's extension loads without a standing trust grant

- **WHEN** `session launch --agent pi` runs on a project with no prior trust decision recorded
- **THEN** the launched process is given `--approve` for that run
- **AND** no global setting trusts future projects automatically

### Requirement: doctor reports Pi availability and extension trust

`scripts/specforge doctor` SHALL report whether `pi` is on `PATH`, and the
absence of `pi` alone SHALL NOT make `doctor` exit non-zero. When `pi` is on
`PATH` and the repository has `.pi/extensions/specforge-guard.ts` but the
project is not yet trusted for it, `doctor` SHALL print an informational
line naming the fix (`--approve` or the `/trust` command), without treating
it as a failure.

#### Scenario: Pi absent does not fail doctor

- **WHEN** `doctor` runs on a host without `pi` installed
- **THEN** it reports `pi` as not installed
- **AND** it exits zero

#### Scenario: An untrusted guard extension is surfaced

- **WHEN** `pi` is on `PATH`, `.pi/extensions/specforge-guard.ts` exists, and the project has no trust decision recorded
- **AND** `doctor` runs
- **THEN** it prints a NOTE naming the fix
- **AND** it does not exit non-zero because of that NOTE

### Requirement: The Pi delegation path is written down

`AGENTS.md` *Tool notes* SHALL carry a **Pi** subsection stating: the write
boundary is the guard extension (not a hook, not an execution-policy file);
a Pi specialist run is a separate supervised
`session launch --agent pi --role specialist:<type> --bead <id>` session,
since Pi has no in-process subagent mechanism; and the operator entry points
are `.pi/prompts/{plan,discovery-review,sync-now}.md`.

#### Scenario: The Pi delegation path is written down

- **WHEN** `AGENTS.md` *Tool notes* is read
- **THEN** it names `session launch --agent pi --role specialist:<type>` as the Pi specialist mechanism
- **AND** it states the specialist boundary rules still apply
