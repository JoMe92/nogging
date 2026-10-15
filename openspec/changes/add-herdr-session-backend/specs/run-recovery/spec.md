## MODIFIED Requirements

### Requirement: Crashed session records can be reaped

`scripts/nogg` SHALL provide a way to move every session record in an active
state whose backend session no longer exists to a terminal `failed` state, so
that `session cleanup` can retire it. Each record's liveness SHALL be judged by
that record's own session backend.

A live session record SHALL NOT be affected. A record whose backend's liveness
cannot be determined SHALL NOT be affected, and the reap SHALL report it in a
note.

#### Scenario: A vanished session is reaped and cleaned up

- **WHEN** a session record is `running` but its backend session is gone
- **AND** the reap operation runs
- **THEN** the record's state becomes `failed`
- **AND** a subsequent `session cleanup` retires it

#### Scenario: A live session is left alone

- **WHEN** a session record is `running` and its backend session exists
- **AND** the reap operation runs
- **THEN** the record is unchanged

#### Scenario: Unknown liveness is left alone

- **WHEN** a herdr session record is `running` and the herdr CLI fails unexpectedly
- **AND** the reap operation runs
- **THEN** the record is unchanged and a note reports the unknown liveness
