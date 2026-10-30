## Nogging agent instructions

Read `docs/nogging/operating-model.md` and the active Bead before work. This
block is the canonical, tool-neutral instruction set; the per-tool specifics
are confined to *Tool notes* at the end.

### Hard rules

1. Execution agents (Main Worker and specialists) must not edit `openspec/`.
2. Work only on a Bead that has been claimed by the Main Worker.
3. Commit a Bead in several coherent steps, not as one commit at the end. Each
   commit stays within the configured commit range (`task_sizing.commit_lines`
   in `.nogging/config.json`; `./scripts/nogg task-sizing` prints it), is a
   Conventional Commit containing the Bead ID (e.g. `[SPEC-abc]`), and holds
   the tests for the code it changes. Test in stages: while working, run only
   the tests of the files you change; before each commit, those tests plus
   lint of the changed files; once per Bead, before closing it, the affected
   suite. The full suite is CI's job; run `scripts/test` once per Bead only
   where the project has no CI. Run a long command (a suite, a build) as one
   blocking call with a timeout long enough for it to finish —
   `./scripts/nogg run-quiet -- <command>` prints one line on success and
   only the tail on failure — and never poll a running command (*Tool notes*
   has the per-runtime detail). Then close the Bead (`bd close <id>`) and
   immediately run `./scripts/nogg task-done <id>` to tick its mapped
   `tasks.md` line (it refuses unless the Bead is already closed), bundling
   that tick into the Bead's last commit, and add a Bead note listing every
   commit SHA and the evidence.
4. Record every material discovery on the active Bead with the native Beads
   `discovery` label plus a required human-readable note — never as serialized
   data, and never by editing `openspec/`. A blocking discovery also sets the
   Bead status to `blocked`; the next planning session lists them with
   `bd list --label discovery`.
5. Leave an intent breadcrumb. Before an expensive or hard-to-reverse step, and
   before ending a turn with a Bead still `in_progress`, append a one-line
   `progress: <next step>` to the Bead note
   (`bd update <id> --append-notes "progress: …"`). On resume, in any tool, it
   is the primary "where was I" signal.

### The write boundary

`openspec/` is read-only for every execution agent and writable only during a
planning session holding the canonical `.nogging/locks/planning.lock` in the
main checkout (`./scripts/nogg plan-begin` … `plan-end`). A held planning lock
never makes `openspec/` writable for an execution role. The lock toggles a
`.nogging/locks/openspec.readonly` sentinel that the write guard consults.

### Specialist delegation

Isolated implementation or review work may be delegated to a specialist, but
claiming a Bead, closing it, writing the evidence note, and committing stay
with the Main Worker, and no delegated context may write `openspec/`.

When a specialist's delegated, incorporated work contributes to a commit, add
a `Co-authored-by: <specialist persona name> <specialist persona email>`
trailer naming that specialist (roster in `.nogging/config.json`'s `personas`
key).

### Planning only

The Planning Agent first allocates `./scripts/nogg worktree plan
<planning-id> <description>` from updated `origin/develop` and works only in
that worktree. A supervised planner gets its worktree at launch:
`./scripts/nogg session launch --role planning --planning-id <planning-id>
--description <description>`. A bare launch stays idle; an optional `--bead`
is context only and is never claimed. After kickoff the planner runs
`plan-begin` itself. That takes the canonical planning lock in the main
checkout, owned by that session; nobody acquires it on its behalf. It writes
or revises OpenSpec, validates, commits with `NOGGING_WRITER=planning`,
materializes Beads (`./scripts/nogg materialize <change>`), wires Beads
dependencies explicitly, fast-forward integrates the plan into `develop`, and
then runs `./scripts/nogg plan-end` from the planning worktree (`plan-end`
always precedes worktree retirement) and, as the very last command, retires the
clean, integrated worktree with `./scripts/nogg worktree cleanup <record>` from
the surviving canonical checkout. If cleanup refuses, it does not retry, force
it or delete files: it reports the hand-off, `./scripts/nogg session stop
<name>`, then `./scripts/nogg worktree cleanup <record>` from the canonical
checkout, and stops. Validation names the change: `./scripts/nogg validate`
plus `openspec validate <change> --strict --no-interactive`, never a bare
`openspec validate`. The commit precedes `materialize` so a crash between them never leaves Beads
without a committed spec. Stop, cleanup and recovery never release another
session's planning lock.

### The Orchestration Agent

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

### Multi-machine mode

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

### Tool notes

- **Claude Code.** `openspec/` writes are also blocked by a `PreToolUse` hook
  (`scripts/hooks/pre-tool-use-openspec-guard`). Specialists are the
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

### Antigravity

`--agent antigravity` (alias `agy`) uses `.agy.toml` profiles and the Python
`scripts/hooks/agy-guard` PreToolUse hook from `.agents/hooks.json`. Both levels
retain the command floor and canonical planning-lock OpenSpec boundary.
Restricted requires verified ask permissions; global always-proceed is refused.
No filesystem/network isolation is validated; requested sandbox mode refuses.
Launch prepares trust only for the selected worktree and refuses missing guards
or failed trust writes. Workflow skills are `.agents/skills/nogging-{plan,discovery-review,sync-now}`.
Specialists run separately with `scripts/nogg session launch --agent agy
--role specialist:<type> --bead <id>` on exactly one already-claimed Bead;
never claim, re-status, close, commit or write OpenSpec. Return structured
results and discoveries to the Main Worker. See `docs/nogging/using-with-antigravity.md`
for exact resume, lifecycle and pending acceptance/quota limitations.

Update Nogging itself with `npx github:JoMe92/nogging update`.
