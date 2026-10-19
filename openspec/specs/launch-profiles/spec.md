# launch-profiles Specification

## Purpose

Defines selectable session authority and prompts, their conservative defaults, command floors and recorded effective configuration.

## Requirements

### Requirement: A supervised session runs under a selectable authority profile

`scripts/specforge session launch` SHALL accept a `--profile` option and a
`--prompt` option, each taking either a name that resolves under a configured
profile / prompt directory or a filesystem path. When `--profile` is not given,
launch SHALL use the restricted profile; when `--prompt` is not given, launch
SHALL use the no-autonomous-claim prompt. Launch SHALL also accept a
`--full-access` option equivalent to selecting the `trusted` profile and the
`autonomous` prompt. If a selected profile or prompt cannot be resolved, launch
SHALL fail before creating any tmux session.

#### Scenario: Named profile is resolved

- **WHEN** `session launch … --profile trusted` runs and `trusted` exists in the profile directory
- **THEN** the session is started under that profile
- **AND** no tmux session is created if the name resolves to nothing

#### Scenario: Path profile is resolved

- **WHEN** `session launch … --profile ./my-profile.json` runs
- **THEN** the file at that path is used as the profile

#### Scenario: Default is unchanged

- **WHEN** `session launch` runs with neither `--profile` nor `--prompt`
- **THEN** the restricted profile and the no-autonomous-claim prompt are used
- **AND** the session behaves exactly as before this capability existed

#### Scenario: `--full-access` selects the trusted pair

- **WHEN** `session launch … --full-access` runs
- **THEN** the session uses the `trusted` profile and the `autonomous` prompt

### Requirement: The restricted profile is the default authority

The profile directory SHALL contain a `restricted` profile that denies pushing
to a remote, remote Dolt sync, destructive shell commands, privilege escalation,
and outbound network access, and this profile SHALL be the one used when
`--profile` is absent. Adding new profiles SHALL NOT change the default.

#### Scenario: Restricted denies push and network

- **WHEN** a session runs under the restricted profile
- **THEN** it cannot push to a git remote or run a remote Dolt sync
- **AND** it cannot make outbound network requests

### Requirement: A fixed command floor cannot be lifted by any profile

`session launch` SHALL merge a fixed set of denied commands — including
recursive force-delete, `sudo`, `dd`, filesystem-format commands, and host
power commands — into the effective permissions of every session, regardless of
which profile is selected or whether the profile was supplied by name or by
path. No profile SHALL be able to grant these commands.

The **single exception** is `--role orchestrator` launched under a profile
whose `specforge_floor` key is `false` (the shipped `orchestrator` profile).
For that role and that key only, `session launch` SHALL skip the floor merge,
and SHALL likewise skip the per-session `openspec/**` read-only rules when
`specforge_openspec_readonly` is `false`. Both keys SHALL be ignored — the
floor and the boundary applied as normal — for every other role, so a `lead`
or `specialist` session pointed at the `orchestrator` profile still runs
floored and `openspec/`-fenced. A session that actually ran with the floor
lifted SHALL be recorded and shown by `session list` as `FULL-ACCESS`.

#### Scenario: The floor survives a permissive supplied profile

- **WHEN** a session is launched with a supplied profile that denies none of the floor commands
- **THEN** the effective settings the session runs under still deny every floor command

#### Scenario: The floor applies to the trusted profile

- **WHEN** a session runs under the `trusted` profile
- **THEN** it still cannot run `sudo` or a recursive force-delete

#### Scenario: A non-orchestrator role cannot lift the floor via the orchestrator profile

- **WHEN** a `lead` session is launched with `--profile orchestrator`
- **THEN** its effective settings still deny every floor command
- **AND** they still deny `Edit`/`Write` under `openspec/**` outside a planning session

#### Scenario: The orchestrator role under the orchestrator profile runs floor-less

- **WHEN** a session is launched with `--role orchestrator` under the `orchestrator` profile (`specforge_floor: false`)
- **THEN** its effective settings deny none of the floor commands
- **AND** `session list` shows the session as `FULL-ACCESS`

### Requirement: The effective authority of a session is recorded and listed

`session launch` SHALL write the merged, floored settings for a session to a
per-session file and pass that file — not the source profile — to the launched
process, without modifying the source profile. The session metadata record
SHALL store the selected profile and the path to the effective settings.
`session list` SHALL show the profile each session runs under. `session cleanup`
SHALL remove the per-session effective-settings file when it retires the record.

#### Scenario: The profile is visible after launch

- **WHEN** a session has been launched under the `trusted` profile
- **AND** an operator runs `session list`
- **THEN** the listing shows that the session runs under `trusted`

#### Scenario: Source profiles are not mutated

- **WHEN** a session is launched under any profile
- **THEN** the source profile file is unchanged
- **AND** a separate effective-settings file for that session exists and is referenced by the metadata record

#### Scenario: Cleanup removes the effective settings

- **WHEN** a session record is retired by `session cleanup`
- **THEN** that session's effective-settings file is removed

### Requirement: The orchestrator profile grants unrestricted authority to the orchestrator role

The profile directory SHALL contain an `orchestrator` profile that runs in
`bypassPermissions` mode with an empty deny list and carries
`specforge_floor: false` and `specforge_openspec_readonly: false`. Combined
with `--role orchestrator` it grants the session full command access, outbound
network, and `openspec/` write access. Selecting it does not change the
default authority for any other launch. The profile SHALL be Claude-only in
this version.

#### Scenario: The orchestrator profile is the unrestricted level

- **WHEN** `session launch --role orchestrator --profile orchestrator` runs
- **THEN** the session can run any command, reach the network, and write under `openspec/`

#### Scenario: The default is unchanged

- **WHEN** `session launch` runs with neither `--profile` nor `--role orchestrator`
- **THEN** the restricted profile and the full command floor apply exactly as before this capability existed

### Requirement: The trusted profile does not block on a first-time Bash approval prompt

The `trusted` profile SHALL set `permissions.defaultMode` to `bypassPermissions`
and SHALL set a top-level `skipDangerousModePermissionPrompt` key to `true`, so
that a genuinely unattended `--full-access` session can run any command not
named in the profile's `deny` list — including one that would otherwise
require an interactive approval, a classifier review, or a one-time
bypass-permissions disclaimer dialog — without an operator present to answer
it.

#### Scenario: A fresh full-access session does not hang on its first qualifying Bash command

- **WHEN** a session is launched with `--full-access` (the `trusted` profile)
- **AND** it runs a Bash command not named in the profile's `deny` list
- **THEN** the command proceeds without an interactive prompt, a classifier
  review, or a disclaimer dialog blocking the session

#### Scenario: The trusted profile's deny list is unaffected

- **WHEN** a session runs under the `trusted` profile
- **THEN** it still cannot run any command the profile's `deny` list names,
  regardless of the `defaultMode` value

#### Scenario: A fresh full-access session does not block on the bypass-permissions disclaimer

- **WHEN** a session is launched with `--full-access` for the first time in a
  given session directory
- **THEN** no interactive "accept responsibility" disclaimer dialog blocks the
  session, because the profile's `skipDangerousModePermissionPrompt: true` key
  is already in effect

### Requirement: `doctor` flags a misconfigured or drifted bypass-permissions profile

For every Claude launch-profile JSON file under `.nogging/launch-profiles/`,
`scripts/nogg doctor` SHALL report a `NOTE` (never a failure) when the file
sets `permissions.defaultMode` to `bypassPermissions` without also setting a
top-level `skipDangerousModePermissionPrompt: true`, and SHALL report a
separate `NOTE` when a shipped profile's filename (`trusted.json`,
`orchestrator.json`) carries a `defaultMode` other than the value
`docs/security-model.md` documents for it.

#### Scenario: Missing disclaimer-skip key is flagged

- **WHEN** a launch-profile JSON sets `permissions.defaultMode:
  "bypassPermissions"` and omits `skipDangerousModePermissionPrompt`
- **AND** an operator runs `scripts/nogg doctor`
- **THEN** its output includes a `NOTE` naming that profile file and the
  missing key

#### Scenario: A correctly paired profile is silent

- **WHEN** a launch-profile JSON sets both `permissions.defaultMode:
  "bypassPermissions"` and `skipDangerousModePermissionPrompt: true`
- **THEN** `scripts/nogg doctor` reports no `NOTE` for that file under this
  check

#### Scenario: A drifted shipped profile is flagged

- **WHEN** an installed `trusted.json` or `orchestrator.json` has a
  `defaultMode` other than what `docs/security-model.md` documents for it
- **AND** an operator runs `scripts/nogg doctor`
- **THEN** its output includes a `NOTE` naming the file and the mismatch

### Requirement: Session model selection has explicit precedence and provenance

Session launch SHALL accept an optional --model override and optional agent-appropriate profile model; the override SHALL take precedence over the profile, followed by the native runtime default. Codex profiles SHALL optionally accept a supported model_reasoning_effort. Claude profiles SHALL optionally accept an effort setting with the Claude-specific selection and validation requirements below. Omitted keys SHALL preserve existing behavior. The session record and list SHALL show the requested model and selection source, or runtime-default when not specified, without modifying user-global settings.

#### Scenario: Override a profile model

- **WHEN** a valid profile model and a different --model are supplied
- **THEN** the override is passed to the runtime and recorded with source launch

#### Scenario: Legacy profile

- **WHEN** no model or reasoning setting is provided
- **THEN** native defaults remain effective and the listing honestly displays runtime-default

#### Scenario: Invalid reasoning setting

- **WHEN** an unsupported reasoning effort is configured
- **THEN** launch refuses before tmux or record creation

### Requirement: Agent runtime state roots are configured and granted only to related sessions

`.nogging/config.json` SHALL accept an optional `agent_state_roots` object mapping a normalized agent name to a list of absolute or `~/`-prefixed directory paths; an absent key SHALL mean no declared roots. Declaring a root SHALL NOT grant it. A supervised session SHALL receive an agent's declared roots only when its Bead carries the label `agent-state:<agent>` or the launch passes `--agent-state <agent>`. Every granted entry SHALL resolve to an existing directory strictly under the resolved `$HOME` (never `$HOME` itself); otherwise, and for a malformed key or unknown agent name, launch SHALL refuse before creating a tmux session or session record. A Codex session SHALL receive the granted roots as additional sandbox writable roots. The granted roots and their source SHALL be recorded in the session record and shown by `session list`. The `NOGG_CODEX_EXTRA_WRITABLE_ROOTS` environment variable SHALL NOT be read or forwarded; when it is set non-empty, launch SHALL refuse with a message naming `agent_state_roots` and the `agent-state:<agent>` label.

#### Scenario: Labelled Antigravity Bead in a Codex session

- **WHEN** `agent_state_roots` declares `antigravity: ["~/.gemini/antigravity-cli"]`, that directory exists, and a Codex session is launched for a Bead labelled `agent-state:antigravity`
- **THEN** the resolved directory is added to the Codex sandbox writable roots
- **AND** the session record and `session list` show it with source `label`

#### Scenario: Unrelated session is not widened

- **WHEN** the same root is declared and a Codex session is launched for a Bead without an `agent-state:` label and without `--agent-state`
- **THEN** the writable roots contain only the Git directories

#### Scenario: Invalid root refuses before start

- **WHEN** a requested relation resolves to `$HOME`, a path outside `$HOME`, a relative path, or a missing directory
- **THEN** launch exits non-zero naming the key and entry
- **AND** no tmux session or session record is created

#### Scenario: Retired environment variable

- **WHEN** `NOGG_CODEX_EXTRA_WRITABLE_ROOTS` is set non-empty at launch
- **THEN** launch refuses and names `agent_state_roots` and the `agent-state:<agent>` label as the replacement

### Requirement: A configured default launch profile and prompt are recorded under their own names

When `.nogging/config.json` pins `session_launch_profile` and `session_launch_prompt`, a new supervised session without explicit `--profile` / `--prompt` SHALL use them, and the session record and listing SHALL label the profile with the configured file's own name rather than `restricted`. Explicit `--profile` and `--prompt` SHALL still take precedence. The repository's documented autonomous Claude configuration SHALL keep the fixed command floor and the execution OpenSpec write boundary, and the documentation SHALL state that hosted Cloud settings cannot select bypass permissions or configure `autoMode` from the repository.

#### Scenario: Pinned trusted profile is labelled honestly

- **WHEN** the config pins `.nogging/launch-profiles/trusted.json` and a Lead session is launched without `--profile`
- **THEN** the session record shows profile `trusted`
- **AND** the effective settings still contain every command-floor deny rule and the `openspec/**` read-only rules

#### Scenario: Explicit restricted launch overrides the pinned default

- **WHEN** a session is launched with `--profile restricted --prompt no-autonomous-claim`
- **THEN** the restricted profile and that prompt are used and recorded

### Requirement: Claude effort has validated session-scoped precedence

Claude JSON launch profiles SHALL accept optional `effort`, and `scripts/nogg session launch` SHALL accept `--effort <level>` for the resolved Claude agent. For Claude the allowed values SHALL be exact strings `low`, `medium`, `high`, `xhigh`, and `max`. Launch SHALL validate both provided inputs, then select launch override over profile effort over native runtime behavior. A present invalid profile value SHALL refuse even when overridden. Omission SHALL emit no effort flag and preserve native behavior. `model_reasoning_effort` SHALL remain Codex-only; `effort` SHALL be rejected in non-Claude profiles, and `--effort` SHALL refuse for Pi and Antigravity launches (Codex is covered by the Codex effort requirement). Refusal SHALL occur before session/worktree creation, settings/record writes or tmux creation. Model selection SHALL remain independent.

#### Scenario: Launch override wins

- **WHEN** a Claude profile specifies `effort: high` and launch specifies `--effort low`
- **THEN** the requested effort is low with source launch
- **AND** the source profile remains unchanged

#### Scenario: Profile or native behavior

- **WHEN** Claude launches without an effort override
- **THEN** a valid profile effort is selected with source profile
- **AND** if the profile omits effort, no effort flag is emitted and the source is runtime-default

#### Scenario: Invalid values fail before side effects

- **WHEN** an effort input is null, non-string, empty, whitespace-bearing, case-mismatched or outside the allowed values, including an invalid profile with a valid override
- **THEN** launch refuses with a diagnostic identifying the offending input
- **AND** no session worktree, effective settings, session record or tmux session is created

#### Scenario: Cross-agent inputs refuse

- **WHEN** --effort targets Pi or Antigravity, a non-Claude profile contains effort, or a Claude profile contains model_reasoning_effort
- **THEN** launch refuses before session creation rather than dropping or translating the setting
- **AND** valid existing Codex model_reasoning_effort behavior remains unchanged

### Requirement: Claude effort reaches the native process without changing authority or persistent configuration

A selected Claude effort SHALL reach the Claude process as separate `--effort` and level argv elements on cold launches and exact-conversation resumes. Nogging SHALL NOT write effort to user-global config, change the source profile, or change authority, fencing, prompt, model or conversation selection because effort was supplied. The Nogging profile key SHALL NOT leak into generated Claude settings. A stale helper unable to guarantee Claude effort forwarding SHALL cause preflight refusal with an update remedy before creating a session. Runtime rejection SHALL retain the existing failed-start diagnostics without silently retrying at another effort.

#### Scenario: Native argv on launch and resume

- **WHEN** Claude launches cold or resumes an exact conversation with effort xhigh
- **THEN** its native argv contains exactly one --effort option followed by xhigh
- **AND** all unrelated launch arguments and permission boundaries are preserved

#### Scenario: Legacy helper cannot drop effort

- **WHEN** effort is requested and the installed helper lacks the Claude effort-forwarding capability
- **THEN** launch refuses before session creation and instructs the operator to update Nogging

#### Scenario: Global and profile state is preserved

- **WHEN** launches select each supported Claude effort including max
- **THEN** source profiles and existing user-global configuration remain byte-for-byte unchanged by Nogging
- **AND** the generated settings contain no Nogging effort key

#### Scenario: Native rejection stays visible

- **WHEN** the Claude runtime rejects an effort or model combination
- **THEN** the session follows the existing failed-start lifecycle with scrubbed diagnostics
- **AND** Nogging does not retry with the effort omitted or changed

### Requirement: Requested reasoning effort and provenance are durable and visible

New Claude and Codex session records SHALL contain `reasoning_effort` and `reasoning_effort_source`. Source SHALL be `launch`, `profile`, or `runtime-default`; absent effort SHALL be null with source runtime-default. Codex profile effort SHALL use source profile. Session list SHALL show the requested level and source, or effort=runtime-default when unspecified in new Claude/Codex records. Existing model fields SHALL remain intact. Old records without effort-source SHALL remain readable: present effort SHALL show unknown provenance, and absent effort SHALL retain the prior display. Other agents' display SHALL remain unchanged. These fields SHALL describe the launch request, not imply observation of later interactive changes or runtime-resolved defaults.

#### Scenario: Profile and override provenance

- **WHEN** new Claude sessions select effort from the profile and launch override respectively
- **THEN** records store the selected values with sources profile and launch respectively
- **AND** session list displays those values and sources

#### Scenario: Codex and unspecified effort

- **WHEN** a new Codex session has profile model_reasoning_effort high or a new Claude/Codex session has no effort input
- **THEN** the former stores high with source profile and the latter stores null with source runtime-default
- **AND** listings show the same requested-setting distinction without inventing a runtime value

#### Scenario: Historical records remain readable

- **WHEN** session list reads records predating reasoning_effort_source
- **THEN** a stored effort displays unknown provenance and an absent effort retains the prior display
- **AND** the list succeeds without rewriting those records

### Requirement: Codex effort can be set at launch

`scripts/nogg session launch --agent codex` SHALL accept `--effort <level>`. The level SHALL be validated against the supported Codex reasoning-effort set (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`) before any side effect. A valid level SHALL reach Codex through the existing `--reasoning-effort` transport as separate argv elements, with no new public Codex flag. Codex effort precedence SHALL be launch `--effort` over `--tier` table effort over profile `model_reasoning_effort` over the runtime default. An explicit effort SHALL be recorded as `reasoning_effort` with source `launch`, shown by `session list` as `effort=<level> (launch)`. An invalid `--effort` SHALL refuse even when a tier or profile would supply a valid value. Refusal SHALL occur before session/worktree creation, settings/record writes or tmux creation. Without `--effort`, Codex behaviour SHALL be unchanged. Whether a given model supports a level SHALL remain the runtime's decision, and a runtime rejection SHALL follow the existing failed-start lifecycle without a retry at another effort.

#### Scenario: Effort overrides the tier effort

- **WHEN** a Codex session launches with `--tier complex --effort low`
- **THEN** Codex receives `--reasoning-effort low` and the tier's model
- **AND** the record stores reasoning_effort low with source launch

#### Scenario: Effort overrides the profile effort

- **WHEN** a Codex profile sets `model_reasoning_effort = "xhigh"` and launch passes `--effort low`
- **THEN** Codex receives `--reasoning-effort low` and the source profile is unchanged

#### Scenario: Effort without a tier

- **WHEN** a Codex session launches with `--effort medium` and no tier or profile effort
- **THEN** Codex receives `--reasoning-effort medium` with source launch

#### Scenario: Unsupported level is refused

- **WHEN** a Codex launch passes `--effort turbo`, `--effort LOW` or an empty value
- **THEN** launch refuses naming the input and the allowed values
- **AND** no worktree, settings, record or tmux session is created

#### Scenario: Pi and Antigravity still refuse

- **WHEN** `--effort` targets Pi, Antigravity or the `agy` alias
- **THEN** launch refuses naming Claude and Codex as the only supported agents
