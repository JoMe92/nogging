# Operating model

## Roles

- **Product Owner:** describes desired outcomes, decides ambiguities, accepts and archives changes.
- **Planning Agent:** works only in a deliberate planning session; writes OpenSpec and creates/reconciles Beads.
- **Main Worker:** selects `bd ready`, delegates isolated implementation work, validates, commits, records evidence and closes Beads.
- **Specialists:** work only on a claimed Bead and report results to the Main Worker.
- **Sync timer:** polls every 30 seconds and mirrors facts only.

## Delegation model and the Lead Agent knowledge path

The Main Worker session runs as the **Lead Agent** persona. It has full
read/write on Beads but **read-only** access to OpenSpec — only the Planning
Agent writes there. For each Bead the Lead Agent follows this path (section 7 of
the concept conversation):

1. `bd ready` — find available work.
2. `bd update <id> --claim` — claim one Bead.
3. `bd show <id>` — this returns the Bead's `openspec:task:<TASK-ID>` label (and
   `openspec:change:<name>`).
4. **Targeted context** — read only the one task line that
   `openspec:task:<TASK-ID>` resolves to in
   `openspec/changes/<name>/tasks.md`, plus the referenced spec excerpt under
   `specs/`. The Lead Agent does not read the whole `proposal.md` / `design.md`.
5. Read the code context from the repo itself.
6. **Decide: implement directly or delegate.** For genuinely isolated work the
   Lead Agent delegates to exactly one of the six specialists in
   `.claude/agents/` via the Task tool, passing the Bead ID, the task slice, and
   the spec excerpt. Delegating trivial work loses context, so it is the
   exception. `architect` and `code-reviewer` are advisory; `ui-ux-designer`
   produces a specification; `backend-engineer` / `frontend-engineer` implement;
   `test-runner` runs and extends tests.
7. Request tests and a review pass (`test-runner`, `code-reviewer`) as needed.
8. If a specialist surfaces a plan-relevant finding, the Lead Agent records the
   discovery (`bd update <id> --add-label discovery --append-notes "<prose>"`;
   `--status blocked` and move to the next independent Bead if it blocks). A
   specialist never labels or re-statuses the Bead itself.
9. Validate, write the evidence note with the commit SHA, commit with the
   `[<ID>]` token, and `bd close <id>`. The sync timer then mirrors the closure
   into `execution-log.md`.

A specialist owns none of steps 2, 8, or 9: claiming, closing, status changes,
the evidence note, and the commit stay with the Lead Agent. See the *Lead Agent
delegation* section of `CLAUDE.md` and the definitions in `.claude/agents/`.

The six specialists in `.claude/agents/` are a **Claude Code** mechanism — they
are Task-tool subagents and are not ported to Codex, and there is no MCP bridge
exposing them. A **Codex** Lead Agent has no in-process subagent mechanism, so
it either does the isolated work inline under the same constraints, or — when
the operator wants a separate observable process — starts one with
`scripts/specforge session launch --agent codex --role specialist:<type>
--bead <id>`. Either way every specialist boundary rule still holds: one
already-claimed Bead, no `openspec/` writes, no claim/close/commit, plan-relevant
findings reported to the Lead Agent as discoveries. `AGENTS.md` *Tool notes*
states the same.

## Commands

Three slash commands under `.claude/commands/` are the operator's entry points
into the workflow. Each is a thin, declarative wrapper over `scripts/specforge`
plus a persona instruction — they orchestrate existing primitives, they do not
reimplement the planning lock, discovery sorting, or sync.

| Command | May do | May **not** do |
| --- | --- | --- |
| `/plan` (`plan.md`) | Enter the Planning Agent persona and run one planning session in the fixed order: `plan-begin` → discovery review → design dialogue → author/revise the change → `validate` → commit `openspec/` as the `planning` writer → `materialize <change>` → `plan-end`. The commit precedes `materialize` so a crash between them never leaves Beads without a committed spec (`materialize` is idempotent). Consult the `architect` specialist for architecture questions. | Force a planning lock another session holds (report the holder and stop). Do any execution work. Auto-delete an orphaned Bead — stop and ask the Product Owner. |
| `/discovery-review` (`discovery-review.md`) | Run `scripts/specforge discoveries` and render it unchanged (blocking first). Per discovery, offer: carry into a `/plan` session, acknowledge via `scripts/specforge discoveries --ack <id>`, or leave pending. | Acquire the planning lock. Create or modify any file under `openspec/`. |
| `/sync-now` (`sync-now.md`) | Run `scripts/specforge sync --now`: signal a resident sync daemon if one exists, else run one reconciliation pass directly. | Retry, loop, or `--force` when the 30-second timer holds the sync lock — report the contention and stop. |

`AGENTS.md` keeps a one-line pointer to these files and the equivalent manual
`scripts/specforge` sequence, so a non-Claude tool can run the same steps by
hand. A Codex session invokes the same three commands from
`.codex/prompts/{plan,discovery-review,sync-now}.md`; see
[`using-with-codex.md`](using-with-codex.md) for the Codex specifics (the
`.codex/` payload, the execpolicy floor, the out-of-process specialist model,
and the known limitations).

## Resuming an interrupted run

A planning or development run can stop mid-way — the token budget runs out, the
process crashes, the SSH session drops, or the operator switches tools (Claude
Code ↔ Codex). On the next start, every session — fresh, resumed, or
tool-switched — runs `./scripts/specforge recover` **before** `bd ready`.
`recover` is a read-only diagnostic: it reports stale/held locks,
committed-but-not-closed (`LIMBO`) Beads, `in_progress` Beads classified
`resumable` / `stale` / `active`, a materialized-but-uncommitted change (with
any leftover `materialize-<change>.json` journal), orphan Beads, crashed
session records and the working-tree state, and exits non-zero when any of
those needs a decision. The agent then resolves each item with the playbook in
[`failure-recovery.md`](failure-recovery.md) § "Resuming an interrupted run" —
in particular, a `LIMBO` / `resumable` Bead's work is already done and is
verified-and-closed, never re-implemented. `AGENTS.md` § "Resuming a run" states
the protocol tool-neutrally; `doctor` also prints a one-line `recover` summary.

## Branches and commits

`main` is the stable integration branch. `develop` is the active integration
branch. `main` and `develop` are protected and exempt from the branch-naming
convention below.

Every other working branch is named `<type>/<slug>`:

- `<type>` is one of `feat`, `fix`, `chore`, `docs`, `refactor`, `perf`,
  `test`, or `plan`. All but `plan` are Conventional Commit types; `plan` is
  reserved for a planning-session branch.
- A **change branch** — one that advances an OpenSpec change — MUST use that
  change's directory name as its `<slug>`, matching a live
  `openspec/changes/<slug>/` or an archived
  `openspec/changes/archive/<date>-<slug>/` (so a branch opened before the
  change was archived does not start failing; never the literal `archive`).
  This is what makes the branch traceable to agreed intent. Any of the `<type>`
  values may front a change branch, e.g. `feat/photo-import-filesystem`.
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

## Acceptance

A change is not **accepted** just because its Beads are closed and CI is green.
Acceptance is an explicit, human act recorded in a signed report.

`docs/acceptance.md` is the reproducible end-to-end procedure — from an empty
git repository through install, planning, materialize, a simulated execution,
mechanical sync and discovery review. Every step is tagged `[M]` mechanical
(reproduced by `scripts/acceptance.sh`, also run as the `acceptance` CI job) or
`[A]` agent-driven. Each run is written up from
`docs/acceptance-report-template.md` into a dated report under
`docs/acceptance/<YYYY-MM-DD>-<hostname>.md`, recording a pass / fail / skipped
result for every step, any deviations, and every discovery filed during the run.

The report is committed with its `Signed-off-by:` line blank; the Product Owner
completes that line in a separate commit. **A change is not accepted until a
signed report exists.** A green `acceptance` CI job is necessary but not
sufficient — the `[A]` steps and the sign-off are the rest.

## Archived changes

When the Product Owner archives a completed change, `openspec archive <name>`
moves it to `openspec/changes/archive/YYYY-MM-DD-<name>/`. Its Beads stay closed
in the tracker, still carrying their `openspec:change:` / `openspec:task:`
labels. This is supported and does not break the mechanical layer:

- `./scripts/specforge validate` (and `doctor` / `audit`) read the archived
  `tasks.md` too — an archived-inclusive `task_map` mode strips the date prefix
  back to the original change name — so a closed Bead mapping to an archived
  task still resolves instead of reporting a missing task or a disagreeing
  change label. Archived `tasks.md` files are frozen, so the "checked task has a
  closed Bead" reverse check is skipped for them.
- `materialize` and `sync` keep acting only on live changes. They never create
  Beads for, or write files into, an archived directory.

So a completed change can be archived at any time; its history stays auditable
and the audit stays clean.

## Session supervision

Every agent session SpecForge starts for Lead Agent or specialist work runs
inside a **named tmux session on the Pi**, under a dedicated tmux server socket
(`tmux -L specforge`) that is isolated from the operator's own tmux. The session
is started with `scripts/specforge session launch --role <lead |
specialist:<type>> --bead <id> [--cwd <path>] [--read-only]
[--agent <claude|codex>] [--profile <name-or-path>] [--prompt <name-or-path>]
[--full-access]`, which:

- generates a collision-free name `sf-<role>-<bead>-<nonce>`;
- writes a durable JSON record to `.specforge/state/sessions/<name>.json`
  (Bead ID, role, host, start time, working directory, redacted launch
  command, owner, lifecycle state, log path) **before** the Claude process
  starts, so the association survives an SSH drop or a restart of the launcher;
- streams all console output to an append-only `<name>.log` beside the record
  (`tmux pipe-pane` → `scripts/session-log-writer`, size-rotated);
- starts the selected agent through `scripts/session-launch` under a
  **selectable authority level**, defaulting to `restricted` (no `git push`, no
  remote Dolt sync, no destructive shell, scoped to the working directory)
  paired with the no-autonomous-claim system prompt.

`session launch` performs **no `bd` mutation**. Being launched is not
permission to start a Bead — claiming stays a deliberate in-session action the
operator directs.

### The agent is selectable

`--agent {claude,codex}` chooses the binary; with no flag it reads the
`session_agent` key from `.specforge/config.json`, default `claude`, so no
existing install changes behaviour. The record stores the agent and
`session list` shows it in an `AGENT` column. `--agent claude` and the default
are byte-for-byte the previous launch — the same settings file, prompt and
effective-settings write.

The `restricted` / `trusted` authority levels are **tool-neutral** and resolve
per agent: for `claude` to the existing `.specforge/launch-profiles/<level>.json`
settings file; for `codex` to `.specforge/launch-profiles/<level>.codex.toml`,
mapped onto Codex's model — `--sandbox workspace-write`, `--ask-for-approval`
`on-request` (`restricted`) or `never` (`trusted`), and network access off.
A Codex session has no per-session `permissions` file; its command floor is the
repo's `.codex/rules/` execpolicy directory (shipped by `codex-onboarding`),
and `session launch` warns when that floor file is missing but still starts.
`--full-access` maps to `trusted` + `autonomous` for whichever agent is in use.

### Launch profiles

`--profile <name-or-path>` and `--prompt <name-or-path>` choose the authority a
session runs under. A bare name resolves under `.specforge/launch-profiles/` /
`.specforge/launch-prompts/`; anything else is a filesystem path. With neither
flag the behaviour is exactly as before this existed: `restricted` +
no-autonomous-claim. Two profiles ship: `restricted` (the default) and
`trusted` (`acceptEdits`; allows `git push`/`merge`/`switch`/`rebase`, `bd`,
`openspec`, `npx`, `scripts/*`; still denies `sudo`, `systemctl`, `curl`/
`wget`, `WebFetch`). Each has a `<level>.codex.toml` sibling for a Codex launch
(see *The agent is selectable*). `--full-access` is shorthand for `--profile
trusted --prompt autonomous`, the pairing that authorises a session to execute
one named change end to end and fast-forward-merge it to `develop`.

A short **command floor** — `rm -rf`/`rm -fr`, `sudo`, `dd`, `mkfs`/`mkfs.*`,
`shutdown`, `reboot`, a fork bomb — is unioned into `permissions.deny` of
*every* profile (named, default, or a supplied path) before launch. No profile
can lift it. It is a guard rail against an accident or a prompt-injected
`rm -rf ~`, not an OS-level sandbox: a `trusted` session really can push and
merge, so the floor and the visibility are the safeguards, not a boundary
against a hostile agent.

For a Claude session the merged, floored settings are written per session to
`.specforge/state/sessions/<name>.settings.json` and that file — never the
source profile — is passed to Claude. The metadata record stores the profile
name and that path; `session list` shows the profile; `session cleanup`
removes the effective-settings file when it retires the record. A Codex session
writes no such file (its `effective_settings_path` is null) — the floor is the
`.codex/rules/` directory. A set
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

A specialist run gets **its own observable tmux session** when it must run as a
separate, long-lived process — a large self-contained chunk of work the operator
wants to watch, attach to, or stop independently. The operator (or the Lead
Agent on operator direction) then runs `session launch --role specialist:<type>
--bead <id>`, adding `--agent codex` for a Codex specialist. For Codex this is
the *only* delegation path — it has no in-process subagent mechanism, so an
isolated slice is either handled inline or split out as its own session. Such a
launched specialist still obeys every specialist boundary rule: one
already-claimed Bead, no `openspec/` writes, no claim/close/commit, discoveries
reported up to the Lead Agent.

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
