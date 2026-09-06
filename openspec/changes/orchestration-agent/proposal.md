# Add an Orchestration Agent above Planning and Main Worker

## Why

Today SpecForge has two session personas — the **Planning Agent** and the
**Main Worker (Lead Agent)** — that run in parallel and are connected only
through the shared OpenSpec/Beads state. The role that decides *what happens
next* — plan this now, execute that change, stop this session, review that
discovery — is the human **Product Owner**. There is no agent that holds the
loop.

The Product Owner wants that orchestration role to be an agent: a third,
top-level persona that sits **above** Planning and the Main Worker, reads the
whole state (Beads, OpenSpec, session logs, `git`), and drives the loop by
launching, steering and stopping Planning and Lead sessions. It is explicitly
**unrestricted** — full system access, no command floor, no `openspec/` write
boundary — because its job is to run the machine, not to be fenced inside one
lane of it. It must also be **always reachable**: running continuously, coming
back on its own after a crash or a host reboot, resumable from a phone.

This is a deliberate reversal of one documented invariant — "no profile can
lift the command floor" — scoped to exactly this one role and stated as plainly
in the docs as the existing Pi floor-only honesty note.

## What Changes

- **New persona: the Orchestration Agent.** A third session persona, above
  Planning and the Main Worker. Hierarchy becomes Product Owner → Orchestrator →
  {Planning Agent, Lead Agent} → Specialists.
- **Default scope is orchestrate-only.** The orchestrator reads state and
  runs `scripts/specforge` (`session launch|attach|log|stop`, `bd`, `git`,
  `/plan`) to drive Planning and Lead sessions. It does **not** write
  `openspec/` or implementation code itself.
- **Explicit takeover.** Only on an explicit in-session operator instruction
  (`/orchestrate takeover {plan|code} …`) the orchestrator performs one task
  directly — a planning edit (via `plan-begin`/`plan-end`, committed with the
  `SpecForge-Writer: planning` trailer) or a code task (claim, commit with the
  `[<bead-id>]` token, close) — then returns to orchestrate-only.
- **New authority level: `orchestrator`.** `.specforge/launch-profiles/orchestrator.json`
  runs in `bypassPermissions` with an empty deny list. Selecting this profile
  **and** launching under `--role orchestrator` lifts the SpecForge command
  floor and the per-session `openspec/` read-only root — recorded in the
  session metadata and shown by `session list` / `doctor` as `FULL-ACCESS`.
  The profile's floor-lifting key is honoured only for `--role orchestrator`;
  any other role selecting the same profile still gets the floor.
- **Always-on lifecycle.** A rendered systemd **user service**
  (`specforge-orchestrator-<slug>.service`, `Restart=always`,
  `WantedBy=default.target`) runs `scripts/specforge orchestrator run`, an
  idempotent supervisor that keeps a single `sf-orchestrator-<slug>` tmux
  session alive, resuming the orchestrator's own conversation with
  `claude --continue` after a crash or reboot. The installer prints the
  `systemctl --user enable --now …` line and the `loginctl enable-linger`
  hint. The launched session registers with Remote Control, so it is reachable
  from a phone with no SSH.
- **Single instance.** `.specforge/locks/orchestrator.lock` (same shape and
  staleness rule as the planning lock) guarantees exactly one orchestrator.
- **`scripts/specforge orchestrator` subcommand group** — `run`, `status`,
  `stop`, `restart` — so the operator drives the service without fighting the
  generic `session` commands.
- **Acceptance stays human.** The orchestrator never signs an acceptance
  report; that remains the one act reserved to the Product Owner.
- **Claude Code only in v1.** Remote Control — the "always reachable"
  requirement — is Claude-only. A Codex/Pi orchestrator is out of scope and
  recorded as a follow-up.
- **New capability:** `orchestration-agent`. **Modified capabilities:**
  `launch-profiles`, `claude-sessions`, `installer`.

## Impact

- **A documented invariant is narrowed.** "A fixed command floor cannot be
  lifted by any profile" gains one explicit exception: `--role orchestrator`
  under the `orchestrator` profile. `docs/architecture.md` and
  `docs/operating-model.md` state this as plainly as the Pi floor-only note —
  it is not an OS sandbox escape, it is a role that was never meant to be
  fenced, and the safeguards for it are visibility (`session list`, the
  append-only log, the durable record) and the single-instance lock, not a
  boundary.
- **New standing attack surface.** An always-on session with no command floor
  that auto-resumes its own conversation is a persistent target for prompt
  injection. Mitigations that fit the existing grain: it runs only on the
  delivery host (blast radius = one box), always as a supervised, listed,
  stoppable session (never a detached process), and the sub-sessions it
  launches keep their normal `restricted` / `trusted` profiles — only the
  conductor is unfenced.
- **New installer output:** a rendered `specforge-orchestrator-<slug>.service`
  unit, the `orchestrator.json` profile and `orchestrator.md` prompt (both ride
  the existing `launch-profiles` / `launch-prompts` verbatim directories), and
  two new lines in the post-install readiness output.
- No change to existing Planning, Lead, specialist, Codex, Pi or sync
  behaviour. The floor, the `openspec/` boundary and every existing profile are
  unchanged for every role except `orchestrator`.
