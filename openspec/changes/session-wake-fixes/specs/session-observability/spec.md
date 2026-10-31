## ADDED Requirements

### Requirement: A Codex usage limit is recognised from the rollout and the pane

The bounded Codex rollout reader SHALL expose the terminal error of the last turn: its kind (only when `codex_error_info` is a string), a message cut to 200 characters, and its timestamp. A Codex session whose last turn ended in `usage_limit_exceeded` SHALL classify as `limit`, from the rollout, until a new turn starts. A Codex pane that shows `You've hit your usage limit` (either apostrophe) SHALL classify as `limit` only while the idle composer is visible and no working marker is, so that a stale message never outranks a running turn. The reset time SHALL be read from the error message and resolved against the error's own timestamp in local time, and SHALL be absent when no time is readable. `session watch` SHALL report the `limit` with its `until` and a redacted excerpt. An unreadable or unfamiliar error SHALL never be read as a limit.

#### Scenario: Rollout limit is not idle

- **WHEN** a Codex rollout's last turn ends in `task_complete` with `error.codex_error_info` equal to `usage_limit_exceeded` and the message ends `try again at 12:51 PM`
- **THEN** the session classifies as `limit` with source `rollout`
- **AND** `until` is 12:51 local on the day of the error's timestamp, or the next day when that time had already passed

#### Scenario: A resumed turn is working

- **WHEN** a new `task_started` follows the limit error in the rollout
- **THEN** the session classifies as `working`, whatever the pane still shows

#### Scenario: Pane fallback needs the idle composer

- **WHEN** no rollout is found and the pane shows `You’ve hit your usage limit` above the idle composer
- **THEN** the session classifies as `limit`
- **AND** the same text beside a `Working (` marker classifies as `working`

#### Scenario: Other errors are not limits

- **WHEN** the last turn's `codex_error_info` is an object, an unknown string or absent
- **THEN** the session is not classified as `limit`

### Requirement: Pi lifecycle events survive a slow startup

The Pi lifecycle extension SHALL give each `session emit` call 20 seconds before it stops waiting, SHALL keep events in the order Pi fired them, and SHALL never block Pi on a slow call: a call that takes longer than a typical turn SHALL delay only later events. A call that has not finished at shutdown SHALL delay exit by at most the existing drain bound. The extension SHALL NOT retry a killed call, so no event is recorded twice.

#### Scenario: A slow nogg still records the event

- **WHEN** a fake `scripts/nogg` takes 4 seconds to append a `turn_end`
- **THEN** the event is in the events file, and Pi's handler returned before the call finished

#### Scenario: A stuck nogg delays nothing else

- **WHEN** a fake `scripts/nogg` never exits
- **THEN** the call is killed at its timeout, later events still append in order, and shutdown is delayed by no more than the drain bound
