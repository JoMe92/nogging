# Operating model

## Roles

- **Product Owner:** describes desired outcomes, decides ambiguities, accepts and archives changes.
- **Planning Agent:** works only in a deliberate planning session; writes OpenSpec and creates/reconciles Beads.
- **Main Worker:** selects `bd ready`, delegates isolated implementation work, validates, commits, records evidence and closes Beads.
- **Specialists:** work only on a claimed Bead and report results to the Main Worker.
- **Sync timer:** polls every 30 seconds and mirrors facts only.

## Branches and commits

`main` is the stable integration branch. `develop` is the active integration
branch. `main` and `develop` are protected and exempt from the branch-naming
convention below.

Every other working branch is named `<type>/<slug>`:

- `<type>` is one of `feat`, `fix`, `chore`, `docs`, `refactor`, `perf`,
  `test`, or `plan`. All but `plan` are Conventional Commit types; `plan` is
  reserved for a planning-session branch.
- A **change branch** — one that advances an OpenSpec change — MUST use that
  change's `openspec/changes/<slug>/` directory name as its `<slug>` (never
  `archive`). This is what makes the branch traceable to agreed intent. Any of
  the `<type>` values may front a change branch, e.g.
  `feat/photo-import-filesystem`.
- `chore/<topic>` and `plan/<topic>` cover work not scoped to a single change —
  tooling, multi-change planning. `<topic>` is a free kebab slug and needs no
  `openspec/changes/` match.

`scripts/check-branch-name <ref>` is the one implementation of this rule; the
`pre-push` hook and the CI `invariants` job both call it and neither re-encodes
it. A branch that does not match fails CI.

Use Conventional Commits, for example
`feat(import): add filesystem picker [SPEC-abc123]`.

Planning changes are committed on their change branch and merged into `develop`
after `./scripts/specforge validate`. A planning commit uses a Conventional
subject — `docs(openspec): …` or `chore(openspec): …` — plus a
`SpecForge-Writer: planning` trailer in the message body; the retired `plan:`
subject prefix is not a Conventional Commit type and must not be used. The
trailer is the durable, portable form of the `SPECFORGE_WRITER=planning`
exemption: the local `commit-msg` hook and CI honour it identically, so a
planning commit needs no Beads ID token but still needs the Conventional
subject.

The timer makes local commits only when there is a tracked execution-log
update; it never pushes. Its mirror commit is
`chore(sync): mirror Beads execution evidence` with a `SpecForge-Writer: sync`
trailer.

## Session supervision

Every Claude Code session SpecForge starts for Lead Agent or specialist work
runs inside a **named tmux session on the Pi**, under a dedicated tmux server
socket (`tmux -L specforge`) that is isolated from the operator's own tmux. The
session is started with `scripts/specforge session launch --role <lead |
specialist:<type>> --bead <id> [--cwd <path>] [--read-only]
[--profile <name-or-path>] [--prompt <name-or-path>] [--full-access]`, which:

- generates a collision-free name `sf-<role>-<bead>-<nonce>`;
- writes a durable JSON record to `.specforge/state/sessions/<name>.json`
  (Bead ID, role, host, start time, working directory, redacted launch
  command, owner, lifecycle state, log path) **before** the Claude process
  starts, so the association survives an SSH drop or a restart of the launcher;
- streams all console output to an append-only `<name>.log` beside the record
  (`tmux pipe-pane` → `scripts/session-log-writer`, size-rotated);
- starts Claude through `scripts/session-launch` under a **selectable launch
  profile**, defaulting to `restricted` (no `git push`, no remote Dolt sync,
  no destructive shell, scoped to the working directory) paired with the
  no-autonomous-claim system prompt.

`session launch` performs **no `bd` mutation**. Being launched is not
permission to start a Bead — claiming stays a deliberate in-session action the
operator directs.

### Launch profiles

`--profile <name-or-path>` and `--prompt <name-or-path>` choose the authority a
session runs under. A bare name resolves under `.specforge/launch-profiles/` /
`.specforge/launch-prompts/`; anything else is a filesystem path. With neither
flag the behaviour is exactly as before this existed: `restricted` +
no-autonomous-claim. Two profiles ship: `restricted` (the default) and
`trusted` (`acceptEdits`; allows `git push`/`merge`/`switch`/`rebase`, `bd`,
`openspec`, `npx`, `scripts/*`; still denies `sudo`, `systemctl`, `curl`/
`wget`, `WebFetch`). `--full-access` is shorthand for `--profile trusted
--prompt autonomous`, the pairing that authorises a session to execute one
named change end to end and fast-forward-merge it to `develop`.

A short **command floor** — `rm -rf`/`rm -fr`, `sudo`, `dd`, `mkfs`/`mkfs.*`,
`shutdown`, `reboot`, a fork bomb — is unioned into `permissions.deny` of
*every* profile (named, default, or a supplied path) before launch. No profile
can lift it. It is a guard rail against an accident or a prompt-injected
`rm -rf ~`, not an OS-level sandbox: a `trusted` session really can push and
merge, so the floor and the visibility are the safeguards, not a boundary
against a hostile agent.

The merged, floored settings are written per session to
`.specforge/state/sessions/<name>.settings.json` and that file — never the
source profile — is passed to Claude. The metadata record stores the profile
name and that path; `session list` shows the profile; `session cleanup`
removes the effective-settings file when it retires the record. A set
`session_launch_profile` / `session_launch_prompt` config key still wins over
the directory default.

From any plain SSH shell (no `TERM`, no tmux client needed):

| Command | What it does |
| --- | --- |
| `session list` | every managed session with Bead, role, age, working dir, owner, state, and the launch profile it runs under (`restricted` renders as `-`); reconciles each record against live tmux and reports a vanished `running` session as `failed`. Read-only, never attaches. |
| `session attach <name> [--read-only]` | attach the terminal to a session (`-r` blocks input). The only command that attaches. |
| `session log <name> [--follow]` | print or tail the append-only log without attaching. |
| `session stop <name> [--reason <text>]` | interrupt Claude, terminate the pane after the grace period, record `stopped` with `ended_at`/`exit_reason`. Idempotent. |
| `session cleanup [<name>]` | remove a lingering tmux session, archive-rotate the log, retire the record. **Refuses** a `starting`/`running`/`idle` record — stop it first. |

### Relationship to Task-tool specialists

The specialist roster (`specialist-agents-and-skills`) defines the six
specialists as **Task-tool subagents of the Lead Agent's session**. That is
still the default: when the Lead Agent delegates an isolated implementation or
review pass, it does so **in process** with the Task tool. Those calls do not
get their own tmux session or metadata record — they run inside the Lead
Agent's supervised session, share its launch profile, and are visible in
that session's own log.

A specialist run gets **its own observable tmux session** only when it must run
as a separate, long-lived Claude Code process — a large self-contained chunk of
work the operator wants to watch, attach to, or stop independently. The
operator (or the Lead Agent on operator direction) then runs `session launch
--role specialist:<type> --bead <id>`. Such a launched specialist still obeys
every specialist boundary rule: one already-claimed Bead, no `openspec/`
writes, no claim/close/commit, discoveries reported up to the Lead Agent.

## Discoveries

Agents record every material discovery on their active Bead using the native
Beads `discovery` label plus a required human-readable note:

```bash
bd update <id> --add-label discovery --append-notes "<prose summary>"
```

Execution agents never edit `openspec/`, so every discovery waits for the next
planning session (`bd list --label discovery`) and does not alter an approved
OpenSpec change automatically.

A discovery is **non-blocking** when the claimed task still finishes as
specified; the agent keeps working. It is **blocking** when the task cannot be
finished sensibly as specified; the agent also runs `--status blocked` and
moves to the next independent Bead. `/discovery-review` lists blocked
discoveries first so they do not get lost.
