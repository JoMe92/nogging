# Troubleshooting

Common failures in symptom → cause → fix form. Every fix links the deep
procedure in [Failure recovery](failure-recovery.md) and the exact command in
the [Command reference](commands.md). Start every diagnosis with
[`doctor`](commands.md#doctor).

## `doctor` prints a FAIL or WARN line

**Symptom.** `./scripts/nogg doctor` exits non-zero, or prints a `WARN` line
you did not expect.

**Cause.** `doctor` checks tool availability, locks, mapping errors, session
helpers and the last sync result without modifying data. A `FAIL` means an
invariant is broken; a `WARN` (for example, a tmux server born inside a
sandbox) is advisory and does not change the exit code.

**Fix.** Read the named line — each one names the file, lock or check it
concerns. For an interrupted run, rerun with `doctor --recover` and follow
[Resuming an interrupted run](failure-recovery.md#resuming-an-interrupted-run).
`doctor --sandbox` adds slow probes when you are inside the Codex sandbox. See
[Failure recovery](failure-recovery.md) for the procedure behind each check.

## A planning lock is already held

**Symptom.** `plan-begin` refuses: another session owns the planning lock, or
the sync log reports `planning session active`.

**Cause.** Only one planning session may write `openspec/` at a time; the lock
is held by the named session for the whole planning run.

**Fix.** If the owner is live, wait for it to run `plan-end`. If the owner's
process is gone, confirm that first, then run
[`plan-end --force`](commands.md#plan-end). A stale lock never makes
`openspec/` writable for an execution role. See
[A failed sync](failure-recovery.md#a-failed-sync) and
[The sync keeps skipping](failure-recovery.md#the-sync-keeps-skipping).

## The shared Dolt server is unreachable

**Symptom.** `bd` cannot reach the Dolt-backed Beads database, or a
network-off sandbox reports it cannot reach the shared server over loopback.

**Cause.** The Dolt server is host-owned: sessions never start, stop or
restart it. A restricted sandbox has no network, and a server that is down
blocks every Bead write.

**Fix.** Do not start or restart the server from a session — report the exact
error to the operator instead. Bead state is durable: every `bd` write is
already a Dolt commit, so nothing recorded is lost while the server is down
(see [Bead durability across a crash](failure-recovery.md#bead-durability-across-a-crash)).
If two machines wrote before either pulled, follow
[Diverged Dolt histories under multi-machine mode](failure-recovery.md#diverged-dolt-histories-under-multi-machine-mode).

## The tmux server is sandboxed or missing

**Symptom.** `doctor` prints
`WARN  dedicated tmux server (-L nogging) runs inside sandbox PID <pid>`, or
sessions terminate together when one session exits.

**Cause.** A shared tmux server that was started inside a sandbox lives in
that sandbox's namespaces: every session it hosts ends with it.

**Fix.** Either let the hosting session finish, or stop the server
deliberately from an unsandboxed shell with `tmux -L nogging kill-server` and
start a fresh session from the host. Nogging never kills the server
automatically. See
[Tmux server born in a sandbox](failure-recovery.md#tmux-server-born-in-a-sandbox).

## A session stalled or failed

**Symptom.** [session list](commands.md#session) shows a record whose backend
pane is gone, or a session that is hung.

**Cause.** The process crashed, the herdr server restarted, the session was
killed outside Nogging, or the agent is stuck waiting.

**Fix.** Run `session reap` to move vanished records to `failed`, read
`session log <name>` for the last output, then `session cleanup` to retire the
record. For a hung but live session, `session log --follow` or `session
attach` first, then `session stop <name> --reason "<why>"`. See
[A crashed or stuck supervised session](failure-recovery.md#a-crashed-or-stuck-supervised-session).

## A session hit its usage limit

**Symptom.** `session watch` classifies the session as `limit` with a reset
time `until=<ISO8601>`.

**Cause.** Account-wide rate limits are exhausted. Switching models does not
clear this.

**Fix.** Run `session resume-when-ready <name>`; it waits out the reset time
and resumes the session without operator action. Do not retry with a different
model. See
[A session hit its usage limit](failure-recovery.md#a-session-hit-its-usage-limit)
and [usage limits](usage-limits.md).

## Sync is skipped or failing

**Symptom.** Closed Beads are not mirrored into `tasks.md`; `doctor` shows a
skip note, a partial pass, or a `sync-failure.json` record.

**Cause.** Sync refuses to mirror when the repository is not a safe place to
commit (protected branch, planning session active, merge in progress,
detached `HEAD`) — a skip. A repository-wide failure is classified `transient`
(retried automatically) or `permanent` (needs repair).

**Fix.** Read the reason `doctor` names. For skips, move off the protected
branch or finish the in-progress operation; for a `permanent` failure run
[`audit`](commands.md#audit), resolve the disagreement, then rerun
[`sync`](commands.md#sync) — retrying is always safe, sync is idempotent. See
[A failed sync](failure-recovery.md#a-failed-sync) and
[The sync keeps skipping](failure-recovery.md#the-sync-keeps-skipping).

## Worktree cleanup is refused

**Symptom.** `worktree cleanup <record>` refuses before removing anything.

**Cause.** The worktree or its Git directory appears in the mount table (a
sandboxed planner), the caller is inside it, another active session record
works there, or the mount table cannot be read.

**Fix.** Do not retry, force it or delete files by hand. Stop the owning
session first, then run the cleanup from the canonical checkout; if a partial
removal already deleted tracked files, restore them first. See
[A planning worktree whose cleanup is refused](failure-recovery.md#a-planning-worktree-whose-cleanup-is-refused)
and [`worktree`](commands.md#worktree).

## A half-applied rebase left a dirty worktree

**Symptom.** A `git rebase`, `merge` or `pull` hit a read-only `openspec/`;
`git status` shows many modified files nobody edited, and neither
`git rebase --abort` nor a plain reset applies.

**Cause.** Files sorted before `openspec/` were already written from upstream,
but the index and `HEAD` did not move, so Git does not know about the partial
write.

**Fix.** Never reset a dirty tree you did not make: run
[`doctor`](commands.md#doctor) to have the dirty paths reported, and follow
the replay procedure in
[A half-applied worktree after a failed rebase or checkout](failure-recovery.md#a-half-applied-worktree-after-a-failed-rebase-or-checkout).
