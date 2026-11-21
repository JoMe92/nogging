---
name: nogging-sessions
description: Supervised sessions, the Orchestration Agent, multi-machine mode and the notes for each runtime (write-boundary enforcement, operator entry points, long commands). Read it when you run inside or drive a supervised session, act as the Orchestration Agent, use multi-machine mode, or need the notes for your runtime.
---

# Sessions, orchestration and runtime notes

## Supervised sessions

Lead Agent, planning and specialist sessions that Nogging starts run inside a
named session, tracked by a durable record under `.nogging/state/sessions/`
and an append-only log. Operators use
`scripts/nogg session list | attach | log | stop | cleanup`;
`session launch --agent <agent>` chooses the runtime, and the `restricted` /
`trusted` authority levels are tool-neutral. See
`docs/nogging/running-work-in-sessions.md`.

If you are running inside such a session:

- Being launched is not permission to start a Bead. Do not run `bd ready` and
  self-assign work; claim only the Bead the operator names, only when they
  direct it in this session.
- A `restricted` session has no `git push`, no remote Dolt sync and no
  destructive shell. Do not work around it.
- Never echo a credential or token value and never pass one on a command line.
- A session launched with `--full-access` may commit, push its branch and
  fast-forward-merge to `develop`, but only for the single named change it was
  started for. Every hard rule still holds.
- A short command floor (`rm -rf`, `sudo`, `dd`, `mkfs`, `shutdown`, `reboot`,
  fork bomb) is denied under every profile and every agent, with the single
  exception of the Orchestration Agent.
- End the run with a signal: `./scripts/nogg session signal done "PR #<n>
  open"` or `./scripts/nogg session signal blocked "<why>"`.

## The Orchestration Agent

A fourth persona above Planning and the Main Worker (**Product Owner →
Orchestration Agent → {Planning, Lead} → Specialists**), run always-on as the
single supervised `nogg-orchestrator-<slug>` session by a systemd user service and
reachable from a phone via Remote Control. **Claude Code only** in this version.
It is **orchestrate-only by default** — reads state and drives Planning and Lead
sessions through `scripts/nogg`, writing no `openspec/` file and no code
itself. The command floor and the `openspec/` boundary are lifted for it (the
one documented exception, keyed to `--role orchestrator`); the discipline lives
in `.nogging/launch-prompts/orchestrator.md`, and `session list` / `doctor`
show it as `FULL-ACCESS`. It writes `openspec/` or code only under an explicit
`/orchestrate takeover {plan|code}` instruction (one task, then back), and it
never signs an acceptance report. See `docs/nogging/operating-model.md`.
`scripts/nogg orchestrator {run,status,stop,restart}` and
`.claude/commands/orchestrate.md` drive it.

## Multi-machine mode

When `.nogging/config.json` sets `"multi_machine": true` (default `false`), a
`trusted` or orchestrator session runs `bd dolt pull` once at session start —
before reading any Beads state — and `bd dolt push` before the session ends,
if it made any Bead write (create, update, claim, close). This keeps Beads
state synchronized across machines that share one Dolt remote.

`restricted` sessions are unaffected and need no change: they already cannot
run `bd dolt push`/`pull` (no remote Dolt sync in their authority level), and
a `restricted` session's local Bead writes land in Dolt history exactly as
before — they reach the remote via the same machine's next
`trusted`/orchestrator session push, which pushes every pending local commit,
not only its own.

`./scripts/nogg doctor` separately prints a NOTE (never a failure) when local
Dolt is ahead of its configured remote. See
`docs/nogging/failure-recovery.md` for the recovery path if two machines
write before either has pulled.

## Runtime notes

Read the entry for the runtime you are running as, and ignore the others.

- **Claude Code.** `openspec/` writes are also blocked by a `PreToolUse` hook
  (`scripts/hooks/pre-tool-use-openspec-guard`, wired in
  `.claude/settings.json`); the boundary holds without it, and
  `./scripts/nogg task-done <id>` is unaffected by the hook. Specialists are the
  `.claude/agents/*.md` roster, invoked in process through the Task tool.
  Operator entry points: `.claude/commands/{plan,discovery-review,sync-now}.md`.
  For a long command give `Bash` a `timeout` that covers the run (up to 10
  minutes), or use `run_in_background` and wait for its completion
  notification; never re-read its output or `sleep` in between.
- **Claude Code cloud sessions.** The assigned `claude/*` branch is never a PR
  source: push the branch `nogg worktree implement` / `worktree plan`
  allocated, and open the pull request from that branch instead.
- **Codex.** No per-tool hook — `openspec/` stays read-only through the
  filesystem write guard plus the commit hooks; the command floor is
  `.codex/rules/nogging.rules` (execpolicy). Codex has no in-process subagent
  mechanism: a specialist run is a separate supervised session,
  `scripts/nogg session launch --agent codex --role specialist:<type>
  --bead <id>`, under every specialist boundary rule. Operator entry points:
  `.codex/prompts/{plan,discovery-review,sync-now}.md`. For a long command
  give `exec_command` a `yield_time_ms` that covers the run; if it returns
  early, wait with one empty `write_stdin` and a yield of several minutes,
  never a loop of one-second polls (each poll re-sends the whole context).
- **Pi.** No per-tool hook and no execpolicy file — `openspec/` writes are
  blocked by the project-local guard extension
  (`.pi/extensions/nogging-guard.ts`), which also enforces the command
  floor; a second extension (`.pi/extensions/nogging-lifecycle.ts`) reports
  the session's turns to `session watch` and is inert outside a supervised
  session; `restricted` is floor-only (no network or filesystem sandbox at
  either authority level, unlike Claude Code or Codex). Pi has no in-process
  subagent mechanism: a specialist run is a separate supervised session,
  `scripts/nogg session launch --agent pi --role specialist:<type>
  --bead <id>`, under every specialist boundary rule. Operator entry points:
  `.pi/prompts/{plan,discovery-review,sync-now}.md`. Run a long command in one
  shell call that waits for it, with a timeout that covers the run.

Any other runtime Nogging supports has its own guide under `docs/nogging/`
(`using-with-*.md`); its rules there apply unchanged.
