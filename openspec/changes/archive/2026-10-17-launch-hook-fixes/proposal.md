## Why

Sources: GitHub issues [#184](https://github.com/JoMe92/nogging/issues/184),
[#195](https://github.com/JoMe92/nogging/issues/195) and
[#204](https://github.com/JoMe92/nogging/issues/204). Three independent
launch-path defects surfaced by the delivery fleet:

- **#184** The Lead launch guard (`scripts/hooks/pre-tool-use-lead-launch-guard`)
  and `unmet_dependencies()` in `scripts/nogg` treat every `bd dep list` entry
  as a blocker, including the `parent-child` link to an open epic. A task under
  an open epic can never get a Lead session, although `bd ready` lists it.
- **#195** `session launch` prints a success summary and exits 0 when the agent
  binary cannot be executed (exit 127 inside tmux). The failure only shows up
  later as a confusing `send` error.
- **#204** The per-session Claude settings register the Stop and Notification
  hooks as the relative `scripts/nogg session emit ...`. After the agent `cd`s
  into a subdirectory every hook fails with `scripts/nogg: not found` and the
  `turn_end` / `needs_input` events are silently lost.

## What Changes

- Only blocking dependency edges (type `blocks`, or no type recorded) count as
  unmet dependencies in both the hook and `unmet_dependencies()`; `parent-child`
  and every other non-blocking edge type are ignored.
- `session launch` checks that the agent binary resolves before any side effect
  (record, log, usage reservation, tmux session) and refuses with a clear
  message; after start it also confirms the session survived a short bounded
  settle window and otherwise fails non-zero with the startup-log tail, without
  printing the kickoff hint or chaining `--kickoff`.
- The generated Claude `Stop` and `Notification` hook commands use an absolute,
  shell-quoted path resolved at launch time, so they work from any working
  directory.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-sessions`: blocking-edge-only dependency check (launch and hook);
  fail-fast on a missing agent binary and on immediate startup death.
- `session-observability`: the Layer-2 Claude hooks are cwd-independent.

## Impact

- `scripts/nogg`: `unmet_dependencies()`, `_session_launch()` preflight and
  settle check, `OBSERVABILITY_HOOKS` / `merge_observability_hooks()`.
- `scripts/hooks/pre-tool-use-lead-launch-guard` (+ its existing test).
- `scripts/session-observability.test.sh` assertion of the relative hook
  command is updated to the intended absolute form.
- Three new focused suites, one per task. No new dependency, no authority or
  profile change, no new config key.

Out of scope: the Antigravity hook (`python3 ../scripts/nogg ...`, a different
generated file), reading readiness from `bd ready --json` instead of the edge
filter, and any change to how Beads are materialized or parented.
