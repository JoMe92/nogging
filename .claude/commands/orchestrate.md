---
description: Reach the always-on Orchestration Agent, or scope it to one takeover task.
---

# /orchestrate — the always-on Orchestration Agent

The **Orchestration Agent** is not a persona you enter here. It is a single
always-on session (`sf-orchestrator-<slug>`) that a systemd user service keeps
alive on the delivery host, above the Planning Agent and the Main Worker. See
the *Orchestration* section of `docs/operating-model.md` for the role, the
hierarchy (Product Owner → Orchestrator → {Planning, Lead} → Specialists), and
the safeguards for its lifted authority.

## Reaching the session

```bash
scripts/nogg orchestrator status   # unit + linger state, the lock, the live session, last log lines
scripts/nogg orchestrator restart  # bounce the service
scripts/nogg orchestrator stop      # stop + disable it and end the session
```

- **From the delivery host:** `scripts/nogg session attach sf-orchestrator-<slug>`
  (read-only: add `--read-only`), or `scripts/nogg session log
  sf-orchestrator-<slug> --follow`.
- **From a phone, no SSH:** the session registers with **Remote Control**
  automatically — open it from the Claude app and type into it there.

If `orchestrator status` shows the unit enabled but linger **off**, run
`loginctl enable-linger $USER` once so the service survives a reboot without a
login. If it shows the workspace untrusted, run `claude` once in the repo root
and accept the trust prompt.

## Giving the orchestrator a takeover task

By default the orchestrator is **orchestrate-only**: it reads state and drives
Planning and Lead sessions through `scripts/nogg`, and writes no
`openspec/` file and no code itself. To have it do one task directly, type — in
the orchestrator session — exactly one of:

```
/orchestrate takeover plan <what to plan>
/orchestrate takeover code <bead-id or what to implement>
```

- **`takeover plan`** — one full planning sequence (`plan-begin` → author →
  `validate` → commit with a Conventional subject **and** a `Nogging-Writer:
  planning` trailer → `materialize` → `plan-end`), then back to
  orchestrate-only. The trailer is mandatory: the orchestrator session has no
  `openspec/**` write guard, so the trailer is the only thing that keeps the
  commit past the CI `invariants` job.
- **`takeover code`** — claim the named Bead, implement, `scripts/test`, commit
  with the `[<bead-id>]` token, write the evidence note, `bd close` — then back
  to orchestrate-only.

A takeover is scoped to that one task. The orchestrator never completes the
`Signed-off-by:` line of an acceptance report — acceptance stays the Product
Owner's.

## Not in this version

There is no Codex or Pi orchestrator pendant in v1 — the always-on,
phone-reachable requirement is Claude Code only. A Codex/Pi orchestrator is a
recorded follow-up.
