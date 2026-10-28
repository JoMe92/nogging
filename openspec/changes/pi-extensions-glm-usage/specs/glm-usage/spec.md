## ADDED Requirements

### Requirement: The GLM usage key is resolved by Pi and never exposed

The `glm-usage` extension SHALL obtain the Z.ai key only through `ctx.modelRegistry.getApiKeyForProvider("zai")`, once per refresh, and SHALL NOT read Pi's `auth.json` or keep the key between refreshes. The key SHALL be sent only in the `Authorization: Bearer` header of a request to the constant URL `https://api.z.ai/api/monitor/usage/quota/limit`. No environment variable or setting SHALL change that URL. The key SHALL NOT appear in a footer status, notification, command output, error text, snapshot or log.

#### Scenario: Key from a secret-manager command

- **WHEN** Pi resolves the `zai` key from a `!command` entry or `ZAI_API_KEY`
- **THEN** the extension uses that key without reading `auth.json`

#### Scenario: Key never surfaces

- **WHEN** a refresh fails with an HTTP, network or parse error
- **THEN** no status, notification, command output or snapshot contains the key

### Requirement: The extension parses only the coding-plan token windows

A response SHALL be accepted only with `code` 200 and a `data.limits` array. A `TOKENS_LIMIT` with unit 3 SHALL be the `short` (5-hour) window, and a `TOKENS_LIMIT` with unit 6 the `weekly` window. All other entries SHALL be ignored. A window SHALL be valid only with a finite `percentage` in 0–100, read as percent used, and a finite epoch-millisecond `nextResetTime`. A response in which neither window is valid SHALL be the error `malformed`. `data.level` SHALL be kept as the plan level when it is a short string.

#### Scenario: Both windows present

- **WHEN** the response lists unit 3 at 37 percent and unit 6 at 21 percent, each with a future reset
- **THEN** short is 37 percent used and weekly is 21 percent used, with their reset times

#### Scenario: Tool limits are ignored

- **WHEN** the response also lists a `TIME_LIMIT` with unit 5
- **THEN** it affects neither window

#### Scenario: Unsupported shape

- **WHEN** the response has `code` 500, no `data.limits`, or only invalid windows
- **THEN** the refresh fails with a fixed reason and no window values change

### Requirement: The footer shows both windows as free percent and time to reset

The extension SHALL show its state with `ctx.ui.setStatus("nogging-glm-usage", text)`. With good values, the text SHALL be `GLM 5h <free>% free · reset <relative> | week <free>% free · reset <relative>`. Free is 100 minus used. The relative time SHALL be recomputed from the stored reset instant on each render. A window that the plan does not report SHALL be left out of the text.

#### Scenario: Normal display

- **WHEN** short is 37 percent used and resets in 2 hours 14 minutes, and weekly is 21 percent used and resets in 3 days 6 hours
- **THEN** the footer reads `GLM 5h 63% free · reset 2h 14m | week 79% free · reset 3d 6h`

### Requirement: Errors keep the last value and mark it stale

A failed refresh SHALL keep the last good values and append `· stale <age>`, where age is the time since the last good observation. A window whose reset instant has passed since that observation SHALL show `reset passed` instead of its old percentage. With no good value yet, the footer SHALL read `GLM usage unavailable (<reason>)`. The reason is one of `http-<status>`, `api-code-<code>`, `timeout`, `network` or `malformed`. No error SHALL escape a Pi event or command handler.

#### Scenario: Network error after a good value

- **WHEN** the last good refresh was 7 minutes ago and the current one times out
- **THEN** the footer still shows the last percentages followed by `· stale 7m`

#### Scenario: A reset passes while stale

- **WHEN** the short window's reset instant passes while refreshes keep failing
- **THEN** the short window shows `reset passed` and the weekly window keeps its stale values

### Requirement: A missing key makes no request

When no `zai` key resolves, the extension SHALL send no request and SHALL show `GLM usage: no Z.ai key`. It SHALL check again on the next tick, so a key added later through `/login` takes effect without restarting Pi.

#### Scenario: No key configured

- **WHEN** `getApiKeyForProvider("zai")` returns undefined
- **THEN** no request is made and the footer reads `GLM usage: no Z.ai key`

#### Scenario: Key added later

- **WHEN** a key resolves on a later tick
- **THEN** that tick fetches and the footer shows both windows

### Requirement: Polling is bounded and shared across sessions

Polling SHALL run only when `ctx.hasUI` is true. It SHALL refresh once at `session_start`, then every 180 seconds from an unref'd timer, which an idempotent `session_shutdown` clears. No timer or request SHALL start in the extension factory. Before fetching, the extension SHALL read the shared snapshot and SHALL use it without a request when the snapshot is younger than 120 seconds. Print and JSON runs SHALL make no request unless `/glm-usage` runs.

#### Scenario: Concurrent sessions share one request

- **WHEN** a second Pi session's tick finds a snapshot written 40 seconds earlier
- **THEN** it shows the snapshot values and sends no request

#### Scenario: Print mode is silent

- **WHEN** Pi runs with `--print` and the extension loaded
- **THEN** no quota request is sent and no timer is left running

### Requirement: /glm-usage reports the full state on demand

`/glm-usage` SHALL force a refresh at most once per 30 seconds; inside that interval it SHALL report the current state. It SHALL then notify a report with these items:

- the plan level
- each window's used percent, free percent, and absolute and relative reset time
- the time of the last good observation
- any stale or error reason
- the snapshot path and any snapshot write error

The report SHALL NOT include the key.

#### Scenario: Command after an error

- **WHEN** `/glm-usage` runs after the last refresh failed with `http-401`
- **THEN** the report names `http-401`, the last good values and their age

### Requirement: Successful refreshes write a key-free shared snapshot

After each successful fetch, the extension SHALL write `$XDG_CACHE_HOME/nogging/usage/pi-zai.json` (default `~/.cache/nogging/usage/pi-zai.json`). It SHALL create the directory with mode 0700 and write a temporary file with mode 0600, then rename it into place. The content SHALL be `schema_version` 1, `provider` `zai`, `source` `pi-extension`, `observed_at` as UTC ISO 8601, `plan_level`, and `windows` holding `short` and `weekly` objects with `used_percent` and `resets_at`, each present only when known. The snapshot SHALL contain no key, account identifier, request header or raw response. A write failure SHALL NOT stop the footer.

#### Scenario: Snapshot content and permissions

- **WHEN** a refresh succeeds
- **THEN** `pi-zai.json` exists with mode 0600 and the schema above
- **AND** contains no key

### Requirement: Loading the extension twice yields one instance

When `glm-usage` loads twice in one Pi process, for example through a personal install and a supervised `--extension`, only one activation SHALL register the command, set the footer and poll. That registration SHALL be released in `session_shutdown`, so a reload registers again.

#### Scenario: Personal install plus supervised flag

- **WHEN** a supervised session loads `glm-usage` both from personal settings and from `--extension`
- **THEN** there is one `nogging-glm-usage` footer entry, one timer and one working `/glm-usage`
