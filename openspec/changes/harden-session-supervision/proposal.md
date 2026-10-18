## Why

The herdr hardening change is implemented. Its real Pi re-acceptance,
`docs/acceptance/2026-10-16-herdr-hardening.md`, ended
**pass-with-deviations** and left four discoveries, N1–N4, recorded on
`SPEC-dcuq`. The hardening design also named a risk it did not fix: if a
sandboxed Lead is the first to start the shared `tmux -L nogging` server,
that server lives in the Lead's PID and mount namespace and dies with the
Lead. It takes every session on it down too, including the Orchestration
Agent. That is the likely cause of the earlier loss of every Lead session at
once. This change closes these gaps in the Product Owner's order of
priority.

## What Changes

- **The shared tmux server is never born in the sandbox.** A caller inside
  the OpenSpec execution sandbox never starts the dedicated tmux server.
  When the server is down, its `session launch` is refused before any side
  effect and points to an unsandboxed launch, the same way herdr's fenced
  refusal works. A server that already lives in another namespace is
  reported by `doctor`, `session list` and `orchestrator status`, and
  Nogging never kills it.
- **The orchestrator lock is read across checkouts (N4).** The orchestrator
  lock, the singleton session name and the systemd unit name are resolved
  from the main checkout, whichever checkout runs the command. From an
  implementation worktree, `recover`, `orchestrator status` and `doctor`
  report the real holder. `orchestrator run` in a linked worktree is
  refused, so it cannot start a second orchestrator.
- **`task-done` never retries without the checkout (N1).** When an older
  sandbox broker rejects the checkout-aware request, the client reports that
  the session must be relaunched. It sends no second request and ticks
  nothing, as hardening Decision 4 ("Mixed versions") requires.
- **`nudge --message` replaces wrapped pending input completely (N2, both
  backends).** Nudge clears pending input row by row and checks that the
  composer is empty before it types. It submits only when the composer then
  holds exactly the message. Text merged with stale input is never submitted
  and never reported as `nudged`.
- **The foreign-pane advisory is quoted correctly (N3).** The herdr guide
  quotes the real `session list` output, and a check keeps the guide and the
  code in step.
- **Documentation and a short re-acceptance.** The session, recovery,
  operating-model and architecture documents describe the new rules. A short
  unsigned Pi re-acceptance repeats the affected steps. The Product Owner
  signs it.

## Non-Goals

- Switching the default backend to herdr, or moving the Orchestration Agent
  off tmux.
- Changing the sandbox model. Sandboxed Leads keep their PID and mount
  namespaces.
- A `session tmux-server start` command, or a tmux server that is kept alive
  with no sessions (see `design.md` Decision 2).
- Stopping, restarting or migrating a tmux server that already lives in
  another namespace. Nogging reports such a server; the operator decides.
- Changing `session send`, which still types without clearing (see
  `design.md` *Risks*).
- Any network listener or new external dependency.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-backends`: a fenced caller never starts the shared tmux server,
  and a server living in another namespace is reported.
- `orchestration-agent`: the lock, the session name and the unit name
  resolve from the main checkout.
- `sync-safety`: a pre-update broker gets no retry without the checkout.
- `session-observability`: `nudge --message` clears completely and submits
  only the exact message.

N3 needs no spec change, because the behaviour already matches the herdr
guide requirement; only the guide's wording is wrong.

## Impact

- Code:
  - `scripts/lib/session_backend_tmux.py`: the fenced `-N` flag, a `prepare`
    preflight and the server namespace probe;
  - `scripts/lib/session_backend.py` and `scripts/lib/session_backend_herdr.py`:
    the `backspace` key;
  - `scripts/nogg`: the orchestrator home resolver, the `task_done` client,
    the nudge region, and the `doctor`, `session list` and `orchestrator
    status` lines.
- Tests: one new suite per task, runnable on GitHub runners with no Dolt or
  `bd`, no PID-range assumptions, no `unshare`, and socket paths under 108
  bytes.
- Docs: `docs/using-with-herdr.md`, `docs/running-work-in-sessions.md`,
  `docs/failure-recovery.md`, `docs/operating-model.md`,
  `docs/architecture.md`, plus a new unsigned acceptance report.
- Host: no new dependency. tmux 3.2, the documented minimum, already has the
  `-N` flag.

This planning artifact authorizes no execution work, release, push or human
acceptance sign-off.
