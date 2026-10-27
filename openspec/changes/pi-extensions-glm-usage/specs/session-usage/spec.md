## ADDED Requirements

### Requirement: Pi quota comes from the Z.ai coding-plan observation

`nogg usage --agent pi` and launch admission for Pi SHALL report the Z.ai coding-plan windows as the Pi `short` and `weekly` buckets when the effective Pi provider is `zai`. The provider is taken from the launch model's `zai/` prefix, else the Pi profile `provider`, else `defaultProvider` in Pi's personal `settings.json`. For a known different provider, both windows SHALL be unknown with the reason `no usage source for Pi provider <name>`. The source SHALL be `$XDG_CACHE_HOME/nogging/usage/pi-zai.json` with schema 1 and provider `zai`. The source SHALL be used when its age is at most `usage_gate.stale_seconds`, under the same reset rules as other providers. The report `model_group` SHALL be `zai-coding-plan`, and the account SHALL stay unknown.

#### Scenario: Fresh snapshot

- **WHEN** the snapshot is 2 minutes old with short at 37 percent and weekly at 21 percent, both resetting in the future
- **THEN** `nogg usage --agent pi` reports both windows known, with projection and fit against the cap

#### Scenario: Weekly over the cap denies

- **WHEN** the Pi weekly window plus reservations and the estimate exceeds the cap
- **THEN** Pi launch admission is denied, naming the weekly reset, with exit 75

#### Scenario: Other provider

- **WHEN** Pi's effective provider is `anthropic`
- **THEN** both Pi windows are unknown, naming the provider, and the gate applies `on_unknown`

### Requirement: A stale Pi observation triggers one bounded probe that never exposes the key

When the Pi snapshot is stale, missing or malformed, and `PI_NOGG_USAGE_PROBE` is not `0`, Nogging SHALL run one probe. The probe obtains the key with `pi auth print-api-key --provider zai` under a 15 second timeout, with stdout captured in memory. It then requests the constant Z.ai quota URL with a 10 second timeout and parses the response under the same rules as the extension. On success, the probe SHALL write the snapshot atomically with mode 0600 and `source` `nogg-probe`, then report known windows. On failure, both windows SHALL be unknown with one of these reasons:

- `pi not installed`
- `no Z.ai API key configured in Pi`
- `Z.ai rejected the key (HTTP <status>)`
- `quota probe failed (<timeout|network>)`
- `unsupported quota response`

Unknown SHALL never be zero. The key SHALL NOT be written to disk, an argument vector, a child environment, a log, a session record, a report or an exception message. No setting or environment variable SHALL change the URL. `doctor` SHALL never probe. `scripts/test` SHALL export `PI_NOGG_USAGE_PROBE=0`.

#### Scenario: Probe refreshes a stale snapshot

- **WHEN** the snapshot is 20 minutes old and the stub `pi` and HTTP opener succeed
- **THEN** both windows are known from the probe and the snapshot is rewritten with `source` `nogg-probe`

#### Scenario: No key

- **WHEN** `pi auth print-api-key --provider zai` exits non-zero or prints nothing
- **THEN** both windows are unknown with `no Z.ai API key configured in Pi` and no request is made

#### Scenario: Key stays secret on failure

- **WHEN** the probe fails after obtaining the key
- **THEN** neither the report, the warning, the snapshot, the session record nor any raised error text contains the key

#### Scenario: Probe disabled

- **WHEN** `PI_NOGG_USAGE_PROBE=0` and the snapshot is stale
- **THEN** no `pi` command or request runs and both windows are unknown as a stale observation

## MODIFIED Requirements

### Requirement: Missing usage sources name their remediation

When a usage window is unknown because an opt-in source is absent, the report SHALL carry an advisory hint naming the remedy, without changing any admission decision. For Claude without the statusline capture, the hint SHALL be `run nogg usage install-statusline`. For Pi, the hint SHALL be one of three remedies:

- `configure the ZAI Coding Plan key in Pi (/login)` when no Z.ai key is configured
- `install pi` when `pi` is missing
- `run nogg usage --agent pi` when the snapshot is stale and the probe is disabled

Each hint SHALL be shown by `nogg usage`, the unknown-admitted launch warning and `doctor`.

#### Scenario: Claude statusline not installed

- **WHEN** `nogg usage --agent claude` runs with no statusline capture cache
- **THEN** each window is unknown (missing usage source) and the output names `nogg usage install-statusline`
- **AND** the gate decision is unchanged

#### Scenario: Hint reaches doctor

- **WHEN** `doctor` runs with no Claude capture cache
- **THEN** its quota NOTE names `nogg usage install-statusline`

#### Scenario: Pi without a Z.ai key

- **WHEN** `nogg usage --agent pi` runs and Pi has no `zai` key
- **THEN** each window is unknown and the output names `configure the ZAI Coding Plan key in Pi (/login)`
- **AND** the gate decision is unchanged
