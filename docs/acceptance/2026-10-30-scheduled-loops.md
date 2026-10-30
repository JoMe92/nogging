# Scheduled loops — delivery host acceptance — 2026-10-30

Unsigned execution evidence for TASK-SCL-010 (`SPEC-0adz`), change
`scheduled-loops`, design Decisions 10 and 12. **Overall: the observed cases
passed, and acceptance is incomplete.** One required case was not run, the
migrated loop has not yet fired, and four findings below need a decision. This
report does not establish Product Owner acceptance.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-30, Europe/Berlin (CET, UTC+1) |
| Host | Linux aarch64 delivery host, this repository's main checkout |
| Operator | Nogging-supervised Claude Lead assigned `SPEC-0adz` (role `lead`, profile `trusted`), under Orchestrator direction, on the Product Owner's go |
| Toolkit version | Nogging 3.4.0 |
| Git commit tested | `3cfe5aef7fac7079c7f95ad1ebf5fd45a223e392` (`origin/develop`) |
| Implementation branch | `test/scheduled-loops` |
| Observation window | 14:36 to 15:12 CET |
| OpenSpec boundary | Locked throughout; no OpenSpec files were edited |

| Tool | Observed version |
| --- | --- |
| Nogging | 3.4.0 |
| Claude Code | 2.1.314 |
| Codex CLI | 0.164.0 |
| tmux | 3.5a |
| Python | 3.13.5 |
| Node.js | v22.23.2 |
| Git | 2.47.3 |

## Who did what

The task and Decision 12 assume the Lead runs `nogg loop add`. It cannot: the
Lead's add was refused with exit 1 and wrote nothing, and
`docs/scheduled-loops.md` reserves loop management for an operator or the
Orchestration Agent. The Lead staged the prompts and commands in an ignored
host-local directory and validated them with `loop_config` and `loop_schedule`
against a scratch copy, without touching the definitions file or the approval
ledger.

The Orchestration Agent added and approved the loops, linked the service,
enabled the timer at 14:36 CET, restarted it at 15:00:50 CET and removed the
temporary loops at 15:11 CET. The Lead read the run log, session records and
session logs. It never ran `systemctl`, so the enable and restart times are the
orchestrator's report; the tick times below are observed.

`systemd/` held no loop units when the run began, because `init` or `update` had
not run since they were added. A dry run of `update` showed changes well beyond
those units, so the Lead rendered only `nogg-loops-nogging.service` and `.timer`
with the installer's own `render()`, after reproducing the existing orchestrator
unit byte for byte. `update` on this host is still outstanding.

## Outcomes

| Case | Result | Evidence |
| --- | --- | --- |
| `loops_file` set to `.nogging/state/loops.json` on `develop` | pass | Read from `.nogging/config.json` |
| Migrated definition and prompt absent from `git status` | pass | Status clean; both paths git-ignored |
| Scheduled fire | pass | Send and launch runs started on their slots, below |
| Short-interval send inside a window | pass | `accept-send`, every 5m in 14:00-23:59 |
| Deferral while the orchestrator is busy | pass, natural | 14:40 to 15:00 CET; see finding 1 |
| Routine Codex launch completed and retired | pass | Three runs |
| Usage skip forced by `max_used_percent: 1` | pass | Three slots, no delivery |
| Timer restart | pass | Ticks continued after 15:00:50 CET |
| Orchestrator restart between two slots | **not run** | Not performed, by instruction |
| Temporary loops removed | pass | Only `orchestrator-issues` remains |
| `orchestrator-issues` fires on schedule | **not yet observed** | First slot is 17:07 CET, after this report |
| Orchestrator session cron deleted | **not established** | The orchestrator's step, not checked here |

## Observed runs

Times are CET. The run log stores UTC.

`accept-send` (every 5m, send to the orchestrator):

| Slot | Result |
| --- | --- |
| 14:40, 14:45, 14:50, 14:55 | Deferred on the slot, skipped 3 minutes later: `waiting_background` |
| 15:00 | Deferred, delivered 15:01:03 once the target went idle, completed 15:03:05 |
| 15:05 | Delivered 15:05:05, completed 15:07:04 |
| 15:10 | Delivered 15:10:05, no `completed` row: the loop was removed first |

The orchestrator's session log contains all three run headers, and the
orchestrator reports replying to each.

`accept-usage` (every 5m, send, `max_used_percent` 1, `on_unknown` deny):

| Slot | Result |
| --- | --- |
| 14:40, 14:45, 14:50, 14:55 | Skipped on target state; the usage gate was not reached |
| 15:00 | Skipped at 15:01:03: `usage-gate: short 20% (loop cap 1%)` |
| 15:05 | Skipped at 15:05:05: `usage-gate: short 20% (loop cap 1%)` |
| 15:10 | Skipped at 15:10:05: `usage-gate: short 21% (loop cap 1%)` |

The orchestrator's session log contains no `accept-usage` header.

`accept-launch` (every 10m, Codex, tier `routine`, `restricted`, `max_runtime`
15m):

| Slot | Result |
| --- | --- |
| 14:40 | Started on the slot, completed 14:42:05, retired |
| 14:50 | Started on the slot, completed 14:52:02, retired |
| 15:00 | Started on the slot, completed 15:02:05, retired |
| 15:10 | Started on the slot, then `failed` with `loop removed` at 15:11:05, retired |

The last row is the documented path for a loop removed during a run. No loop
session stayed open.

The timer ticked at 15:00:00, before the restart, and at 15:01:03, 15:02:05 and
15:03:05 after it, and it fired the 15:05 and 15:10 slots.

`orchestrator-issues` is enabled with `every: 5h`, `start: 02:07`, send to the
orchestrator, next slot 17:07 CET. It has no run yet.

## Findings

1. **A send loop gets no delivery while the target holds a background task.**
   The orchestrator ended every turn from 12:02Z to 14:00Z with
   `background_tasks: 2`, which classifies as `waiting_background`. Send mode
   requires exactly `idle`, so all four slots in that period were lost. The
   docs and spec name working, waiting for input, rate limited and absent
   targets, not this state, and the log carries the raw state instead of a
   `target-*` reason. A slot lost this way on `orchestrator-issues` means a
   5-hour gap. Delivery worked as soon as the tasks were gone.
2. **The target check runs before the usage gate.** A send loop that defers on
   target state never reports its usage decision. This matches the code and is
   harmless, but an operator reading the log cannot tell a usage skip was
   avoided.
3. **The launch prompt runs as its own turn before the kickoff.** In the first
   run, whose log was read in full, Codex reported that its loop prompt was
   missing and ran a read command before the kickoff arrived. That command
   failed on the Beads server with `operation not permitted`. The run then acted
   on the kickoff and ended correctly. The turn costs tokens and does work the
   loop prompt did not ask for. The same log shows the `restricted` Codex run
   executing that command without stopping, while the docs describe a restricted
   run stopping at its first Bash prompt.
4. **`doctor` misreports the timer from a fenced session.** While the timer was
   firing, `doctor` in this Lead printed that all loops `will not run` because
   the timer was `unavailable`. `systemctl` is denied here, so the check could
   not see it. The advisory should not imply the loops are stopped.

The refusal of `nogg loop add` for a Lead is correct behaviour. Decision 12 and
the task text are what need correcting.

## Not run

The orchestrator restart between two slots was not performed: the operator's
instruction forbade this Lead from stopping or restarting the orchestrator, and
the orchestrator marked the step as not run. The scheduler's handling of a
target restart is therefore untested on this host. The shared tmux server was
not stopped.

## Sign-off

Signed-off-by:
