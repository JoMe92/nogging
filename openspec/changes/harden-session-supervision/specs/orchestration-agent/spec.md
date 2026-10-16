## MODIFIED Requirements

### Requirement: Exactly one Orchestration Agent runs at a time

`scripts/nogg orchestrator run` SHALL acquire `.nogging/locks/orchestrator.lock`
and SHALL refuse, naming the holder, while that lock is held. The orchestrator
lock is independent of the planning lock; a `plan` takeover holds both.

The lock, the singleton session name `nogg-orchestrator-<slug>`, the unit
name `nogg-orchestrator-<slug>.service` and the lookup of the live
orchestrator session SHALL be resolved from the repository's main checkout,
whichever checkout of the repository runs the command. The lock SHALL live in
the main checkout's `.nogging/locks/`, and `<slug>` SHALL derive from the main
checkout's directory name. `orchestrator run` invoked in a linked worktree
SHALL refuse before it takes the lock and SHALL name the main checkout. A
checkout-local `orchestrator.lock` in a linked worktree SHALL never be read
as the lock; `recover` and `doctor` SHALL report it as a note.

The lock SHALL record:

- the holder's process ID, host and creation time;
- the holder's process start time and PID namespace.

A single rule SHALL decide whether the lock is held or stale. `orchestrator
run`, `orchestrator status`, `recover` and `doctor` SHALL all apply it:

- **Verified holder.** The lock is held, and never stale whatever its age, when
  the caller is on the holder's host and in the holder's PID namespace, and
  the holder process is alive with the recorded start time.
- **Legacy lock.** A lock without a recorded start time is held by a verified
  holder when its process is alive and is a Nogging `orchestrator run`.
- **Dead holder.** On the same host and in the same namespace, the lock is
  stale when the holder process is gone, has another start time, or is
  another command. A stale lock is reclaimable without `--force`.
- **Unobservable holder.** When the caller cannot observe the holder's PID
  namespace, the holder is unverifiable and the lock SHALL NOT be reported
  stale. This includes a caller inside the OpenSpec execution sandbox.
- **Another host.** `orchestrator_lock_ttl_seconds` decides staleness only
  when the holder runs on another host.

`recover` SHALL count only a stale lock as needing attention.

#### Scenario: A second orchestrator is refused

- **WHEN** `orchestrator run` is invoked while `orchestrator.lock` is held by a live, verified holder
- **THEN** it exits non-zero and names the holding host and pid
- **AND** it starts no tmux session

#### Scenario: A day-old lock with a live holder is not stale

- **WHEN** the orchestrator lock is older than `orchestrator_lock_ttl_seconds`
- **AND** its holder process is alive with the recorded start time
- **THEN** `recover` and `doctor` report the lock as held, not stale
- **AND** `recover` does not exit non-zero because of it

#### Scenario: A sandboxed caller does not report the lock stale

- **WHEN** a Lead inside the OpenSpec execution sandbox runs `recover`
- **AND** the orchestrator lock's holder lives in the host PID namespace
- **THEN** `recover` reports the holder as unverifiable and not stale

#### Scenario: A dead holder's lock is reclaimable

- **WHEN** the recorded holder process is gone, or its start time differs from the lock
- **THEN** the lock is reported stale
- **AND** `orchestrator run` reclaims it without `--force`

#### Scenario: A worktree sees the main checkout's lock

- **WHEN** the Orchestration Agent holds the lock in the main checkout
- **AND** `recover`, `orchestrator status` or `doctor` runs in a linked worktree of the same repository
- **THEN** it reports the lock as held by that holder, never as free
- **AND** `orchestrator status` and `doctor` name the unit derived from the main checkout

#### Scenario: A worktree cannot start a second orchestrator

- **WHEN** `orchestrator run` is invoked in a linked worktree
- **THEN** it refuses before taking any lock, names the main checkout, and starts no tmux session
