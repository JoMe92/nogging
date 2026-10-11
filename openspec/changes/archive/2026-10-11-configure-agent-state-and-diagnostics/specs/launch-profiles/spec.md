## ADDED Requirements

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
