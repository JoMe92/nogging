## ADDED Requirements

### Requirement: Every focus runtime reports its lifecycle in one normalized form

Claude Code, Codex and Pi sessions SHALL report through one normalized event
schema with the events `turn_start`, `turn_end`, `needs_input`, `turn_error`,
`session_end`, `blocked` and `done`. `session emit` SHALL read at most 64 KiB of
hook JSON from stdin when present, SHALL tolerate invalid input, and SHALL keep only
a whitelist of fields: `source`, `error`, `notification_type`, the count of
`background_tasks`, and an excerpt of the last agent message. An excerpt SHALL be at
most 300 characters, single-line, with control characters removed, and redacted of
secrets and email addresses. The per-session events file SHALL be rotated at 256 KiB.

A `Notification` SHALL map to `needs_input` only for a question type:
`permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` or
`agent_needs_input`. `turn_error` with `rate_limit` SHALL classify as `limit`. A
`turn_end` with background tasks in flight SHALL classify as `waiting_background`.
Antigravity's existing Stop event path SHALL be unchanged.

#### Scenario: An idle notification is not a question

- **WHEN** Claude sends a `Notification` of type `idle_prompt`
- **THEN** no `needs_input` event is recorded

#### Scenario: A paused session is not finished

- **WHEN** Claude's `Stop` input lists a running background task
- **THEN** the session classifies `waiting_background`

#### Scenario: Hook input cannot leak through the event file

- **WHEN** a hook payload contains a secret in the last message and unknown fields
- **THEN** the recorded event holds a redacted excerpt and none of the unknown fields

#### Scenario: A malformed payload still records the event

- **WHEN** stdin holds invalid JSON
- **THEN** the event is recorded without optional fields and the command exits 0

### Requirement: A supervised Pi session reports its lifecycle

A supervised Pi session SHALL load `.pi/extensions/nogging-lifecycle.ts`, exactly once
per session, which does nothing unless `NOGG_SESSION_NAME` is set. It SHALL emit
`turn_start` on `agent_start`, `turn_end` on `agent_settled` and never on `agent_end`,
`needs_input` on `ui_prompt_start`, clear it on `ui_prompt_end`, emit `turn_error` when
`agent_before_settle` reports `outcome: "error"`, and emit `session_end` on
`session_shutdown`. Handler errors SHALL NOT affect the session, and its child
processes SHALL be bounded by a timeout and shall not delay Pi's exit.

#### Scenario: A retried run is not reported finished

- **WHEN** Pi fires `agent_end` and then starts an automatic retry
- **THEN** no `turn_end` is emitted until `agent_settled`

#### Scenario: Pi is classified in watch

- **WHEN** `session watch` runs for a supervised Pi session on tmux whose last event is `turn_end`
- **THEN** it reports `idle`, not `unknown`

#### Scenario: Outside a supervised session it does nothing

- **WHEN** Pi loads the extension with `NOGG_SESSION_NAME` unset
- **THEN** it registers no behaviour and emits nothing

### Requirement: Codex turns are observed from the rollout without an install

For a Codex session, a turn's start and end SHALL be read from the session's own
rollout through a bounded reader, resolved by the session's exact thread identity and
never by a guess. `task_complete` SHALL yield `turn_end` with an excerpt of
`last_agent_message`, and a terminal abort SHALL yield `turn_end` with the reason. An
unrecognized or unreadable record SHALL leave the state to the next evidence source.

#### Scenario: A finished Codex turn needs no hook

- **WHEN** a supervised Codex session has no user-level hook and its rollout ends with `task_complete`
- **THEN** it classifies `idle` and exposes the excerpt

#### Scenario: An unknown rollout is not read as finished

- **WHEN** the rollout has only unrecognized records
- **THEN** classification falls through to herdr or the pane adapter

### Requirement: The Codex stop hook is an explicit, user-level install

`nogg session-hooks install --agent codex` SHALL merge one `Stop` entry into the
user-level `~/.codex/hooks.json`, preserving every other entry, and SHALL record its
trust through Codex's own configuration API, printing what it trusted. The hook's
command SHALL be constant across repositories and SHALL do nothing outside a
supervised session. `remove` SHALL reverse both. `status` SHALL report `trusted`,
`untrusted`, `modified` or `missing` from Codex's own `hooks/list`. `init` and `update`
SHALL NOT perform this install. `session-launch` SHALL NOT pass
`--dangerously-bypass-hook-trust`, because Codex runs a local hook outside its sandbox
and a sandboxed session can write its own project `.codex/hooks.json`.

#### Scenario: A foreign hook survives the install

- **WHEN** `~/.codex/hooks.json` holds another tool's `SessionStart` entry
- **THEN** the install leaves it byte-equivalent and adds only the Nogging `Stop` entry

#### Scenario: The hook is inert outside Nogging

- **WHEN** a bare Codex session ends a turn with the hook installed
- **THEN** the hook exits 0 and records nothing

#### Scenario: A modified hook is reported

- **WHEN** the hook definition no longer matches its trusted hash
- **THEN** `status` and `doctor` report `modified` and name the fix, and neither fails

#### Scenario: A launch never bypasses trust

- **WHEN** any Codex session launches
- **THEN** its argv does not contain `--dangerously-bypass-hook-trust`

### Requirement: A Lead ends its work with an explicit signal

`nogg session signal blocked|done "<reason>"` SHALL append the matching event for the
calling supervised session. It SHALL need neither network nor Dolt, SHALL refuse
outside a supervised session, and SHALL limit the reason to 300 characters with the
excerpt rules. It SHALL print whether dispatch is on and what the Lead should do next.
A signal SHALL NOT change the classified state, so callers that test for `idle` keep
working, and `session watch` SHALL report it as its own event. The restricted launch
profile SHALL allow the command.

#### Scenario: A sandboxed Lead can signal

- **WHEN** a restricted Codex Lead with no Dolt access runs `session signal blocked "..."`
- **THEN** the event is recorded and the command exits 0

#### Scenario: A signal does not break delivery

- **WHEN** a Lead that signalled `done` is idle
- **THEN** it classifies `idle` and `session send` still works

### Requirement: A bounded stop guard keeps a Lead from ending with work left

`nogg session completion-check [--json]` SHALL report the gaps `dirty`, `unpushed` and
`no-signal` from local git facts and the session's events, and SHALL exit 0 on an
internal error. For a `lead` session under the `autonomous` prompt, on Claude Code,
Codex and Pi, a stop with gaps SHALL be turned into one continuation with a fixed
message: `decision: "block"` on Claude's and Codex's `Stop` hook, and `continue: true`
with a `custom_message` on Pi's `agent_before_settle`. The guard SHALL pass when
`stop_hook_active` is true, and on Pi after one continuation per user input. It SHALL
NOT apply when a `blocked` or `done` signal is newer than the last `turn_start`, when
background tasks are in flight, or after an API error. A continued stop SHALL be
recorded as `guard_continue`, not `turn_end`. Any guard failure SHALL allow the stop.

#### Scenario: Uncommitted work gets one continuation

- **WHEN** an autonomous Lead ends its turn with a dirty tree
- **THEN** it continues once with the fixed message naming the gap

#### Scenario: The guard cannot loop

- **WHEN** the Lead stops again with `stop_hook_active` true
- **THEN** the stop is allowed

#### Scenario: A blocked Lead may stop

- **WHEN** a Lead signals `blocked` and then ends its turn with a dirty tree
- **THEN** the stop is allowed

#### Scenario: A broken check never traps a session

- **WHEN** `completion-check` raises or times out
- **THEN** the stop is allowed

### Requirement: Runtime capabilities are explicit

`nogg session capabilities [--agent <agent>] [--profile <profile>] [--json]` SHALL
report, from what launch resolves and not from a separate hand-kept list, whether a
session of that agent and authority can launch child sessions, reach Dolt, push, open
a pull request, rebase without an operator, and run in-process specialists. An answer
that cannot be established SHALL read `unknown`. A `session launch` from a caller that
cannot write the required state SHALL refuse before side effects with a message that
names the reason and tells the caller to signal blocked, instead of surfacing a raw
filesystem error. No authority SHALL be widened.

#### Scenario: A sandboxed launch fails clearly

- **WHEN** a sandboxed Codex Lead runs `session launch` and the usage reservation path is read-only
- **THEN** it refuses with the named reason and creates no session, record or log

#### Scenario: A kickoff can be checked first

- **WHEN** the orchestrator runs `session capabilities --agent codex --profile trusted --json`
- **THEN** the output states whether that Lead can launch a reviewer session

## MODIFIED Requirements

### Requirement: Watch classifies a session's live state via a per-agent adapter

`scripts/nogg session watch` SHALL classify each named or running session's
current state from one evidence order for every agent: a fresh structured event,
then a Codex rollout turn state, then herdr `agent_status`, then the pane adapter
keyed off that session's recorded `agent` field, never a single global keyword
match. Pane classification SHALL strip lines matching the adapter's `ignore`
patterns before checking state, and SHALL consider only the pane's last
approximately 15 lines, not its full scrollback. The classified state SHALL be one
of `working`, `waiting_background`, `idle`, `needs_input`, `limit`, `stalled`,
`ended`, or `unknown`. No source SHALL infer completion from missing evidence.

#### Scenario: A benign status banner does not cause a false positive

- **WHEN** a Claude session's pane shows only the `Auto-update failed: no
  write permission to npm prefix` notice while background shells are running
- **AND** `watch` classifies that session
- **THEN** the classified state is `waiting_background`
- **AND** it is never `unknown` or treated as requiring attention

#### Scenario: A gone session is reported as ended

- **WHEN** a named session's tmux session no longer exists
- **AND** `watch` is asked about it
- **THEN** it reports `ended`

#### Scenario: Missing evidence stays unknown

- **WHEN** a Pi session has no event file, no herdr status and no adapter
- **THEN** `watch` reports `unknown`, not `idle`

#### Scenario: A later turn is not reported idle

- **WHEN** a Claude session's last recorded event is `turn_end` and it has started a new turn
- **THEN** a `turn_start` event classifies it `working`

#### Scenario: A lost turn-start hook does not pin idle

- **WHEN** a session's last event is `turn_end` and its pane adapter reports `working`
- **THEN** `watch` reports `working`

### Requirement: Claude's Layer-2 hooks run from any working directory

The effective settings written for a launched Claude session SHALL register the
`UserPromptSubmit` (`turn_start`), `Stop` (`turn_end`), `Notification` (`needs_input`),
`StopFailure` (`turn_error`) and `SessionEnd` (`session_end`) hooks with an absolute,
shell-quoted path to the launching checkout's `scripts/nogg`, resolved when the
settings are written. No generated hook
command SHALL depend on the session's current working directory, so a `cd` into a
subdirectory does not lose events. `SubagentStop` SHALL NOT be wired.

#### Scenario: Generated hook commands are absolute

- **WHEN** `session launch --agent claude` writes the effective settings
- **THEN** every generated hook command begins with an absolute quoted `scripts/nogg` path
- **AND** no generated hook command begins with a relative `scripts/` path

#### Scenario: A hook fires after the agent changes directory

- **WHEN** the `Stop` hook command runs with a subdirectory of the checkout as its working directory
- **THEN** it resolves `scripts/nogg` and records the `turn_end` event for the session

#### Scenario: A path with spaces is quoted

- **WHEN** the launching checkout path contains a space
- **THEN** the generated hook commands remain valid shell and resolve correctly
