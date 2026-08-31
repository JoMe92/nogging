## SpecForge agent instructions

Read `docs/specforge/operating-model.md` and the active Bead before work.

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

### Planning only

The Planning Agent runs `./scripts/specforge plan-begin`, writes or revises
OpenSpec, runs `./scripts/specforge validate`, materializes Beads
(`./scripts/specforge materialize <change>`), commits with
`SPECFORGE_WRITER=planning`, then runs `./scripts/specforge plan-end`.

Update SpecForge itself with `npx github:JoMe92/specforge update`.
