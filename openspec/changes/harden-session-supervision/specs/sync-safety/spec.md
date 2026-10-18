## MODIFIED Requirements

### Requirement: Closing a Bead can tick its task line immediately

Nogging SHALL provide a command that ticks a single closed, mapped Bead's
`tasks.md` checkbox immediately, independent of the sync timer's schedule.
The command SHALL refuse when the named Bead is not closed. It SHALL use the
same tick logic the timer-driven sync uses, so the two paths never disagree
about what "ticked" means, and ticking the same line twice (once
synchronously, once later by the timer) SHALL be a no-op the second time.

The tick SHALL land in the checkout from which the command is invoked. This
also applies when the command runs inside the OpenSpec execution sandbox and
is relayed through the sandbox's host-side broker. The broker SHALL accept
the requesting checkout only when, at the time of the request, it is a
registered worktree of the same repository. Otherwise it SHALL refuse and
tick nothing. A refused or malformed request SHALL never fall back to another
checkout, such as the session's launch checkout.

The command SHALL send exactly one request, carrying the requesting
checkout, to the broker. When a broker that predates checkout-aware requests
rejects it, the command SHALL report that the session must be relaunched and
exit non-zero. It SHALL NOT send a second request without the checkout, and
it SHALL tick nothing.

#### Scenario: A closed Bead's task line ticks without waiting for the timer

- **WHEN** a Bead mapped to a live change's task is closed
- **AND** the immediate-tick command is run for that Bead
- **THEN** the matching `tasks.md` line shows `[x]` before the next scheduled
  sync tick runs

#### Scenario: An open Bead is refused

- **WHEN** the immediate-tick command is run for a Bead that is not closed
- **THEN** it refuses and ticks nothing

#### Scenario: A later sync tick does not double-write an already-ticked line

- **WHEN** a Bead's task line was already ticked by the immediate-tick command
- **AND** the timer-driven sync later processes the same closed Bead
- **THEN** the sync makes no further change to that line

#### Scenario: A sandboxed Lead ticks its implementation worktree

- **WHEN** a Lead launched from the shared checkout runs the immediate-tick command inside its sandbox from an implementation worktree created after launch
- **THEN** the task line is ticked in that implementation worktree
- **AND** the shared checkout's `tasks.md` is unchanged

#### Scenario: An unregistered checkout is refused

- **WHEN** the broker receives a tick request naming a path that is not a registered worktree of the repository
- **THEN** it refuses with a message naming the problem and ticks nothing in any checkout

#### Scenario: A pre-update broker leads to a relaunch, not a retry

- **WHEN** the immediate-tick command runs in a session whose broker predates checkout-aware requests
- **AND** that broker rejects the request because it carries the checkout
- **THEN** the command exits non-zero and says that the session must be relaunched
- **AND** it sends no second request and ticks nothing in any checkout
