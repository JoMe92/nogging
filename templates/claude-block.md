## SpecForge

This repository uses the SpecForge operating model. OpenSpec owns approved
product intent, Beads owns executable work, Git owns the implementation.

- **Do not edit `openspec/` outside a planning session.** A `PreToolUse` hook
  blocks `Edit`/`Write` under `openspec/` unless `.specforge/locks/planning.lock`
  is held (`./scripts/specforge plan-begin` … `plan-end`).
- Execution commits must be Conventional Commits carrying a real Beads issue ID,
  e.g. `feat(area): summary [SPEC-abc]`.
- Record discoveries on the active Bead with the native `discovery` label plus a
  human-readable note; never edit `openspec/` to capture them.

See `AGENTS.md` and `docs/specforge/` for the full model. Update SpecForge with
`npx github:JoMe92/specforge update`.
