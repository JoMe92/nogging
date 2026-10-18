## Why

Planning and research sessions on Codex and Antigravity fail in ways that cost
a lock recovery, a relaunch or a lost conversation. Three GitHub issues and
the fleet's own runs show the same pattern:

- **#176.** A Codex planner cannot run `plan-end` once its planning worktree
  is retired. Codex builds its bubblewrap sandbox from the launch worktree,
  so after the removal every command fails before it starts. From inside the
  sandbox, `worktree cleanup` fails with `Device or resource busy`, and
  `git worktree remove` has already deleted tracked files by then. Planning
  runs recorded this on SPEC-hjir, SPEC-brxc and the TUC planning notes.
  Claude planners that retired their worktree first lost their working
  directory too.
- **#177.** `scripts/hooks/agy-guard` denies Antigravity's `search_web` at
  every authority level. The deny reason is the generic "malformed or
  unsupported tool", so the agent cannot tell why.
- **#178.** A planning launch for Codex or Antigravity without `--profile`
  runs at `restricted` and stops at an approval prompt on almost every step.
  The watcher sees an idle pane, not a failure. A restricted Codex planner
  also cannot reach the shared Dolt server. Verified on codex-cli 0.162.1:
  with `network_access=false`, `bd` fails with `dial tcp 127.0.0.1:3308:
  socket: operation not permitted` and suggests `bd dolt start`, which is
  exactly what a restricted planner then tried to run.
- **Interactive validation.** `openspec validate --strict` without a change
  name waits for interactive input, so a sandboxed agent hangs on it.

## What Changes

- **`plan-end` comes before worktree retirement.** A planner releases its
  own lock with `plan-end` from its planning worktree, while that worktree
  and the sandbox built on it still exist. It retires the worktree last,
  from the surviving canonical checkout. When cleanup refuses, the planner
  hands retirement off: the operator stops the session and runs the same
  cleanup from the canonical checkout.
- **`worktree cleanup` refuses an in-use worktree before deleting
  anything.** It refuses when the worktree or its Git directory is a mount
  point in the caller's namespace, when it contains the caller's current
  directory, or when it is the working directory of another active
  supervised session. No file is removed on refusal.
- **`session stop` releases a stopped planner's lock without `--force`.**
  Stop waits, within its grace period, for the planning owner's process to
  exit, then releases the lock as today. A lock it must keep names `session
  stop <name>` as the next step, and `recover` does the same.
- **Antigravity can search the web.** The guard accepts `search_web` with a
  non-empty `query`, which is the argument key recorded in an agy 1.4.0
  transcript. It allows the call under `trusted` and asks for approval
  under `restricted`, like `read_url_content`. Every denial names its cause
  and the tool, never the arguments.
- **Planning launches name their authority.** A Codex or Antigravity
  planning launch without `--profile` or `--full-access` is refused before
  any side effect, naming `--profile trusted` and `--profile restricted`.
  Nothing escalates silently. Every launch prints its effective profile. A
  Claude planning launch at the implicit default prints the existing
  manual-mode warning, and a restricted Codex launch prints that `bd` cannot
  reach a Dolt server.
- **Guidance.** All planning surfaces state the new close order and name
  the change in `openspec validate <change> --strict --no-interactive`. The
  Codex guide states that a restricted session cannot reach the shared Dolt
  server. The launch prompts say that the Dolt server is host-owned and is
  never started or stopped from a session. The Antigravity guide documents
  `search_web`, and the orchestrator prompt launches Codex and Antigravity
  planners with an explicit profile.
- **A short live re-acceptance** of the Codex close order, the cleanup
  refusal, the launch refusal and `search_web` produces an unsigned report.

## Non-Goals

- Retiring a planning worktree automatically as a side effect of `session
  stop` or `session cleanup`. Retirement stays one deliberate command.
- Changing how Codex builds its sandbox, or Nogging's `openspec-sandbox`.
- A role-default profile key, or any silent default to `trusted`.
- Refusing restricted Claude or Pi planning launches. Claude depends on the
  repository's permission rules and gets a warning. Pi's restricted level
  asks no approvals.
- Changing the `-` that `session list` shows for `restricted`.
- New command-floor entries for Dolt server commands. The floor is mirrored
  across four runtimes; prompts and docs carry this rule.
- Enabling other unvalidated Antigravity tools, such as multi-edit or
  browser tools, or allowing web search under `restricted` without approval.
- Making the shared Dolt server reachable from a restricted Codex session.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workflow-commands`: `/plan` releases the lock before retiring the
  worktree; planning instructions name the change for validation and keep
  the Dolt server host-owned.
- `agent-worktrees`: cleanup refuses an in-use worktree before removing
  anything.
- `claude-sessions`: stopping the owning planner releases its lock after the
  owner exits.
- `launch-profiles`: a Codex or Antigravity planning launch needs an
  explicit profile.
- `antigravity-onboarding`: `search_web` follows the authority level, and
  denials name their cause.
- `codex-onboarding`: a restricted Codex session cannot reach a shared Dolt
  server, and the guide says so.

## Impact

- Code: `scripts/nogg` (`cleanup_worktree`, `session_stop`, `recover`
  attention text, the planning launch check and launch output, the planning
  kickoff text) and `scripts/hooks/agy-guard`.
- Tests: one new suite per code task, runnable on GitHub runners with no
  Dolt or `bd`, no PID-range assumptions, no `unshare` and no running tmux
  server. `scripts/planning-docs.test.sh` asserts the new order.
- Fixture: `scripts/fixtures/antigravity/1.4.0/search_web.json`, derived
  and labelled as such.
- Docs and prompts: the planning prompt, the `/plan` command for Claude,
  Codex and Pi, the Antigravity plan skill, `AGENTS.md` and its template,
  the operating model, README, the worktree, session, recovery, security,
  Codex and Antigravity guides, and the orchestrator prompt and command.

This planning artifact authorizes no execution work, release, push or human
acceptance sign-off.
