## ADDED Requirements

### Requirement: Antigravity web search follows the authority level and denials name their cause

The Antigravity guard SHALL accept `search_web` when its `query` argument is a
non-empty string without NUL, returning `allow` under `trusted` and
`force_ask` under `restricted`, the same split as `read_url_content`. Any
other `search_web` shape SHALL be denied. Every denial reason SHALL name its
cause and, for an unsupported tool, the tool name restricted to
`[A-Za-z0-9_.-]{1,64}` or shown as `<invalid>`. A reason SHALL NOT contain
argument values such as commands, paths, URLs or queries.

#### Scenario: Trusted web search

- **WHEN** a trusted Antigravity session calls `search_web` with a non-empty query
- **THEN** the guard allows it

#### Scenario: Restricted web search

- **WHEN** a restricted Antigravity session calls `search_web` with a non-empty query
- **THEN** the guard requires approval for it

#### Scenario: Malformed web search

- **WHEN** `search_web` arrives with an empty, non-string or missing `query`
- **THEN** the guard denies it with the reason `invalid search query`

#### Scenario: Unsupported tool

- **WHEN** the guard receives a tool outside its validated contracts
- **THEN** the denial reason names that tool

#### Scenario: Floor denial hides the command

- **WHEN** a shell command hits the command floor
- **THEN** the denial names the command floor and does not repeat the command
