# Using Nogging with Claude Code

This page is for anyone running the Nogging loop from **Claude Code**, the
default agent: it covers what the installer places under `.claude/`, the slash
commands, the six specialists and how a Lead Agent delegates to them, the
authority levels and effort selection, and the Claude-only Orchestration Agent
with Remote Control. `AGENTS.md` is the canonical instruction file for every
agent runtime, and the mechanical bridge (`scripts/nogg`) is the same whichever
agent runs it, so this page covers only what is specific to Claude Code. For the
other runtimes, see the [Codex](using-with-codex.md) and [Pi](using-with-pi.md)
guides.

Claude Code is the agent Nogging uses when you pass no `--agent` flag:
`session launch` reads the `session_agent` key in `.nogging/config.json`, which
defaults to `claude`. The version validated against this release is listed in
the [compatibility matrix](compatibility.md).

## Prerequisites

In addition to the usual target-repo prerequisites (`bd`/Beads, `python3`,
`git`, and a reachable Dolt for sync):

- **The `claude` CLI on `PATH`, signed in.** Nogging never stores or asks for
  your credentials. `./scripts/nogg doctor` reports the CLI as available or
  not; its absence never fails `doctor` for a repository that uses another
  agent.
- **A trusted workspace.** Run `claude` once in the repository root and accept
  the trust prompt. `scripts/nogg orchestrator status` points at this when the
  Orchestration Agent's workspace is untrusted.
- **tmux** (or herdr, experimental) for supervised sessions. A session you
  start by hand in your own terminal needs neither.

## What the installer places under `.claude/`

`npx github:JoMe92/nogging#v3.3.0 init` (or `update`) installs:

| Path | Behaviour |
| --- | --- |
| `.claude/commands/{plan,discovery-review,sync-now,orchestrate}.md` | The four **slash commands**, copied verbatim and tracked in the manifest. A locally modified file is preserved as `<file>.nogging-new` on `update`. |
| `.claude/agents/*.md` | The six **specialists**, copied the same way. |
| `.claude/settings.json` | **Merged, never replaced.** Nogging adds two `PreToolUse` hooks, each exactly once, and leaves every other setting and hook of yours untouched. |
| `templates/claude/orchestrator-permissions.example.json` | A permissions fragment for *interactive* Orchestration Agent sessions. It is never applied automatically; see [Authority levels](#authority-levels-and-effort). |

The merged `.claude/settings.json` wires:

- **`pre-tool-use-openspec-guard`**, matched on `Edit|Write`. It rejects a
  write under `openspec/` unless your own planning session lock is held, and
  prints a message naming the missing lock.
- **`pre-tool-use-lead-launch-guard`**, matched on `Bash`. It refuses a
  `scripts/nogg session launch --role lead` or `--role specialist:<type>`
  command for a Bead that still has an unmet `blocks` dependency, before the
  command runs. `session launch` makes the same check itself, so the hook is a
  fast Claude-only backstop.

Nogging also makes sure `CLAUDE.md` carries the managed Beads block and the
*Lead Agent delegation* section, so a Claude Code session loads the
instructions on start. The `bd prime` `SessionStart` hook that primes Beads
context comes from `bd init`, not from Nogging.

### The guard and what it does not cover

The `PreToolUse` guard is an early signal on the `Edit` and `Write` tools only.
It does not parse shell commands, so a write made through `Bash` is not caught
by it. The boundary for those is held by the layers beneath it:

1. the per-session `openspec/**` deny rules and, for supervised sessions, the
   OS mount fence applied at launch;
2. the filesystem write guard, the `.nogging/locks/openspec.readonly` sentinel
   that `plan-begin` and `plan-end` toggle;
3. the Git hooks: `pre-commit` refuses an `openspec/` change from a writer that
   is not the planning writer, and `commit-msg` requires the Bead ID token.

The Git hooks only run when Git reads them from `.git/hooks`. If
`core.hooksPath` points elsewhere, `init` warns you; see the
[installation guide](installation.md).

## The slash commands

| Command | What it does |
| --- | --- |
| `/plan` | Enter the Planning Agent persona and run one planning session end to end. |
| `/discovery-review` | Show every pending discovery (`scripts/nogg discoveries`) and triage it, without entering a planning session. |
| `/sync-now` | Run `scripts/nogg sync --now` instead of waiting for the 30-second timer tick. If the timer holds the sync lock, the command says so; do not loop and do not pass `--force`. |
| `/orchestrate` | Reach the always-on Orchestration Agent, or scope it to one takeover task. See [The Orchestration Agent](#the-orchestration-agent-and-remote-control). |

The persona and step text of the first three are the same on every runtime;
only the invocation surface differs. Each command is a thin wrapper over
`scripts/nogg`.

## Specialists and delegation

The Lead Agent implements a claimed Bead directly by default. It delegates to a
specialist only for genuinely isolated work, because delegating loses the
context the Lead already holds. Claude Code runs a specialist **in process
through the Task tool**, using the files in `.claude/agents/`:

| Specialist | Role |
| --- | --- |
| `architect` | Advisory: answers one design question and recommends one option. |
| `ui-ux-designer` | Advisory: turns a UI Bead into an interaction, layout and state specification. |
| `backend-engineer` | Implements the server, data or CLI side of one Bead. |
| `frontend-engineer` | Implements the client or UI side of one Bead, using any designer output. |
| `code-reviewer` | Advisory: reviews the diff for one Bead and ranks findings by severity. |
| `test-runner` | Runs the relevant tests, adds missing coverage for that Bead, edits tests only. |

All six use `model: inherit`, so a specialist runs on the model of the session
that called it.

The Lead passes the Bead ID, the task slice and the relevant spec excerpt in the
Task-tool prompt. A specialist returns a structured result and nothing else: it
never claims, closes or re-statuses a Bead, never commits, and never writes
`openspec/`. When it returns, the **Lead**:

1. validates the work in stages: the tests of the changed files while
   working, those tests plus lint of the changed files before each commit, and
   the affected suite once per Bead before closing it, leaving the full suite
   to CI (`scripts/test` once per Bead only where the project has no CI). A
   long command is one blocking `Bash` call with a `timeout` that covers it,
   or `run_in_background` with a wait for its completion notification, never
   a polling loop;
2. commits in coherent steps within the configured commit range
   (`./scripts/nogg task-sizing` prints it), each with a Conventional subject
   that carries the Bead ID token and the tests for the code it changes, adding
   a `Co-authored-by: <persona name> <persona email>` trailer for each
   specialist whose delegated work went into that commit;
3. writes the evidence note on the Bead, listing every commit SHA;
4. closes the Bead.

The persona names and addresses come from the `personas` key in
`.nogging/config.json`, so the trailer for the backend engineer uses the
`backend-engineer` entry. A plan-relevant finding from a specialist is recorded
by the Lead as a discovery on the Bead; if it blocks the task, the Lead marks
the Bead blocked. See the [operating model](operating-model.md) for the
delegation model across roles.

## Authority levels and effort

`session launch` runs a Claude session under a **launch profile**. A bare
`--profile` name resolves under `.nogging/launch-profiles/`.

| Level | Selected by | Permission mode | What it allows |
| --- | --- | --- | --- |
| **restricted** | default, or `--profile restricted` | `default` | Denies `git push`, `git remote`, `git config`, `bd sync`, `bd dolt push\|pull\|clone`, `dolt push\|pull\|remote`, `systemctl`, `chown`, `chmod -R`, `curl`, `wget` and `WebFetch`, plus the command floor. A restricted Lead stops at a committed local branch and reports. |
| **trusted** | `--profile trusted` or `--full-access` | `bypassPermissions` | Allows `git push`, `git merge`, `git switch`, `git rebase`, `bd`, `openspec`, `npx` and `scripts/*`. Denies only the command floor. |
| **orchestrator** | `--role orchestrator` | `bypassPermissions` | Unrestricted; see the next section. |

`--full-access` is shorthand for `--profile trusted --prompt autonomous`. The
`autonomous` prompt is what authorises a session to carry one named change end
to end; the default prompt makes no such claim, and claiming a Bead stays a
deliberate action.

A short **command floor** is merged into the deny list of every profile before
launch: `rm -rf`, `rm -fr`, `sudo`, `dd`, `mkfs`, `mkfs.*`, `shutdown`,
`reboot` and a fork bomb. For a Lead or specialist, the per-session deny rules
also fence `Edit`, `Write` and `MultiEdit` on `openspec/**`. The merged result
is written to `.nogging/state/sessions/<name>.settings.json`, and that file,
never the source profile, is passed to Claude.

This is a guard rail against an accident, not an operating-system sandbox. A
trusted session really can push and merge. The [security model](security-model.md)
states what each level does and does not protect.

### Model and effort

`--tier routine|standard|complex` takes the model and effort from the
model-selection table. For Claude, the model goes to `--model` and the effort
to Claude's native `--effort`:

| Tier | Model | Effort |
| --- | --- | --- |
| routine | `claude-sonnet-5-5` | `low` |
| standard | `claude-sonnet-5-5` | `high` |
| complex | `claude-opus-5-5` | `xhigh` |

An explicit `--effort` (`low`, `medium`, `high`, `xhigh` or `max` for Claude)
wins over a project `tier_overrides` entry, which wins over the table, which
wins over the profile and the runtime default. Run `scripts/nogg models --agent
claude --tier standard` to see the effective values. The
[model selection guide](model-selection.md) has the full precedence rules.

## The Orchestration Agent and Remote Control

The Orchestration Agent is **Claude Code only** in this version. It is a
separate always-on session, `nogg-orchestrator-<slug>`, kept alive by a systemd
user service and launched with `--remote-control`, so it appears in the Claude
app on your phone as a session you can read and type into, with no SSH.
Remote Control is switched on only for the orchestrator; a Lead or planner
session you launch is reached with `session log`, `session attach` or
`session send`.

```bash
scripts/nogg orchestrator status   # unit and linger state, the lock, the live session
scripts/nogg orchestrator restart  # bounce the service
scripts/nogg orchestrator stop     # stop and disable it and end the session
```

From the delivery host, read the session with `scripts/nogg session log
nogg-orchestrator-<slug> --follow`, or attach with `scripts/nogg session attach
nogg-orchestrator-<slug> --read-only`. If `status` shows the unit enabled but
linger off, run `loginctl enable-linger $USER` once so the service survives a
reboot without a login.

By default the orchestrator is **orchestrate-only**: it reads the whole state
and drives Planning and Lead sessions through `scripts/nogg`, and writes no
`openspec/` file and no implementation code. To have it do one task itself, type
one of these in the orchestrator session:

```
/orchestrate takeover plan <what to plan>
/orchestrate takeover code <bead-id or what to implement>
```

It does that one task and returns to orchestrate-only. It never signs an
acceptance report; that stays the Product Owner's act.

Its launch profile lifts the command floor and the `openspec/` fence. That is
keyed to `--role orchestrator`: a Lead or specialist that selects the same
profile still gets both. `session list` and `doctor` show such a session as
`FULL-ACCESS`. The safeguards are visibility, the append-only session log and a
single-instance lock, not a boundary. The [operating model](operating-model.md)
describes the role and its limits.

An *interactive* orchestrator session that you start yourself uses your own
user settings. `templates/claude/orchestrator-permissions.example.json` is a
fragment you can adapt into `~/.claude/settings.json`; allow rules in it do not
bypass Claude Code's auto-mode classifier.

## Resuming a run

Switching between agents mid-run is a supported interruption, and so is a
dropped session. The durable state (`git`, `bd`/Dolt, `openspec/` and
`.nogging/state/`) is not Claude-specific. On the next start, before `bd
ready`, run `./scripts/nogg recover` and resolve what it reports with the
[failure recovery guide](failure-recovery.md). To resume one exact Claude
conversation, pass its conversation ID: `scripts/nogg session launch --resume
<session-id>`. Nogging never resumes "the latest" conversation.

## Known limitations

- **The guard covers `Edit` and `Write` only.** Writes through `Bash` rely on
  the per-session fence, the sentinel and the Git hooks listed above.
- **Restricted is not a network sandbox.** For Claude it is a deny list of
  commands, not an operating-system boundary. A restricted session cannot push,
  but the list cannot enumerate every way to reach the network.
- **Cloud sessions.** A Claude Code cloud session's assigned `claude/*` branch
  is never a valid pull request source. Push the branch that `nogg worktree
  implement` or `worktree plan` allocated and open the pull request from that
  branch. A fresh cloud container also has no Beads database or Git hook path;
  the installation guide describes the opt-in bootstrap hook.
- **Auto mode.** Claude Code's auto-mode classifier can still refuse an action
  that a broad allow rule would otherwise permit, and a resumed session can
  keep auto mode instead of adopting a new default. See the
  [sessions guide](running-work-in-sessions.md).
- **The orchestrator is Claude only.** Remote Control is a Claude feature; a
  Codex or Pi orchestrator is a recorded follow-up.
- **No dedicated Claude CI job.** None is needed: the mechanical CI subset is
  agent-neutral.

## See also

- `AGENTS.md`: the canonical, tool-neutral instruction file, with a *Tool notes*
  section for each runtime.
- [Operating model](operating-model.md): roles, delegation and session
  supervision.
- [Running work in sessions](running-work-in-sessions.md): launch, watch, steer
  and clean up supervised sessions.
- [Installation](installation.md): the installer and everything it writes.
- [Compatibility](compatibility.md): the validated Claude Code version.
