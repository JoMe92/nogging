## Context

Three small, unrelated defects on the launch path. They touch different code
regions (`unmet_dependencies()` + one hook script; the `_session_launch()`
preflight/start sequence; the `OBSERVABILITY_HOOKS` constant), so each is its
own task on its own branch and the tasks run in parallel with no prerequisites.
`_session_launch()` is also being edited by other in-flight changes; each task
here keeps its edit local to the named function or constant.

## Goals / Non-Goals

**Goals:** a child of an open epic is launchable; a missing agent binary fails
launch loudly before side effects; Claude's Stop/Notification hooks survive a
changed working directory. One focused regression test per defect.

**Non-Goals:** reading readiness from `bd ready`; the Antigravity hook file;
changing which edge types Beads materialization creates; new config keys.

## Decisions

### 1. Test and execution discipline (every task)

- Each task adds its named focused suite and runs `scripts/test`. Fixtures stub
  `bd` (no real Dolt), clear inherited `NOGG_*`, `NOGGING_*`, `HERDR_*`, `TMUX`
  and `TMUX_TMPDIR`, use a scratch repository, no real sleeps for deadlines
  (inject a clock), no PID-range assumptions, no `unshare`, no existing tmux
  server. Source `scripts/lib/test-env.sh` like sibling suites.
- Leads read Decision 1, their own Decision, their task line and the matching
  spec slice. No execution claims occur during planning.

### 2. Blocking edges only (TASK-LHF-001, issue #184)

`bd dep list <id> --json` entries carry `dependency_type` (`blocks`,
`parent-child`, `tracks`, `related`, `discovered-from`, ...). An entry blocks a
launch only when its type is `blocks` or the field is absent (older bd output
and the existing stubs omit it) **and** its status is not `closed`. Apply the
identical rule in `unmet_dependencies()` (Python:
`r.get("dependency_type", "blocks") == "blocks"`) and in the hook (`jq`:
`select((.dependency_type // "blocks") == "blocks")`). `unmet_dependencies()`
also feeds the `doctor` retroactive-block note, which inherits the fix. An
allow-list of the one blocking type (rather than a deny-list of known
non-blocking types) keeps new non-blocking bd edge types from re-breaking
launch. The existing hook suite and `session.test.sh` fixtures that omit
`dependency_type` must stay green unchanged.

New suite `scripts/launch-blocking-edges.test.sh` drives both paths with the
same fixture: open epic parent (`parent-child`) alone launches; open `blocks`
blocker refuses naming only the blocker; closed `blocks` blocker launches; epic
parent plus open blocker names only the blocker; typeless entry still blocks.

### 3. Fail-fast agent launch (TASK-LHF-002, issue #195)

Two layers, both in `_session_launch()`:

1. **Preflight.** After the agent is resolved and before the first side effect
   (session record, log, usage reservation bind, backend start), check that the
   agent's executable (`claude`, `codex`, `agy`, `pi`, matching the wrapper's
   `exec`) resolves with `shutil.which` against the launcher's `PATH`. On a
   miss raise the usual refusal error: `agent binary '<name>' not found on
   PATH`, naming the agent, non-zero exit, nothing created. The existing
   `session-launch` wrapper continues to resolve the binary itself; this check
   only front-runs its failure.
2. **Settle check.** After a successful backend start and the `running`
   transition, wait a bounded settle window (2 s total, polled, injected
   clock/sleep in tests) and re-read backend liveness. If the session vanished
   or the record is already `failed`, mark/keep it `failed` with the redacted
   startup-log tail as the reason, release any usage reservation the same way
   other launch failures do, and raise `ToolError` so the command exits
   non-zero **without** the success summary, the kickoff hint, or the chained
   `--kickoff`. A session that survives the window proceeds exactly as before.

The settle window is a fixed 2 s constant, not a config key (no new surface).
The Lead may return early once liveness is confirmed, but a healthy launch must
never wait longer than the window.

New suite `scripts/session-launch-agent-binary.test.sh` covers: missing binary
refused before any record/log/tmux call (assert no side effects), the message
names the binary, a present binary launches normally, and a stub backend whose
session dies inside the window yields non-zero exit, log tail in the error, and
no kickoff hint even with `--kickoff`.

### 4. Absolute Stop/Notification hook path (TASK-LHF-003, issue #204)

`OBSERVABILITY_HOOKS` becomes a function (or is formatted at merge time) that
builds each command from the launcher's own checkout:
`<shlex.quote(str(ROOT / "scripts/nogg"))> session emit turn_end` (and
`needs_input`). The path is resolved when settings are written, so the hook is
independent of the session's current directory and of any `cd` the agent does,
and survives spaces in the path. `merge_observability_hooks()` keeps its
append-only, never-reorder contract and input-not-mutated behaviour. The
effective-settings JSON for a launched Claude session must contain no hook
command that begins with a relative `scripts/` path. The Antigravity hook
(`.agents/hooks.json`, validated near `expected_stop`) is a separate file and
untouched. Update the assertion at `scripts/session-observability.test.sh`
(`== "scripts/nogg session emit turn_end"`) to the new form in the same commit.

New suite `scripts/session-hook-absolute-path.test.sh`: generate settings via
the real merge for a root containing a space; assert Stop and Notification
commands are absolute and quoted; execute the Stop command via `sh -c` from a
subdirectory of a scratch repo with a stub session and assert `turn_end` is
appended to the session's events; assert no relative `scripts/` command remains
in the generated settings.

## Risks / Trade-offs

- The settle check can mis-fail a slow-starting but healthy agent only if its
  backend session is already gone, which is exactly the failure mode in #195.
- The absolute hook path ties a session's settings to the launching checkout;
  that is the same checkout whose state directory receives the events.
