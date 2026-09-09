# Design — Orchestration Agent

## Context

- `docs/operating-model.md` / `docs/architecture.md`: Planning Agent and Main
  Worker are two **personas** of the top-level session, connected only through
  shared OpenSpec/Beads state. The concept's "permanently-running planning
  agent" was deliberately cut in favour of personas.
- `docs/running-work-in-sessions.md`: `scripts/specforge session launch`
  starts a supervised Claude/Codex/Pi process in a tmux session on the delivery
  host, with a durable JSON record, an append-only log, and a selectable
  authority level (`restricted` default, `trusted`, `--full-access`).
- `scripts/specforge`: `normalize_role()` accepts `lead` / `specialist:<type>`;
  `merge_floor()` unions `FLOOR_DENY` into every session's effective
  permissions; `session_launch()` requires `--bead`; `gen_session_name()`
  appends a nonce.
- The existing `systemd/specforge-sync.{service,timer}` and
  `templates/systemd/*.tmpl` + `bin/lib/manifest.js` `systemd` array are the
  pattern for a rendered, per-repo unit.

## Goals

1. A third persona above Planning and the Main Worker that drives the loop.
2. Truly unrestricted authority for that persona — no command floor, no
   `openspec/` boundary — selected implicitly by its profile.
3. Always-on: survives a crash and a host reboot, resumes its own conversation,
   reachable from a phone.
4. Exactly one orchestrator at a time.
5. Zero behaviour change for every other role.

## Decisions

### Decision 1 — A persona + an authority level, not a daemon

The orchestrator is a **session persona**, like Planning and Lead, run as a
supervised tmux session. It is *kept* always-on by a systemd user service
(Decision 4), but the thing that is alive is a normal supervised Claude
session with a durable record and an append-only log — not a bespoke
long-lived process. This keeps SpecForge's safety model intact: the safeguard
is that the session is **listed, logged and stoppable**, not that it is
sandboxed.

**Rejected:** a resident daemon with its own event loop (the concept's
approach, already cut once — "personas, not a daemon" — and it would need its
own lifecycle supervision). **Rejected:** a Task-tool subagent (in-process,
ephemeral, cannot outlive or sit above its parent).

### Decision 2 — Default scope is orchestrate-only; takeover is explicit

The orchestrator's job is to **run `scripts/specforge`**, not to do the
semantic work. By default it never writes `openspec/` or code. This keeps the
two-plane separation and the write-boundary audit trail
(`pre-commit` / `commit-msg` / the CI `invariants` job all still expect either
`SPECFORGE_WRITER=planning|sync` / the trailer, or a real `[<bead-id>]` token).

The Product Owner explicitly wanted the orchestrator to be *able* to plan or
change code "in Ausnahmefällen, mit einem expliziten Befehl". So: an in-session
instruction `/orchestrate takeover {plan|code} <description>` puts the
orchestrator into a one-task takeover:

- **`takeover plan`** — the orchestrator runs `plan-begin`, authors the
  `openspec/` change, `validate`, commits with a Conventional subject plus the
  `SpecForge-Writer: planning` trailer, `materialize`, `plan-end`. Identical to
  a `/plan` session, run in-persona.
- **`takeover code`** — the orchestrator claims the named Bead, implements,
  validates, commits with the `[<bead-id>]` token, writes the evidence note,
  closes it. Identical to a Lead task.

After the one task it returns to orchestrate-only. Nothing *mechanically*
enforces the return (the profile is god-mode); the discipline lives in
`orchestrator.md` and the operator's explicit scoping, exactly as the
`autonomous` prompt scopes a `--full-access` Lead session to "one named
change".

### Decision 3 — God-mode is implicit in the `orchestrator` profile, keyed to the role

`.specforge/launch-profiles/orchestrator.json`:

```json
{
  "permissions": { "defaultMode": "bypassPermissions", "deny": [], "allow": [],
                   "additionalDirectories": ["/"] },
  "specforge_floor": false,
  "specforge_openspec_readonly": false
}
```

In `session_launch()`:

- The `specforge_floor` / `specforge_openspec_readonly` keys are read **only
  when `role_meta == "orchestrator"`**. For any other role they are ignored and
  the floor is unioned and the `openspec/` read-only root is added exactly as
  today — so a `lead` session pointed at `--profile orchestrator` still gets
  the floor and the boundary.
- For `--role orchestrator` with `specforge_floor: false`, `merge_floor()` is
  skipped; with `specforge_openspec_readonly: false` the per-session
  `openspec/**` deny rules are not added.
- The effective-settings file, the metadata record and `session list` mark the
  session `FULL-ACCESS` (a distinct token, not just a profile name) whenever
  the floor was actually lifted. `doctor` surfaces a running FULL-ACCESS
  orchestrator prominently.

The Product Owner chose "implizit übers Profil" over an extra `--no-floor`
flag: selecting the profile is the deliberate act. Keying the floor-lift to
the role is what stops the profile from becoming a god-mode backdoor for
`lead` / `specialist`.

**No `orchestrator.codex.toml` / `.pi.toml` sibling** in v1 — Claude only
(Decision 6). The file carries a comment saying so.

### Decision 4 — Always-on via a systemd user service + an idempotent supervisor

`templates/systemd/specforge-orchestrator.service.tmpl` renders to
`systemd/specforge-orchestrator-<slug>.service`:

```ini
[Unit]
Description=SpecForge Orchestration Agent (always-on)
After=default.target

[Service]
Type=simple
WorkingDirectory=<abs repo path>
Environment=PATH=...
ExecStart=<abs repo path>/scripts/specforge orchestrator run
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

`scripts/specforge orchestrator run` is the idempotent supervisor:

1. Acquire `.specforge/locks/orchestrator.lock` (PID/host/created_at; the
   planning-lock staleness rule). If a *fresh* lock is held by a live process,
   print the holder and exit non-zero — systemd will retry, and a second
   manual `run` refuses.
2. If a live `sf-orchestrator-<slug>` tmux session exists (crash of `run` but
   not of the tmux session, or a re-`enable`), **adopt** it: re-pipe the log,
   refresh the record, block until it exits.
3. Otherwise create the tmux session under the SpecForge socket:
   - first ever start: `claude --append-system-prompt <orchestrator.md> \
     --settings <effective-settings>` — the effective-settings file is produced
     the same way `session_launch()` does it, via the `orchestrator` profile
     with the floor lifted.
   - a conversation already exists in this working dir:
     `claude --continue …` so history/context survive the restart.
4. Write / refresh the durable record: `role: "orchestrator"`,
   `bead_id: null`, stable `name: "sf-orchestrator-<slug>"` (no nonce — it is a
   singleton; a "collision" is the session we adopt), `profile: "orchestrator"`,
   `floor_lifted: true`.
5. Block until the tmux session exits, release the lock, return non-zero so
   `Restart=always` brings it back (unless `orchestrator stop` disabled the
   unit).

`loginctl enable-linger <user>` (printed by the installer, not run for the
operator) makes the user manager — and therefore the service — start at boot
with no login. Remote Control registration is inherited from the normal
launched-session path.

**`orchestrator` subcommand group:** `run` (above), `status` (unit
enabled/active state, linger on/off, whether a FULL-ACCESS session is live,
the record, the last log lines), `stop` (`systemctl --user stop` +
`--disable`, record terminal, release the lock), `restart`
(`systemctl --user restart`).

### Decision 5 — The orchestrator shares the repo-root checkout; sub-sessions get worktrees

`docs/running-work-in-sessions.md`: "two sessions working the same checkout
will collide." The orchestrator runs at the repo root but in orchestrate-only
mode never mutates the working tree, so it coexists with **at most one**
sub-session against the repo root. For parallel Planning + Lead, or two Lead
sessions, the orchestrator provisions a `git worktree` per sub-session and
passes `--cwd`. `orchestrator.md` states this rule; automating worktree
lifecycle is left to the orchestrator's own judgement (it has `git`).

### Decision 6 — Claude Code only in v1

Remote Control — the "immer erreichbar, auch vom Handy" requirement — is a
Claude Code feature. Codex and Pi have no equivalent, so their "always
reachable" story would be SSH + `tmux attach`, a different design. A
Codex/Pi orchestrator is recorded as a follow-up discovery, not built here.
The six specialists are already Claude-only for the same kind of reason
(Task-tool subagents), so this is consistent.

### Decision 7 — Acceptance stays human

`docs/operating-model.md`: "Acceptance is an explicit, human act recorded in a
signed report." The orchestrator may run the mechanical `[M]` acceptance steps
and drive the `[A]` ones through sub-sessions, but it never completes the
`Signed-off-by:` line. That is the one independent check that must not collapse
into the thing being checked. `orchestrator.md` says so explicitly.

## Risks / open questions

- **`claude --continue` semantics under tmux, non-interactively.** TASK-ORC-001
  verifies hands-on that `--continue` resumes the most-recent conversation for
  the working dir, that a `bypassPermissions` settings file genuinely suppresses
  all prompts in a piped-pane tmux session, and that Remote Control
  re-registers after a process restart. Any mismatch adjusts the later tasks.
- **Prompt-injection persistence.** An always-on god-mode session that resumes
  its own history means a successful injection persists across restarts. Not
  fully mitigated by design; the accepted position (proposal *Impact*) is
  delivery-host-only blast radius + full visibility + single instance. A future
  change could add a periodic context reset or an allowlist of push remotes.
- **The `openspec/` boundary in takeover-plan mode.** Even god-mode, a planning
  commit still needs the `SpecForge-Writer: planning` trailer or CI's
  `invariants` job fails. `orchestrator.md` must spell this out; the guard
  hook simply won't fire (no per-session `openspec/**` deny), so the trailer
  is the only thing keeping the commit legal.
- **`doctor` exit code.** A missing/inactive orchestrator service must **not**
  fail `doctor` (matching the Codex/Pi availability pattern) — it is an
  opt-in. Only a *misconfigured* one (unit enabled, linger off) rates a NOTE.
- **Two orchestrators across two clones of the repo.** The lock is
  filesystem-local. Running the service from two checkouts of the same repo on
  one host is possible; the per-repo slug in the unit name makes that a
  deliberate act, not an accident.
