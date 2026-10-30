# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/). Entries
before `v1.6.0` are not retroactively reconstructed here; see the Git tags
and GitHub Releases for that history.

## [Unreleased]

### Added

- Launch-mode loops: a fresh, bounded `loop` session per run with the loop's
  exact agent, tier and authority, stopped and retired when it finishes or
  passes `max_runtime`. `init` and `update` render
  `nogg-loops-<slug>.service` and `.timer`, and `doctor` reports the timer, a
  stalled tick and unapproved, suspended or stale loops.
- `nogg loop add`, `list`, `show`, `log`, `pause`, `resume`, `approve` and
  `remove` for managing host-approved recurring work, with atomic host state,
  hash-bound approvals, orchestrator guidance and the scheduled-loops guide.
- `nogg session signal blocked|done "<reason>"` lets a supervised Lead state
  the end of its work as a fact (allowed in the restricted profile, no network
  or Dolt); `session watch` reports it as its own event.
- Session events use one normalized schema with a field whitelist, redacted
  one-line excerpts and rotation at 256 KiB. Claude's launch settings now also
  wire `UserPromptSubmit`, `StopFailure` and `SessionEnd`, and Codex turns are
  read from the rollout with no hook install.
- Supervised Pi sessions load `.pi/extensions/nogging-lifecycle.ts`, which
  reports `agent_start`, `agent_settled`, extension prompts and shutdown through
  `session emit`, so Pi reads `working`, `idle` or `needs_input` in `watch`
  instead of `unknown`. It does nothing outside a supervised session, never
  uses `agent_end` as completion, and a missing file only warns at launch.

### Changed

- `session watch` also reads herdr's `agent_status` (`blocked` is a question,
  `done` is idle, `unknown` proves nothing), between the rollout and the pane.
- `session watch` classifies every agent from one evidence order (structured
  event, Codex rollout, pane adapter): an idle event yields to a pane that is
  working, a Claude session no longer reads `idle` during a later turn, and
  only question notifications (not `idle_prompt`) count as `needs_input`.

## [3.4.0] - 2026-10-30

### Fixed

- `token-usage report`, `session`, `export` and `status` no longer hang or
  fail with "local Dolt could not run" on a large usage store. Current facts
  are read from the base tables instead of the `current_*` views, which Dolt
  evaluates quadratically (77 s to 3 s for 6,430 usage events in one consumer
  store); `status` counts facts without loading them; every read query is
  bounded by the new `token_usage_query_timeout_seconds` (default 30) and a
  timeout says so and names the remedy.

### Added

- `nogg token-usage report --group-by bead` (and a `--bead` filter): fresh
  input, cache read, cache write, output and total tokens per Bead and
  runtime, plus the Bead's commits, production lines and tokens per
  production line from its `[<bead-id>]` commits (tests, `openspec/`,
  `.beads/` and lockfiles excluded). `docs/token-usage.md` documents it as
  the efficiency metric: fresh input and output per line are the cost of the
  work, cached re-reads show waiting and context growth.
- `nogg validate` also notes open tasks whose `[~N loc]` estimate is above the
  configured `bead_prod_lines` maximum without a reason, mirroring the minimum
  note. A note never fails `validate`.
- `nogg run-quiet [--log PATH] [--tail N] -- <command>` runs a long command
  (a suite, a build) as one blocking call: one `ok:` line on success, a
  `FAIL (exit N)` line plus the log tail on failure, the full output in a
  private log (removed after a passing run unless `--log` names it) and the
  exit code passed through. It applies the command floor and the calling
  session's own `Bash(...)` deny rules to the wrapped command, at any word
  position and inside `<shell> -c` scripts, and masks credential-looking
  values in the printed command.
- `doctor_agy_models_cache_seconds` (default 3600): `doctor` reuses a
  successful `agy models` listing per `agy` executable instead of spawning
  the probe on every run; a failed probe is never cached.

### Changed

- Planning splits a task above the configured Bead maximum; a task outside
  the range states its reason in the tag. `docs/configuration.md` records the
  measured sweet spot: 500–1000 production lines per Bead cost the fewest
  tokens per line, and a maximum far above it costs more per line.
- `nogg doctor`, `validate` and `usage` read the Codex rollouts
  incrementally: a per-root byte-offset index under the usage cache means
  only appended bytes are parsed, with the same result and damaged-line
  report as a full scan. On the delivery host a warm `doctor` fell from
  about 44 s to under 4 s and `usage --agent codex` from about 20 s to about
  1 s.
- Sharper test stages: before each commit only the tests of the changed files
  plus lint of those files; once per Bead the affected suite; the full suite
  is CI's job (`scripts/test` once per Bead only where a project has no CI).
  The same wording runs through `AGENTS.md`, `CLAUDE.md`, the shipped blocks,
  the launch prompts, `/orchestrate`, the specialists and the docs.
- No polling: Leads and specialists run a long command as one blocking call
  with a timeout or yield that covers it and never poll it. `AGENTS.md` adds
  per-runtime notes (Claude Code `timeout`/`run_in_background`, Codex
  `yield_time_ms` and one long `write_stdin` wait, Pi). In one consumer
  project half of all Codex tool calls had been such polls.

## [3.3.0] - 2026-10-28

### Added

- `task_sizing` in `.nogging/config.json` (`bead_prod_lines`, default
  400–1000 production lines per Bead; `commit_lines`, default 100–600 lines
  per commit) and `nogg task-sizing`, which prints the ranges in effect.
- `nogg validate` notes open tasks whose `[~N loc]` estimate is below the
  configured minimum without a reason, and changes whose open tasks mostly
  carry no estimate. A note never fails `validate`; existing changes stay
  valid.
- Security guidance for public projects: `docs/security-model.md` and the
  FAQ explain why a Beads remote must stay private and how to configure it
  safely, naming the `__dolt_remote_info__` table and recommending the seed
  commit be authored locally (#306).
- A troubleshooting page with symptom-cause-fix entries for the most common
  operational failures (#311).

### Changed

- Planning writes each task as a vertical slice delivering one testable
  capability (backend, API, UI and docs together) in the configured Bead
  range, with a `[~N loc]` estimate; a smaller task states its reason.
- Leads commit a Bead in several coherent commits within the configured
  commit range, each carrying the `[<bead-id>]` token with its tests; the
  evidence note lists every SHA.
- Staged testing replaces "always the full suite": affected tests while
  working, the affected suite plus lint before each commit, the full suite
  once per Bead. CI stays the final gate.
- In a repository Nogging is installed into, `scripts/test` runs only that
  repository's own tests; Nogging's shipped self-tests run with
  `NOGG_SELFTEST=1 scripts/test`. The Nogging repository runs everything.
- `recover` and `validate` LIMBO lines show how many commits carry a Bead's
  token, and the recovery playbook treats a LIMBO or `resumable` Bead as
  possibly partial work (#313).
- `docs/usage-limits.md` rewritten around `nogg usage`, including how to
  install the statusline capture wrapper with `nogg usage
  install-statusline` (#312, Refs #280).

### Fixed

- `scripts/nogg.test.sh` and `scripts/session-observability.test.sh` no
  longer read the operator's real `~/.codex` after a scenario that unset
  `CODEX_HOME`; on the delivery host that cost about 90 s per run.
- The docs-site guard test derives the owner-surname check from a hash so
  the surname itself stays out of the repository (#310).

## [3.2.0] - 2026-10-27

### Added

- A branded documentation site: the Just the Docs theme in Nogging colours
  with light and dark mode, self-hosted Poppins for the wordmark and
  headings, a landing page with a pinned quick start, sidebar sections and
  search, and new pages: Your first change, Claude Code guide, command
  reference, configuration reference and glossary. Internal pages are
  excluded from the site (#281 #288 #289 #291 #292 #293 #294 #296).
- An offline docs-site test suite (`scripts/docs-site.test.sh`) and a
  container build for the site (`scripts/docs-site-build`) (#289 #293).
- `THIRD_PARTY_NOTICES.md` carries the full MIT texts for the OpenSpec and
  Beads skill material and entries for Poppins (OFL 1.1) and Just the Docs
  (MIT) (#293).
- Pi can run on the herdr backend (#299).
- How to watch all herdr sessions at once with `herdr --session nogging`
  (#303).

### Changed

- The owner surname removed from `LICENSE` and `package.json`; the copyright
  holder is now "Jonas (JoMe92)" (#279).
- Agent Console sibling-project references removed (#287).
- Internal groundwork for scheduled loops (no user-facing command yet).

### Fixed

- Documentation consistency: pinned installer lines, stale facts and
  internal IDs removed (#291).
- Session logs stay readable when log rotation splits a UTF-8 character;
  rotation now cuts on character boundaries (#304).

## [3.1.1] - 2026-10-26

### Added

- `docs/` is now a Jekyll GitHub Pages site (`docs/_config.yml`), with new
  `docs/faq.md` and `docs/comparison.md` pages.
- `CITATION.cff` for citing Nogging, and a Discussions contact link in the
  issue template.
- A square social card, `docs/brand/nogging-social-card-square.png`
  (1080x1080).

### Changed

- New tagline "Structure for a team of agents." across the README banner,
  the social card and the logo.
- `package.json` description and keywords and `docs/project-identity.md` are
  aligned with the new GitHub description and 20 topics.
- README reworked for first-time visitors: keyword intro, badges, "Why
  Nogging?", "How it compares", FAQ, image alt texts and a Discussions link.
- Stale private-repository and 2.0.x statements removed from the docs.

### Security

- `zod` updated to 4.6.7, clearing GHSA-mrhx-c7xc-m3w5.
- `actions/setup-python` updated to v7.1.0.

## [3.1.0] - 2026-10-21

### Added

- Project effort overrides: a `tier_overrides` block in `.nogging/config.json`
  changes the effort of one tier and agent (Claude, Codex) with precedence
  explicit `--effort` > override > table. `models` shows `(project; table X)`,
  `session list` shows `(project)`, `models check` validates the block, and
  `doctor` NOTEs a malformed or redundant override. Apart from the Codex
  complex default listed under Changed, the shipped table is unchanged.
- `nogg worktree rebase` brings an implementation branch up to date with
  `origin/develop` on the side that can write `openspec/` (directly when
  unfenced, through the sandbox broker for a fenced Lead), with ordered
  refusals, a journal, a backup ref and `--continue`/`--abort`: an `openspec/`
  conflict aborts with the tree proven unchanged, a code-only conflict pauses
  (exit 3).
- A read-only worktree-integrity classifier reported by `doctor` and `recover`,
  and `nogg worktree repair <record> [--apply]` to restore a half-applied
  checkout (#241) without losing local edits.
- `scripts/hooks/pre-rebase` refuses a raw `git rebase` or `git pull --rebase`
  that would replay an `openspec/` change onto a read-only tree; the launch
  prompts tell Leads to use `nogg worktree rebase`.

### Changed

- The shipped Codex `complex` default is now `gpt-6.1-sol` at effort `low`
  (was `high`; `table_version` `2026-10-19`). The Claude defaults are
  unchanged. A project that wants the previous effort sets it with a
  `tier_overrides` entry.

### Fixed

- `init` and `update` install every packaged file with the executable bit it has in the package, not only the files named in an installer list. `scripts/session-pty-recorder` was created non-executable by an upgrade from `v2.2.0`, which made `doctor` fail its session-helper check (#263). A managed file that already has the packaged content but lost the bit is repaired by the next `update` (reported as `update`, `mode 0755`); `--dry-run` reports it without changing the file; `<file>.nogging-new` and `--force` overwrites are executable, and `<file>.orig` keeps the mode of the local file.

- `scripts/test` no longer goes red when the host `.nogging/config.json`
  selects the `herdr` session backend (#264): fixtures that copy the host
  config now pin the scratch repository to `tmux` through the shipped
  `scripts/lib/test-fixture-config.sh` helper, and
  `scripts/fixture-backend-pin.test.sh` runs the affected suites under a herdr
  host config.

## [3.0.0] - 2026-10-18

Upgrade notes: run `npx github:JoMe92/nogging#<new-tag> update` from each
installed repository. Since `update` now keeps locally modified managed files,
look for `<file>.nogging-new` files afterwards (`./scripts/nogg doctor` lists
them), merge what you want, and delete them; `update --force` instead
overwrites the file and keeps your copy as `<file>.orig`. Launch automation
that starts Codex or Antigravity planning sessions must now name an authority
(`--profile trusted`, `--profile restricted` or `--full-access`). Roll back to
`v2.2.0` only after every usage reservation is released (no active supervised
sessions), because `v2.2.0` cannot read the new reservation entries; see
`docs/failure-recovery.md`.

### Added

- **Safe session launch and Codex delivery guidance.** Document backend-safe
  session names, cleanup after failed launches, Codex paste-placeholder and
  startup-turn handling, busy-queue refusal, planner process identity recovery,
  and updating older vendored Nogging copies.
- **Codex `--effort` and the tier/model/effort combination.** `session launch --effort <level>` now works for Codex sessions, validated against Codex's reasoning-effort set and forwarded to the CLI. `--tier`, `--model` and `--effort` combine with a documented precedence (explicit flag over tier over profile), and `docs/model-selection.md` records the Product Owner cost policy: `gpt-6-luna` by default, `gpt-6.1-sol` only at low effort for extremely hard tasks.
- **Installer preflight.** `init` and `update` run an advisory host preflight that reports missing prerequisites before changing anything, without blocking the install.
- **Grouped installer output and numbered next steps.** `init`, `update` and `remove` group their output by file class with per-class counts, show each path once, collect preserved and forced files into a single review block and deduplicate warnings (`--verbose` lists every file). They end with a numbered next-steps block (required before optional) and a normalized readiness verdict that points to `/plan` when ready; `npx ... doctor` prints the report once, then the same verdict.
- **A rewritten README.** It leads newcomers from purpose to daily use and presents `v3.0.0` as the first public release, with every install command pinned to it.
- **A switchable, experimental session backend with herdr.** `session_backend: tmux|herdr` in `.nogging/config.json` and `session launch --backend` choose where a supervised session runs; `tmux` stays the default and recommended backend, and the Orchestration Agent stays on it. The herdr backend adds a PTY-recorded, size-rotated session log, a live `AGENT_STATUS` column in `session list`, `session herdr-server start` to start or verify the dedicated server, conditional `doctor` herdr checks and a setup guide (`docs/using-with-herdr.md`). Mixed backends run side by side, and `list`, `reap`, `stop`, `cleanup`, `attach` and `send` follow each record's own backend.
- **Codex exact resume.** `session launch --resume <thread-id>` now works for Codex sessions, through `codex resume <id>` inside the normal launch wrapper.
- **Reliable session input.** `session send`, `nudge` and `kickoff` paste with explicit bracketed paste (multiline text arrives intact), wait `session_submit_delay_seconds` before one Enter, and verify the submission by default for Claude, Codex and Antigravity. Codex queue delivery is checked against fresh receipts from the exact thread; a message that cannot be positively verified fails as unverified instead of reporting success, and is never silently re-queued. Kickoff waits for startup readiness (`session_startup_timeout_seconds`); the new `session_submit_delay_seconds`, `session_submit_verify_delay_seconds` and `session_delivery_timeout_seconds` keys are validated.
- **`nudge --message` replaces pending input completely.** It clears wrapped pending input row by row, checks the composer is empty, and submits only when it then holds exactly the message, on both backends.
- **`orchestrator restart` relaunches the agent.** It ends the live orchestrator session before restarting the unit, so the new supervisor starts Claude under the current prompt and settings and resumes the prior conversation. `--supervisor-only` keeps the old unit-only restart, and a restart from inside the orchestrator session is refused.
- **Launch-path fail-fast.** `session launch` checks that the agent binary resolves before any side effect, and fails non-zero with the startup-log tail when the session dies within a short settle window instead of printing a success summary.
- **Antigravity can search the web.** The `agy-guard` hook accepts `search_web` with a non-empty `query` (allowed under `trusted`, asks under `restricted`), and every denial now names its cause and the tool.
- **Usage visibility.** A missing usage source carries a remediation hint (`run nogg usage install-statusline` for Claude), shown by `nogg usage`, the launch warning and `doctor`. A launch admitted with unknown usage prints a prominent `WARN`, and `doctor` prints a NOTE explaining `usage_gate.on_unknown: "deny"`. The default stays `warn`. An unset Antigravity model reports `no model selected; pass --model <id>`, and a drift guard keeps the model-selection table mapped to a `/usage` group.
- **Installer change tracking.** `.nogging/installed-manifest.json` records SHA-256 digests of installed verbatim and documentation files, with baselines for `v2.1.0` and `v2.2.0` so installs without a manifest upgrade conservatively. `update` and `init` accept `--force`, `--dry-run` distinguishes preserved from overwritten files, `doctor` reports pending `<file>.nogging-new` files, and `remove` cleans the manifest.
- **A stable, versioned usage reservation format.** Reservation entries carry a schema version; readers keep valid accounting, never probe or reap an entry they do not understand, and refuse admission with a clear message when the ledger cannot be understood. `docs/failure-recovery.md` documents ledger recovery and rollback.
- **Test isolation.** `scripts/lib/test-env.sh` strips inherited `NOGG_*` and `NOGGING_ROOT` before any test runs, so direct test invocations no longer pick up a supervised session's identity, authority or task-tick broker. It ships with the other test helpers.

### Changed

- **BREAKING**: `update` (and re-running `init`) no longer overwrites a locally modified managed file. It keeps your file and writes the new upstream content to `<file>.nogging-new` with a warning. Automation that ran `update` to reset local edits now keeps them. **Migration:** pass `--force` to overwrite them (the previous file is saved as `<file>.orig`), or merge the `.nogging-new` file by hand and delete it.
- **BREAKING**: a Codex or Antigravity planning launch without `--profile` or `--full-access` is refused before any side effect, with a message naming the options. A command line that `v2.2.0` accepted now exits non-zero. **Migration:** add `--profile trusted`, `--profile restricted` or `--full-access` to the launch. Every launch now prints its effective profile.
- **BREAKING**: usage reservation entries are backend-neutral and versioned, and `v2.2.0` crashes on them with `KeyError: 'tmux'`. This makes the documented rollback ("run `update` from the exact preceding tag") unsafe while reservations exist. **Migration:** release every reservation, or wait for active sessions to end, before rolling back to `v2.2.0`; never split the ledger or delete live reservations (`docs/failure-recovery.md`).
- **Planning close order.** A planner now runs `plan-end` from its planning worktree while that worktree and its sandbox still exist, and retires the worktree last, from the surviving canonical checkout. All planning surfaces state the new order and use `openspec validate <change> --strict --no-interactive`. `session stop` waits, within its grace period, for the planner to exit and then releases the lock without `--force`.
- **Orchestrator state is read from the main checkout.** The orchestrator lock, singleton session name and systemd unit name resolve the same way from any worktree, so `recover`, `orchestrator status` and `doctor` report the real holder. `orchestrator run` in a linked worktree is refused. The lock's staleness is bound to the holder's liveness (PID, start time and PID namespace): a verified-alive holder is never stale, however old the lock.
- **`task-done` ticks the requesting checkout.** The sandbox broker ticks the `tasks.md` of the registered worktree that asked, and refuses anything else; an older broker that rejects the request is reported as needing a session relaunch rather than retried without the checkout.
- **Launch dependency check counts only blocking edges.** Only `blocks` (or untyped) dependency edges are unmet dependencies, in both `session launch` and the Lead launch guard; a `parent-child` link to an open epic no longer blocks a ready task.
- **Claude Stop and Notification hooks use an absolute path** resolved at launch, so `turn_end` and `needs_input` events are no longer lost after the agent changes directory.
- **Codex launch flags match the current CLI.** `--add-dir` is omitted for read-only launches, and `ask_for_approval = "untrusted"` is rejected during preflight (accepted values: `on-request`, `never`).
- **Codex usage observations stay valid until each window resets.** An aged observation is marked stale but still gates, so a known window over its cap denies the launch instead of being discarded as `unknown`.
- **Cleanup is safer.** `session cleanup` stops the dedicated tmux server only when it hosts no session, and removes only herdr panes that this checkout's records name. `worktree cleanup` refuses, before deleting anything, a worktree that is a mount point, contains the caller's current directory, or is another active session's working directory. A caller inside the OpenSpec sandbox never starts the shared tmux server (the launch is refused and points to an unsandboxed launch), and a server living in another namespace is reported by `doctor`, `session list` and `orchestrator status`.
- **Session logs are byte-bounded.** `session-log-writer` appends output as it arrives without waiting for a newline, keeps memory and every log generation within `session_log_max_bytes`, and `session cleanup` archives every rotated generation (both backends).

### Fixed

- A Codex planner could not run `plan-end` once its planning worktree was retired, and `worktree cleanup` could delete tracked files before failing with `Device or resource busy`.
- A day-old `orchestrator.lock` with a live holder read as stale and halted autonomous Lead sessions.
- A usage reservation written by a newer Nogging could make an older reader fail or reap a live entry; entries of an unknown version are now retained without probing.
- Antigravity's permanent status bar was mistaken for pending input when verifying a nudge, and a Codex pane message was reported as delivered without verification.
- Mixed-version and direct test invocations inherited the calling session's identity and could send fixture task ticks to the operator's live broker.

## [2.2.0] - 2026-10-11

### Added

- A fourth supervised agent runtime, **Google Antigravity (`agy`)**: `session launch --agent antigravity` (alias `agy`), `.agy.toml` launch profiles with model forwarding and exact-conversation resume, a fail-closed command-floor/`openspec/` write-boundary guard, a `session watch` pane adapter (working/idle/needs_input/limit), and three workflow skills (`nogging-plan`, `nogging-discovery-review`, `nogging-sync-now`). Shipped through the normal init/update/remove payload; `doctor` NOTEs when `agy` is absent or the repo isn't yet trusted.
- **Researched model/effort selection**: a shipped `.nogging/model-selection.json` rule table (`routine`/`standard`/`complex` tiers × Claude/Codex/Antigravity) and `scripts/nogg models` to print/validate it; `session launch --tier <tier>` resolves the table, with an explicit `--model`/effort override still taking precedence over the tier, and the tier over the profile.
- **Claude reasoning effort**, matching what Codex already had: optional `effort` in Claude launch profiles, `session launch --effort <level>`, forwarded through the wrapper as Claude's native `--effort` (including exact-conversation resumes), with the selection and its source recorded and shown in session listings.
- **Pre-launch usage gating**: `nogg usage --agent ... --json`, a quota-aware admission check that exits `75` when a launch would exceed a configured cap, atomic same-host concurrent reservations so two simultaneous launches can't both spend the last slot, an opt-in Claude statusline composition, and bounded learned per-agent/model usage estimates for when live quota data is unavailable.
- **Cross-session token usage tracking**: `nogg token-usage collect/report/session/export/status` persists attributable input/output/cache/thinking token counts, runtime, provider, model and task complexity for Claude, Codex and Antigravity sessions into a Nogging-owned sibling Dolt store (separate from Beads), with hourly/daily/session grouping, arbitrary time filters, and an explicit opt-in multi-device sync command.
- An interactive, whiptail-based `scripts/bootstrap` wizard: a welcome screen, an install-path prompt, an optional-components checklist, a guided GitHub/Claude Code/Codex login step, and a closing summary — the fully-automated, non-interactive path is unchanged and remains the default outside a real TTY.
- `scripts/nogg session launch` now refuses to start a Lead/specialist session whose Bead has an unmet, already-recorded dependency, naming the blocking Bead; a matching Claude-only `PreToolUse` hook catches the same case one step earlier. `doctor` also flags a currently-running session whose Bead became blocked after it started.
- `scripts/nogg session kickoff`/`--kickoff`, `scripts/nogg session nudge` (clear a stale/unsent pane input and resubmit it, or an explicit message), a new `awaiting_manual_approval` pane state for Claude, and `scripts/nogg session sweep` (flags `change-complete`, `bead-blocked`, or `has-unsent-input`) — surfaced together by `doctor`.
- A supervised `--role planning` session: it owns and releases the planning lock itself, gets role-specific kickoff and scoped orchestration permissions, while execution sessions stay fenced from `openspec/`.
- A validated `agent_state_roots` config key granting a Codex session specific agent-runtime state directories (e.g. Antigravity's), replacing the interim `NOGG_CODEX_EXTRA_WRITABLE_ROOTS` env var; an offline-by-default Codex sandbox diagnosis in `doctor` (deeper probes under `doctor --sandbox`).

### Changed

- The `trusted` launch profile's `permissions.defaultMode` is now `bypassPermissions` (was `auto`): `auto` silently fell back to fully manual when Claude's classifier was unavailable, exactly the unattended-reliability gap `--full-access` is supposed to close. The existing `deny` list is unchanged.

### Fixed

- A repository missing the session-launch wrapper or log-writer (common right after a fresh install) could fail a supervised agent before its first turn; `init`/`update` now ship and refresh both and preserve a startup error durably before tmux can discard the pane.
- One Bead with an incomplete OpenSpec label pair used to abort materialization and sync mirroring for every other, unrelated change; mapping failures are now quarantined to the affected change.
- Worktree-local ignored state could make discovery acknowledgements disappear after a sync and let the Pi guard treat the `openspec/` write boundary as open from a linked worktree; both now resolve their canonical location from the shared repository.

## [2.1.0] - 2026-10-03

### Added

- `scripts/nogg session watch`: agent-neutral session-state observability for
  Claude Code and Codex sessions (`working` / `waiting_background` / `idle` /
  `needs_input` / `limit` / `stalled` / `ended`), via per-agent adapters
  (patterns as data, not free-text keyword matching) plus an optional Claude
  `Stop`/`Notification` hook events layer. Usage-limit messages are recognized
  and resolved to an absolute reset timestamp. `scripts/nogg session
  resume-when-ready` waits out a detected limit and nudges the session to
  continue without switching models. `scripts/nogg session send --verify`
  confirms a message was actually submitted, not left sitting in an input box.
- Opt-in multi-machine Beads sync: `"multi_machine": true` in
  `.nogging/config.json` makes a `trusted`/orchestrator session `bd dolt pull`
  at session start and `bd dolt push` before ending if it wrote a Bead;
  `doctor` reports unpushed local Dolt state. Default stays off.
- Cloud session (Claude Code on the web) branch discipline: the managed
  instruction block states the assigned `claude/*` branch is never a PR
  source; an optional `SessionStart` hook template bootstraps `bd`/Dolt and
  git hooks in a fresh cloud container; `check-branch-name` gives a
  cloud-specific hint.
- `scripts/nogg task-done <bead-id>` ticks a closed Bead's `tasks.md` line
  immediately; `doctor` reports a change ready to archive once every mapped
  Bead is closed; `/plan`'s sequence gained a conditional archive step.
- `scripts/bootstrap`: a standalone, pinned-version bootstrap installer for
  the whole supported toolchain (Node via `nvm`, Claude Code, Codex, the
  OpenSpec CLI, `bd`, Dolt, `git`/`tmux`/`gh`) on Debian/Ubuntu Linux, runnable
  via `curl | bash` with no prerequisite but a shell. Idempotent; a
  pin-consistency test keeps it from drifting against `docs/compatibility.md`.
- A per-persona commit identity roster (Planner, Lead, Orchestrator, Sync, and
  each specialist) in `.nogging/config.json`'s `personas` key. A session's
  worktree carries its persona's `user.name`/`user.email`, isolated per
  worktree via `extensions.worktreeConfig`; the Lead Agent delegation protocol
  credits an incorporated specialist's work with a `Co-authored-by:` trailer.
  Tier 1 only (plain git identity) in this release — real GitHub `[bot]`
  identities via a registered GitHub App remain a documented, opt-in
  follow-up.

### Fixed

- `EnterWorktree`'s relocation-approval prompt blocked every autonomous Lead
  session on its first worktree entry; the autonomous launch prompt now
  instructs a plain `cd` instead, which Claude Code does not gate the same way.
- The `trusted` launch profile's `defaultMode` is now `auto`, not
  `acceptEdits`: an unattended `--full-access` session no longer hangs on its
  first qualifying Bash command waiting for an operator to approve it.
- A Codex session's `workspace-write` sandbox now includes the shared
  checkout (`--add-dir`) at every authority level, so a session running from
  an implementation/planning worktree can reach the shared `.git`/`.beads` it
  needs for `git commit`/`push` and `bd`/`scripts/nogg`.

## [2.0.2] - 2026-09-16

Documentation-only release: no installed CLI behavior changes.

### Removed

- The README's "Brand" section (palette hex table, typography note, the
  nogging timber-framing etymology, voice guidance). Brand-design detail an
  end user of the tool doesn't need — it already lives, more completely, in
  the private `JoMe92/rooftree` companion repo. `docs/brand/` itself (the
  actual logo/banner/social-card/diagram image assets the README embeds) is
  unaffected.

## [2.0.1] - 2026-09-15

Documentation-only release: no installed CLI behavior changes.

### Added

- Four diagrams in the README (communication model, tool map, quick start,
  daily workflow), rendered from the Nogging Claude Design project.
- A CI status badge and a "Tests and CI" section documenting every
  `nogging-validate.yml` job.
- A "Brand" section in the README with the palette sampled from the shipped
  brand assets.
- `docs/README.md`, a categorized index of the `docs/` folder (Concepts /
  Using Nogging / Releasing and maintaining).

### Changed

- Moved the brand asset directory to `docs/brand/` (was `brand/`).
- Moved product-planning and internal audit/status documents
  (`docs/product-identity/`, `docs/security/`,
  `docs/public-release-readiness-report.md`) to the new private
  `JoMe92/rooftree` companion repository; they are not something an end user
  of the public tool needs.
- `docs/architecture.md` is now linked from the README documentation table.

### Fixed

- The Quick start and Install sections were still pinned to the pre-rename
  `v1.6.0` tag despite `v2.0.0` having been tagged and released; bumped to
  the current tag.
- `docs/compatibility.md` still described "Nogging 1.6.x" and linked a
  superseded acceptance report as "latest".

## [2.0.0] - 2026-09-14

A major version bump: the Nogging rename changes technical identifiers
(CLI command, state root, commit trailer) that a `v1.x` installation
relied on — see the compatibility note under Changed. Released from
release candidate `v2.0.0-rc.2` (`v2.0.0-rc.1` was pushed, found unable
to upgrade a real v1.x install, and superseded by rc.2's `update`
migration fix) with no further code changes.

### Changed

- **BREAKING**: renamed the project from Agentsembli SpecForge to
  **Nogging**. The CLI command is now `nogg` (was `specforge`), the state
  root is `.nogging/` (was `.specforge/`), the commit trailer/env var are
  `Nogging-Writer`/`NOGGING_WRITER` (were `SpecForge-Writer`/`SPECFORGE_WRITER`),
  generated systemd units use the `nogg-` prefix (were `specforge-`), and the
  canonical repository is `JoMe92/nogging` (was `JoMe92/agentsembli-specforge`).
  See `docs/product-identity/` for the full provenance chain.

### Added

- Full brand identity assets and a rewritten, user-first `README.md`.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, a refreshed `SECURITY.md` route,
  issue forms, and a pull-request template.
- CLI release-lifecycle commands: report the installed version, update to a
  pinned tag, roll back, and uninstall while preserving target-owned state.
- A documented compatibility policy and matrix (Node 18/20/22, Python
  3.9/3.11/3.13, Git, Bash, OpenSpec, Beads, Dolt, tmux, systemd, and every
  supported Claude/Codex/Pi path).
- A public security and threat-model guide.
- CI hardening: least-privilege workflow permissions, action revisions
  pinned to full SHAs, Dependabot for npm and Actions, and dependency,
  secret, and package-content gates — each verified to fail against an
  intentionally bad fixture and pass on the real repository.
- This changelog, a release-consistency check, checksum/SBOM generation,
  and an exact-tag install smoke test (`scripts/release-check`,
  `scripts/release-artifacts`, `scripts/release-smoke-test`); see
  `docs/releasing.md`.

### Fixed

- `recover`'s stale-claim check failed to parse Beads' `Z`-suffixed
  timestamps on Python 3.9/3.10 (`datetime.fromisoformat` only accepted the
  `Z` suffix from Python 3.11), so an old claim was silently never reported
  as stale on those versions.
- `update` refused outright against a real v1.x install (`no .nogging/config.json
  — run init first`) because it never recognized the legacy `.specforge/`
  state root. `init`/`update` now migrate `.specforge/` to `.nogging/` in
  place (config, launch-profiles, launch-prompts, locks, state) the first
  time either runs against a legacy install.

### Removed

- Minimized the published npm package payload: internal research notes,
  acceptance history, and generated/cache artifacts are no longer packed.
