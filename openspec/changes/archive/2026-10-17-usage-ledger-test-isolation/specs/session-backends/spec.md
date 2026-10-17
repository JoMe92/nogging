## MODIFIED Requirements

### Requirement: Usage reservations probe liveness through the record's backend

A usage-admission reservation SHALL store a backend-neutral liveness probe for
its session. A failing probe tool SHALL NOT be treated as proof that the
session ended. Reservations written before this capability SHALL still be
read. Readers SHALL execute probes only for understood reservation versions and
valid session shapes. Unsupported versions and malformed session metadata with
usable accounting SHALL remain conservatively reserved without executing their
probe or using session state as proof of death.

#### Scenario: A herdr reservation stays bound while its pane lives

- **WHEN** a herdr session holds a usage reservation and its pane is alive
- **THEN** the reservation is not released as stale

#### Scenario: A legacy tmux reservation is read

- **WHEN** a reader encounters an unversioned reservation using the old tmux and socket fields
- **THEN** it can verify liveness without requiring a backend-neutral probe field

#### Scenario: An unknown probe shape is retained

- **WHEN** a future or malformed session shape has usable reservation accounting
- **THEN** no probe executes and no shape exception escapes
- **AND** the reservation is retained and a compatibility diagnostic is reported
