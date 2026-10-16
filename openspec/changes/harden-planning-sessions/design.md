## Context

The baseline is `develop` at 616b4c0. This is the code as it stands there,
checked against issues #176, #177 and #178 and the fleet's planning runs:

- **Close order.** The planning prompt, the four `/plan` surfaces and the
  kickoff text in `_session_kickoff` all say: integrate, retire the
  worktree, then `plan-end` "from a surviving canonical checkout".
  `scripts/planning-docs.test.sh` enforces "Cleanup always precedes
  `plan-end`". The Antigravity plan skill already says `plan-end` "from the
  planning worktree", so the surfaces disagree.
- **`plan-end` from the worktree already works.** `release_planning_lock()`
  resolves the canonical locks directory through
  `canonical_repository_state(ROOT)` and takes the owner from
  `planning_session_context()`, which reads the record in
  `NOGG_SESSION_ROOT`. No suite runs `plan-end` from a linked planning
  worktree.
- **Codex sandbox.** Codex builds its bubblewrap sandbox from the launch
  worktree and binds it, and its Git directory, as writable roots. Inside
  that sandbox they are mount points. `cleanup_worktree()` checks only for a
  clean tree and integration, then runs `git worktree remove`. Inside the
  sandbox, Git deletes the tracked files and then fails on the mount point
  with `Device or resource busy`. SPEC-brxc recorded 30 tracked files
  restored after this. Run from the host, removal succeeds, and the still
  running Codex session can then start no command at all (#176).
- **Bind mounts.** A bind mount from the same filesystem keeps the parent's
  `st_dev`, so `os.path.ismount()` does not see it. Only the mount table
  (`/proc/self/mountinfo`) does.
- **Stop and the lock.** `session_stop()` kills the backend session and then
  calls `transition(..., "stopped")`, which calls
  `release_planning_lock(session_record=rec)`. That function closes the
  boundary, but keeps the lock while `planning_lock_live()` is true.
  `pid_alive()` uses `os.kill(pid, 0)`, which also succeeds for a process
  that is exiting or not yet reaped. A lock check right after the kill can
  therefore still see the owner, so the lock is kept. A second `session
  stop` on the terminal record already releases it, but nothing says so:
  `recover` suggests `plan-end --force`.
- **agy guard.** `decide()` accepts only `write_to_file`,
  `replace_file_content`, `run_command`, `read_url_content` and four read
  tools. Anything else raises, and `main()` replaces every exception with
  one generic reason. A recorded agy 1.4.0 transcript on the delivery host
  shows `search_web` arguments `query`, `toolAction` and `toolSummary`. The
  same transcript shows `read_url_content` with `Url`, which matches the
  committed 1.3.2 hook fixture, so hook keys and transcript keys agree.
  Issue #177 guessed `Query`; the recorded key is lowercase `query`.
- **Planning authority.** `_session_launch()` sets `prompt = prompt or
  "planning"` and resolves the profile per agent, with `restricted` as the
  default. The manual-mode warning at the end of the launch covers only lead
  and specialist roles. For Codex, `restricted` means `on-request` approvals
  and no network. For Antigravity, it means `ask` approvals and a guard that
  answers `force_ask` to every tool.
- **Restricted Codex and Dolt.** Verified on the delivery host with
  codex-cli 0.162.1: under `codex sandbox` with
  `sandbox_workspace_write.network_access=false`, `bd list` fails with
  `Dolt server unreachable at 127.0.0.1:3308: dial tcp 127.0.0.1:3308:
  socket: operation not permitted`, and `bd` suggests `bd dolt start`. With
  `network_access=true` the same call succeeds. The `codex-onboarding`
  scenario that has `scripts/nogg discoveries` succeed at `restricted`
  predates the shared Dolt server. `.beads/config.yaml` now sets
  `dolt.shared-server: true`.
- **Validation.** `openspec validate` (1.11.0) with no item name prompts for
  one. `--no-interactive` disables the prompt. The orchestrator prompt still
  says a bare `openspec validate --strict`.

## Goals / Non-Goals

**Goals:**

- Every planner, on every runtime, can finish `plan-end` itself.
- No cleanup ever deletes part of a worktree and then fails.
- A stopped planner's lock is released without `--force`.
- Antigravity can search the web under the authority rules that already
  apply to `read_url_content`, and every denial says why.
- A Codex or Antigravity planner never starts at an authority that blocks
  it, and nobody's authority is raised silently.

**Non-Goals:** see `proposal.md`.

## Decisions

### 1. Test discipline for GitHub runners (every task)

- **No Dolt and no real `bd`.** Stub `bd` through `beads_command` or a
  `PATH` stub.
- **No PID-range assumptions.** To get a live owner, keep a child process
  running. To get a dead one, terminate the child and reap it with `wait()`.
  Treat namespace identities as opaque strings.
- **No `unshare`, no real mounts.** Simulate a mount point by replacing the
  one function that reads the mount table. Simulate a fenced caller with
  `NOGG_OPENSPEC_FENCED=1`.
- **No running tmux server.** Replace `tmux_has_session` and the backend
  calls in-process, or put a `PATH` stub named `tmux` first that records its
  argv and exits non-zero. Never touch the operator's or the shared Nogging
  tmux server.
- **Clean environment.** Source `scripts/lib/test-env.sh` first, which
  clears `NOGG_*` and `NOGGING_ROOT`. Also unset `HERDR_*`, `TMUX` and
  `TMUX_TMPDIR`, then set only what the case needs. This planner's own
  session identity must never reach a fixture.
- **One suite per task.** Each code task adds its own
  `scripts/<name>.test.sh`. Existing suites change only where they assert
  the old behaviour.

### 2. `plan-end` before retirement (close protocol)

The close sequence of every planning session becomes:

1. Fast-forward integrate the planning branch into `develop`, locally. A
   dirty or unintegrated worktree is preserved, as today.
2. Run `./scripts/nogg plan-end` **from the planning worktree**, in the
   owning session, with its inherited session identity. The worktree and
   the sandbox built on it still exist, so this works on every runtime. It
   releases only the session's own canonical lock and writes the canonical
   sentinel.
3. As the very last command, retire the worktree from the surviving
   canonical checkout: `cd <main checkout> && ./scripts/nogg worktree
   cleanup <record>`. A runtime that does not mount the worktree into a
   sandbox (Claude, Antigravity, Pi) finishes here.
4. If cleanup refuses (Decision 3), do not retry, force it or delete files
   by hand. Report the hand-off line and stop: `./scripts/nogg session stop
   <name>`, then `./scripts/nogg worktree cleanup <record>` from the
   canonical checkout. The operator or the Orchestration Agent runs it. For
   a Codex planner, this is the normal end.

`plan-end` always precedes worktree retirement. Retiring while the lock is
held gains nothing: integration into `develop` has already happened, and
retirement touches no `openspec/` path. After `plan-end`, the old worktree
holds only committed, integrated work, and the canonical sentinel already
fences it.

- **Validation step.** Every planning surface names the change:
  `./scripts/nogg validate` plus `openspec validate <change> --strict
  --no-interactive`. A bare `openspec validate` is never written.
- **Rejected alternatives:**
  - *Retire as a side effect of `session stop` or `session cleanup`.* It
    breaks the "deliberate lifecycle" rule, and it would retire a worktree
    the operator wanted to inspect.
  - *Record a "retire after stop" intent in `worktree cleanup`.* It adds a
    second state machine for a two-command hand-off.
  - *Keep the old order and special-case Codex.* That leaves two protocols,
    and Claude planners still lose their working directory before
    `plan-end`.

### 3. `worktree cleanup` refuses an in-use worktree before deleting anything (TASK-HPS-001)

`cleanup_worktree()` keeps its record, clean-tree and integration checks.
Before `git worktree remove`, it adds three checks, all read-only. Any one
of them refuses with a non-zero exit, and the worktree, branch and record
stay unchanged:

- **Mounted into the caller's namespace.** One function,
  `mount_points()`, reads `/proc/self/mountinfo` (field 5, with octal
  escapes such as `\040` decoded) and returns resolved paths. The worktree
  path, anything under it, and the worktree's Git directory (`git -C <wt>
  rev-parse --absolute-git-dir`) must not be among them. An unreadable
  mount table also refuses, because the check fails closed. Message:
  `refusing to remove <wt>: it is mounted into this process's sandbox at
  <path>; run plan-end first if you are its planner, then hand off: the
  operator runs 'nogg session stop <name>' and 'nogg worktree cleanup
  <record>' from <main checkout>`. `<name>` is `NOGG_SESSION_NAME` when
  set, else `<session>`.
- **Current directory.** The caller's resolved `os.getcwd()` must not be
  the worktree or a path under it. Message: `refusing to remove the current
  directory <wt>; run worktree cleanup from <main checkout>`.
- **Another live session.** The canonical session store (the main
  checkout's `session_state_dir`) must hold no record in `starting`,
  `running` or `idle` whose resolved `working_dir` is the worktree or under
  it. The caller's own record (`NOGG_SESSION_NAME`) is exempt, so a
  planner can retire its own worktree from the canonical checkout. Message:
  `refusing to remove <wt>: it is the working directory of active session
  <name> (<state>); stop it first with 'nogg session stop <name>'`. A stale
  `running` record also refuses; `session reap` resolves it.

The checks apply to every recorded worktree, planning and implementation
alike.

- **Suite:** `scripts/worktree-cleanup-in-use.test.sh`. It loads
  `scripts/nogg` as a module in a temporary repository with one linked,
  clean, integrated worktree and its record. Each case asserts that the
  worktree directory, every tracked file, the branch and the record are
  unchanged after a refusal. It covers:
  - the worktree as a mount point;
  - its Git directory as a mount point;
  - a mount point below the worktree;
  - an unreadable mount table;
  - the caller's current directory inside the worktree;
  - another session's `running` record;
  - the caller's own `running` record, which proceeds;
  - a `stopped` record, which proceeds;
  - the plain case, which retires exactly as before;
  - a parser case for an escaped mount point path.

### 4. Stop releases a stopped planner's lock (TASK-HPS-002)

- **Wait for the owner.** For a record with role `planning` whose session
  owns the canonical lock (`planning_lock_owned`), `session_stop()` polls
  `planning_lock_live(lock)` every 0.2 s after the backend session is gone.
  It stops polling when the owner is gone or when the
  `session_stop_grace_seconds` deadline, measured from the stop's start,
  is reached. It then makes the terminal transition, which releases the
  lock as today. Other roles, and a lock owned by another session, skip the
  wait.
- **Retention message.** When the owner is still live, the lock is kept
  exactly as today. The message becomes: `planning lock retained for
  still-live owner <name> pid <pid>; rerun 'nogg session stop <name>' once
  it has exited (never plan-end --force while it lives)`.
- **`recover`.** For an interrupted planning owner whose session record
  exists, the attention line names `nogg session stop <name>` as the
  release. `plan-end --force` stays the remedy only when no record remains.
  The line keeps the prefix `interrupted planning owner <name>`.
- **Suite:** `scripts/planning-close-order.test.sh`. It loads
  `scripts/nogg` as a module with a main checkout, a linked planning
  worktree, its worktree record and a planning session record. The owner is
  a live child process, `sleep`. `tmux_has_session`, the backend calls and
  `collect_session_usage` are replaced in-process. It covers:
  - `plan-end` run with `NOGGING_ROOT` set to the planning worktree and the
    session identity releases the canonical lock and writes the canonical
    sentinel. A following `worktree cleanup` from the main checkout, with
    no mount and the caller's own record, retires the worktree;
  - `session stop` while a helper thread terminates and reaps the child
    after 0.5 s, with a 5 s grace: the lock is released and no `--force` is
    used;
  - a child that outlives a 0.5 s grace: the lock is kept, the message
    names `session stop <name>`, and a second stop after the child is
    reaped releases it;
  - the `recover` attention text;
  - an execution-role stop leaves another planner's lock untouched.

### 5. Antigravity `search_web` and named denials (TASK-HPS-003)

- **Contract.** `decide()` accepts `search_web` when `args["query"]` is a
  non-empty string, after stripping, without NUL. It returns `allow` under
  `trusted` and `force_ask` under `restricted`, the same split as
  `read_url_content`. Any other shape raises `invalid search query`.
- **Named denials.** `main()` maps a `ValueError` raised by `decide()` to
  `Nogging: <message>` only when it is the guard's own denial: a dedicated
  `GuardDenied(ValueError)` class, which every existing `raise
  ValueError(...)` in `decide()` becomes. The unsupported-tool message
  becomes `unsupported tool contract: <name>`. `<name>` is the tool name if
  it matches `[A-Za-z0-9_.-]{1,64}`, else `<invalid>`. Every other
  exception maps to `Nogging: malformed tool payload`. That includes
  `json.JSONDecodeError` and other library `ValueError`s such as `shlex`'s,
  as well as missing keys and wrong types. A reason never contains argument values: no command, path, URL
  or query. Decisions do not change for any other tool.
- **Fixture.** `scripts/fixtures/antigravity/1.4.0/search_web.json` takes
  the 1.3.2 `read_url_content.json` envelope with neutral values for
  `query`, `toolAction` and `toolSummary`. A `README.md` beside it says it
  is derived from a recorded 1.4.0 transcript tool call, not captured from
  a hook. TASK-HPS-007 confirms it live.
- **Suite:** `scripts/agy-guard-web-search.test.sh`, in the layout of
  `scripts/agy-guard.test.sh`. It covers, under both authority levels and
  for the lead and planning roles:
  - the fixture replayed;
  - empty, whitespace, non-string, NUL and missing `query`, each denied with
    `invalid search query`;
  - `Query` (wrong case) denied;
  - an unknown tool's reason naming it;
  - a hostile tool name shown as `<invalid>`;
  - a floor command whose reason names the command floor and does not
    contain the command;
  - malformed JSON giving `malformed tool payload`.

  The existing `agy-guard.test.sh` stays unchanged.

### 6. Planning launches name their authority (TASK-HPS-004)

- **One check.** `planning_launch_authority(agent, profile, full_access)`
  raises when the role is `planning`, the agent is `codex` or
  `antigravity`, and neither `--profile` nor `--full-access` was given. The
  message: `planning with <agent> needs an explicit authority: --profile
  trusted for an unattended planner, or --profile restricted to approve
  each step in the attached session (restricted <agent> stops at approval
  prompts)`. `_session_launch()` calls it right after `normalize_role()`.
  That is before tier resolution, backend preflight, the usage gate,
  worktree allocation, trust preparation and the record, log and backend
  session. A configured `session_launch_profile` is
  Claude-only and does not count.
- **Explicit restricted.** `--profile restricted` with Codex or Antigravity
  proceeds and prints `NOTE: restricted <agent> planning stops at approval
  prompts; attach to approve each step`.
- **Launch output.** Every successful launch prints `  profile=<label>
  prompt=<prompt file stem>`. The lead and specialist manual-mode warning
  also covers a Claude planning launch made with neither `--profile` nor
  `--full-access`, decided on the caller's original arguments. Every
  restricted Codex launch, of any role, prints `NOTE: restricted Codex has
  no network; a Dolt-server-backed bd is unreachable from its sandbox`.
  Pi is unchanged.
- **Suite:** `scripts/planning-launch-profile.test.sh`. It runs the CLI in
  a temporary repository with a `tmux` stub first on `PATH` that records
  argv and exits 1. It covers:
  - Codex, `antigravity` and `agy` planning launches without a profile:
    refused, naming both flags; no planning worktree directory or record,
    no session record or log, and no `tmux` invocation;
  - direct calls to `planning_launch_authority` that pass for `--profile
    trusted`, `--profile restricted`, `--full-access`, any Claude or Pi
    call, and every non-planning role;
  - the launch-output helpers for the profile line and the notes, called
    directly.

### 7. Planning surfaces state the close order (TASK-HPS-005)

The order from Decision 2, the hand-off line and the named validation step
go into every surface that states the planning flow:

- `.nogging/launch-prompts/planning.md`;
- `.claude/commands/plan.md`, `.codex/prompts/plan.md`,
  `.pi/prompts/plan.md` and `templates/antigravity/skills/nogging-plan/SKILL.md`;
- the planning kickoff text in `_session_kickoff`;
- `AGENTS.md` and `templates/agents-block.md`, kept identical;
- `docs/operating-model.md`, `README.md`, `docs/worktree-workflow.md`,
  `docs/running-work-in-sessions.md`, `docs/using-with-codex.md`,
  `docs/using-with-pi.md` and `docs/using-with-antigravity.md`;
- `.nogging/launch-prompts/orchestrator.md` and
  `.claude/commands/orchestrate.md`: after a planner reports that
  `plan-end` ran, stop it, then run `worktree cleanup` from the canonical
  checkout. The bare `openspec validate --strict` becomes the named,
  non-interactive form;
- `docs/failure-recovery.md`: refused cleanup and its hand-off, the
  `session stop` lock release, and restoring tracked files that an older
  build's partial `git worktree remove` deleted (`git -C <wt> restore
  --source=HEAD --worktree -- .`, then cleanup again).

The phrase "`plan-end` always precedes worktree retirement" replaces
"Cleanup always precedes `plan-end`".

- **Suite:** `scripts/planning-docs.test.sh` is updated. It asserts this
  order:
  - on every `/plan` surface and the Antigravity skill: plan-begin, commit,
    materialize, `bd dep add`, fast-forward, `plan-end`, worktree
    retirement, surviving canonical checkout;
  - the new phrase;
  - the hand-off line;
  - `--no-interactive` with a named change on every planning surface, and
    no bare `openspec validate --strict` in any of the listed files.

  The kickoff assertions in `scripts/planning-kickoff.test.sh` keep
  passing. The installed-copy check is unchanged.

### 8. Runtime guidance (TASK-HPS-006)

- **Codex.** `docs/using-with-codex.md` states that a restricted Codex
  session has no network, including loopback TCP, so `bd` with the shared
  Dolt server fails with `Dolt server unreachable … socket: operation not
  permitted`. The guide names the remedy: relaunch with `--profile trusted`
  or let the operator run the `bd` step. It corrects the sentence that
  presents `bd` as working at `restricted`, and it states the planning
  launch rule.
- **Prompts.** `.nogging/launch-prompts/planning.md`, `autonomous.md` and
  `no-autonomous-claim.md` add one line: the shared Dolt server is
  host-owned, so never start, stop or restart it (for example `bd dolt
  start`) from a session; if `bd` cannot reach it, stop and report the
  exact error.
- **Antigravity.** `docs/using-with-antigravity.md` documents `search_web`
  (`query`; `allow` under `trusted`, an approval under `restricted`), the
  named deny reasons and the planning launch rule.
- **Sessions and security.** `docs/running-work-in-sessions.md` and
  `docs/operating-model.md` (*Launch profiles*, *The agent is selectable*)
  describe the planning launch refusal, the `profile=` launch line and the
  restricted-Codex Dolt note. `docs/security-model.md` lists `search_web`
  with `read_url_content` as guarded read-only network access.
- **Orchestrator.** `.nogging/launch-prompts/orchestrator.md` launches Codex
  and Antigravity planners with `--profile trusted`, or `--full-access`,
  and names starting the Dolt server as a host action.
- **Suite:** `scripts/runtime-guidance-docs.test.sh` asserts each of these
  statements in its file, and that the installed launch prompts equal the
  source.

### 9. Short live re-acceptance (TASK-HPS-007)

This is a live run on the delivery host. It uses a scratch consumer
repository installed from the packed tree, never this repository's
`develop`, and a throwaway planning scope. It runs these checks:

- **Launch refusal.** A Codex planning launch without a profile is refused
  with no side effect.
- **Codex close order.** A Codex planner with `--profile trusted` runs the
  full sequence through `plan-end` from its worktree. Its own cleanup is
  refused as mounted, and no file is deleted. The operator's `session
  stop` and `worktree cleanup` succeed, and no `--force` is used.
- **Claude close order.** A Claude planner retires its own worktree from
  the canonical checkout after `plan-end`.
- **Antigravity.** A trusted Antigravity session runs one `search_web`,
  and the call is allowed. A hook capture confirms the `query` key, or the
  report records a fixture correction. A restricted session shows the
  approval prompt for `search_web`.
- **Validation.** A named `openspec validate <change> --strict
  --no-interactive` returns without a prompt.

The report is `docs/acceptance/<date>-planning-robustness.md`, written from
the template and left unsigned. Host-side steps are recorded as operator
actions. The run never stops the shared tmux server or the Orchestration
Agent. It needs a session that can launch Codex, Claude and Antigravity
sessions and run host-side commands, so it does not suit a sandboxed Codex
or Antigravity worker.

## Dependencies and parallel lanes

`A ← B` means A depends on B (`bd dep add A B`). The edges are explicit, not
inferred from task order.

Branches follow `<type>/harden-planning-sessions`. Tasks that run at the
same time differ only in the `<type>` prefix, so each lane owns one prefix.
Tasks in the same lane run one after another: each deletes its integrated
branch before the next allocates it. The prefix only tells parallel
worktrees apart; each commit subject still carries its own Conventional
type.

| Task | Complexity | Depends on | Branch prefix | Main files (ownership) |
| --- | --- | --- | --- | --- |
| HPS-001 cleanup in-use guard | standard | — | `fix/` | `scripts/nogg` (`cleanup_worktree`, new `mount_points`) |
| HPS-002 stop releases planner lock | standard | — | `refactor/` | `scripts/nogg` (`session_stop`, `release_planning_lock` message, `recover` planning attention line) |
| HPS-003 agy `search_web`, named denials | routine | — | `feat/` | `scripts/hooks/agy-guard`, `scripts/fixtures/antigravity/1.4.0/` |
| HPS-004 planning launch authority | standard | — | `chore/` | `scripts/nogg` (`_session_launch` early check and launch output, new `planning_launch_authority`) |
| HPS-005 close order on all surfaces | standard | 001, 002 | `docs/` | planning prompt, four `/plan` surfaces, `_session_kickoff` planning text, `AGENTS.md` and template, flow docs, orchestrator prompt and command, `failure-recovery.md`, `scripts/planning-docs.test.sh` |
| HPS-006 runtime guidance | standard | 003, 004, 005 | `docs/` | Codex and Antigravity guides, session, operating-model and security docs, launch prompts, orchestrator prompt |
| HPS-007 live re-acceptance | complex | 006 | `test/` | `docs/acceptance/<date>-planning-robustness.md` |

Why each edge exists:

- **005 ← 001, 002.** The documented hand-off and the lock release must
  match the implemented refusal messages and stop behaviour.
- **006 ← 003, 004.** The guides describe the guard and launch behaviour as
  finally implemented.
- **006 ← 005.** Both edit the planning prompt, the orchestrator prompt,
  `docs/using-with-codex.md` and `docs/operating-model.md`. The docs lane
  runs them one after another.
- **007 ← 006.** The acceptance checks the documented behaviour.

The lanes run as follows:

- **At start:** 001, 002, 003 and 004 can all begin at once, on four
  distinct prefixes. 001, 002 and 004 edit disjoint regions of
  `scripts/nogg`. Each rebases onto `develop` before its pull request.
- **Spine:** 005 → 006 → 007.

**Cross-change overlap, no edge.** TASK-RSI-006 (`reliable-session-input`)
changes how `_session_kickoff` delivers messages. TASK-HPS-005 changes only
the planning message text there. ORR-004, RSI-007 and ULT-007 edit other
sections of the same guides. None of these is a semantic dependency.
Whichever lands second rebases and keeps both changes. The new suites
follow `usage-ledger-test-isolation`'s shared `scripts/lib/test-env.sh`.

Before allocating a dependent worktree, a Lead verifies that every
prerequisite execution commit is integrated into `develop`; Bead closure
alone is not enough. TASK-HPS-001 to TASK-HPS-006 suit sandboxed Codex or
Antigravity Leads. A sandboxed Codex Lead needs `--full-access`, or
`--profile trusted`, to reach the shared Dolt server for `bd`.
TASK-HPS-007 needs a host session.

## Risks / Trade-offs

- **The hand-off needs a second actor.** A Codex planner cannot retire its
  own worktree. Until the operator or the Orchestration Agent stops it and
  runs cleanup, the worktree stays. The lock is already released by then,
  so the next planner is not blocked.
- **Mount-table check, not a full in-use proof.** A process that only has
  its current directory in the worktree, without a mount, is caught only
  when it is the caller or has an active session record. Another process,
  such as an editor, can still lose its directory. That is today's
  behaviour, and it deletes nothing partially.
- **Stale records refuse.** A `running` record whose session is gone blocks
  cleanup until `session reap`. This fails closed on purpose.
- **Stop can take longer.** A planning stop can wait up to the grace period
  a second time. It applies only to the owning planner.
- **Derived fixture.** The `search_web` hook payload is derived from a
  transcript, not captured from a hook. A wrong key fails closed with a
  named reason, and TASK-HPS-007 confirms it.
- **A refused default is a breaking change for scripts** that launch Codex
  or Antigravity planners without a profile. The refusal names the fix, and
  the orchestrator prompt is updated in the same change.
