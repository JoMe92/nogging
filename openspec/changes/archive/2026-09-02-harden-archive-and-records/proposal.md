# Harden the audit against archived changes and fix two record/floor gaps

## Why

Three defects surfaced while building and running the roadmap, all recorded as
discoveries:

- **`SPEC-fc4`** — `openspec archive <change>` moves a completed change to
  `openspec/changes/archive/YYYY-MM-DD-<name>/`. `scripts/specforge` `changes()`
  / `task_map()` skip `archive/`, but `beads()` reads closed Beads (since
  `reliable-beads-sync`). So every closed Bead still labelled
  `openspec:task:TASK-<c>-*` for an archived change makes `validate()` report
  "maps missing task" — the audit and `sync` break. Effect: **a completed
  change can never be archived while its closed Beads exist**, so all six done
  roadmap changes sit unarchived in `openspec/changes/`.
- **`SPEC-fgf`** — `selectable-launch-profile` writes
  `.specforge/state/sessions/<name>.settings.json` beside the record.
  `session_records()` globs `*.json`, loads the settings file as a bogus
  session record (it is valid JSON), so `session list` shows a spurious
  `unknown` row and the no-name `cleanup` server-kill guard is fooled.
- **`SPEC-bxq`** — `FLOOR_DENY` contains a fork-bomb pattern
  (`Bash(:(){ :|:& };:)`) that Claude Code's settings parser rejects
  ("Empty parentheses") and silently skips, so that one floor rule is inert.

## What Changes

- **The invariant audit tolerates archived changes.** `task_map()` gains an
  archived-inclusive mode that also reads `openspec/changes/archive/*/tasks.md`,
  normalising the `YYYY-MM-DD-` directory prefix back to the change name so the
  `openspec:change:` label still matches. `validate()` uses that mode; a closed
  Bead mapping to a task in an archived change resolves cleanly instead of
  failing. `materialize()` and `sync()` keep operating only on live changes.
- **`session_records()` ignores non-record files.** It excludes
  `*.settings.json` (and anything not matching the `<name>.json` record shape),
  so `session list`, `cleanup`, and the launch collision guard see only real
  records.
- **The launch floor contains only valid rules.** The fork-bomb entry is
  removed from `FLOOR_DENY` (it is not expressible as a Claude Code prefix
  rule); a test asserts every remaining entry is a syntactically valid
  permission rule. The other floor entries (`rm -rf`, `rm -fr`, `sudo`, `dd`,
  `mkfs`, `mkfs.*`, `shutdown`, `reboot`) are unchanged.
- **Docs**: `docs/failure-recovery.md` / `docs/operating-model.md` state that
  archiving a completed change is now supported.

## Capabilities

### New Capabilities

- `run-hygiene`: the mechanical layer tolerates archived changes in its audit,
  ignores auxiliary files when enumerating session records, and rejects an
  invalid launch-floor rule at test time.

### Modified Capabilities

<!-- none -->

## Impact

- New code: `scripts/specforge` (`task_map` archived mode + `validate` use of
  it; `session_records` filter; `FLOOR_DENY` edit).
- Modified: `scripts/specforge.test.sh` and `scripts/session.test.sh` (new
  fixtures), `docs/failure-recovery.md`, `docs/operating-model.md`.
- Behavioural change: `openspec archive` on a completed change no longer breaks
  `./scripts/specforge validate` / `sync`. `session list` no longer shows a
  spurious row while a session is live.
- Unblocks archiving the six completed roadmap changes (a follow-up housekeeping
  action, not part of this change).
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
