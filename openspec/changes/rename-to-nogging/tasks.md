# Tasks

## 1. Baseline sequencing and GitHub

- [ ] TASK-NOG-001 Archive the completed `rename-agentsembli-specforge` change so its Agentsembli SpecForge requirements become the OpenSpec baseline; verify `openspec/specs/product-identity/spec.md` exists and `scripts/specforge validate` passes before continuing.
- [ ] TASK-NOG-002 Rename the GitHub repository from `JoMe92/agentsembli-specforge` to `JoMe92/nogging`, update its description and topics; verify the old URL redirects, `git remote -v` reflects the new URL locally, and repository visibility is unchanged (still private).

## 2. Local machine safety

- [ ] TASK-NOG-003 Stop the live `specforge-sync.timer`/`.service` on this delivery machine and record an inventory of `.specforge/state/worktrees/` (active sessions, locks, in-flight worktrees) before any file layout changes; verify no orphaned worktree or lock is silently dropped.

## 3. Package, CLI, and state root

- [ ] TASK-NOG-004 Rename `package.json` (`name`, `bin.specforge` → `bin.nogg`, description, repository/homepage/bugs URLs), `bin/cli.js`, and `bin/lib/*.js` to the Nogging/`nogg` identity; verify `node bin/cli.js --help` and the packaged file list are consistent.
- [ ] TASK-NOG-005 Rename `.specforge/` to `.nogging/` (config, launch-profiles, launch-prompts, state) including migrating this machine's already-existing state inventoried in TASK-NOG-003; rename `scripts/specforge` to `scripts/nogg` and its dedicated test files (`specforge.test.sh`, `specforge-materialize.test.sh`, `identity.test.sh`, `rename-compatibility.test.sh`, …); verify `scripts/test` passes and no `.specforge/` path remains referenced by code.
- [ ] TASK-NOG-006 Rename the `SpecForge-Writer` commit trailer and `SPECFORGE_WRITER` env var to `Nogging-Writer`/`NOGGING_WRITER` across git hooks (`commit-msg`, `pre-commit`, `pre-push`, `pre-tool-use-openspec-guard`), scripts, and tests (112 occurrences); verify the commit-msg hook test suite passes with the new trailer and that no code path still checks for the old trailer name.

## 4. Systemd

- [ ] TASK-NOG-007 Rename the systemd templates (`templates/systemd/specforge-*.tmpl` → `nogg-*`) and the orchestrator singleton session name (`sf-orchestrator-<slug>` → `nogg-orchestrator-<slug>`) everywhere it is referenced; on this machine, install and enable the new `nogg-sync.timer`/`.service` from the renamed templates and verify it ticks (a fresh `chore(sync)` commit appears) before removing the old unit files.

## 5. Agent configs and documentation

- [ ] TASK-NOG-008 Update literal `specforge` references in `.claude/agents/*`, `.claude/commands/*`, `.codex/rules/specforge.rules` (rename file + content), `.codex/prompts/*`, `.pi/prompts/*`, `.pi/extensions/specforge-guard.ts` to the Nogging/`nogg` identity; verify each still functions (guard test, prompt-link test) against the renamed paths.
- [ ] TASK-NOG-009 Sweep `AGENTS.md`, `CLAUDE.md`, and `docs/*.md` (excluding `README.md`, handled separately) for identity references; add `docs/product-identity/decision-<date>-nogging.md` documenting the Nogging decision, the technical-identifier rename, and the accepted OpenSpec-spec-wording divergence, explicitly superseding (not deleting) `docs/product-identity/decision-2026-09-10.md`; verify all maintained relative Markdown links still resolve.

## 6. Branding

- [ ] TASK-NOG-010 Add the three supplied Nogging brand assets (logo, banner, social card) under a checked-in `brand/` directory, and rewrite `README.md` as a full README: banner, tagline, purpose, the two-phase model, a `nogg` quick start, install steps, boundaries table, and test instructions; verify links resolve and quick-start commands match the renamed CLI from group 3.

## 7. Governance and community files

- [ ] TASK-NOG-011 Add `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, a refreshed `SECURITY.md` reporting route, a GitHub issue form set, and a pull-request template under the Nogging identity; document the intended GitHub description/topics for the owner to apply; verify every contributor and disclosure path is internally consistent and link-valid, and that nothing here changes repository visibility.

## 8. CI and final verification

- [ ] TASK-NOG-012 Rename `.github/workflows/specforge-validate.yml` (file and job content) to the Nogging identity; verify the renamed workflow still passes on a pushed branch.
- [ ] TASK-NOG-013 Run the full `scripts/test` suite, perform a fresh clone from the renamed GitHub URL, and run a final regression scan for stray `specforge`/`.specforge`/`SPECFORGE_WRITER`/`sf-orchestrator` mentions outside the accepted allowlist (the 17 unchanged OpenSpec capability specs, archived OpenSpec history, and migration/provenance documents); record and resolve or explicitly allowlist every unexpected hit.
