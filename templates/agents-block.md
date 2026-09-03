## SpecForge agent instructions

Read `docs/specforge/operating-model.md` and the active Bead before work. This
block is the canonical, tool-neutral instruction set; the per-tool specifics
are confined to *Tool notes* at the end.

### Hard rules

1. Execution agents (Main Worker and specialists) must not edit `openspec/`.
2. Work only on a Bead that has been claimed by the Main Worker.
3. Before closing a Bead, run relevant validation, commit with a Conventional
   Commit containing the Bead ID (e.g. `[SPEC-abc]`), and add a Bead note with
   the commit SHA and evidence.
4. Record every material discovery on the active Bead with the native Beads
   `discovery` label plus a required human-readable note — never as serialized
   data, and never by editing `openspec/`. A blocking discovery also sets the
   Bead status to `blocked`; the next planning session lists them with
   `bd list --label discovery`.
5. Leave an intent breadcrumb. Before an expensive or hard-to-reverse step, and
   before ending a turn with a Bead still `in_progress`, append a one-line
   `progress: <next step>` to the Bead note
   (`bd update <id> --append-notes "progress: …"`). On resume, in any tool, it
   is the primary "where was I" signal.

### The write boundary

`openspec/` is read-only for every execution agent and writable only during a
planning session holding `.specforge/locks/planning.lock`
(`./scripts/specforge plan-begin` … `plan-end`). The lock toggles a
`.specforge/locks/openspec.readonly` sentinel that the write guard consults.

### Specialist delegation

Isolated implementation or review work may be delegated to a specialist, but
claiming a Bead, closing it, writing the evidence note, and committing stay
with the Main Worker, and no delegated context may write `openspec/`.

### Planning only

The Planning Agent runs `./scripts/specforge plan-begin`, writes or revises
OpenSpec, runs `./scripts/specforge validate`, commits with
`SPECFORGE_WRITER=planning`, materializes Beads
(`./scripts/specforge materialize <change>`), then runs
`./scripts/specforge plan-end`. The commit precedes `materialize` so a crash
between them never leaves Beads without a committed spec.

### Tool notes

- **Claude Code.** `openspec/` writes are also blocked by a `PreToolUse` hook
  (`scripts/hooks/pre-tool-use-openspec-guard`). Specialists are the
  `.claude/agents/*.md` roster, invoked in process through the Task tool.
  Operator entry points: `.claude/commands/{plan,discovery-review,sync-now}.md`.
- **Codex.** No per-tool hook — `openspec/` stays read-only through the
  filesystem write guard plus the commit hooks; the command floor is
  `.codex/rules/specforge.rules` (execpolicy). Codex has no in-process subagent
  mechanism: a specialist run is a separate supervised session,
  `scripts/specforge session launch --agent codex --role specialist:<type>
  --bead <id>`, under every specialist boundary rule. Operator entry points:
  `.codex/prompts/{plan,discovery-review,sync-now}.md`.

Update SpecForge itself with `npx github:JoMe92/specforge update`.
