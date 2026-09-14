## Context

See `proposal.md` for motivation. This is the second identity change. The
2026-09-10 rename (`rename-agentsembli-specforge`, all tasks closed) moved the
repository from `JoMe92/specforge` to `JoMe92/agentsembli-specforge` but
deliberately preserved every technical identifier (`specforge` CLI,
`.specforge/`, `SpecForge-Writer` trailer) for installed-state compatibility
ahead of a planned public launch. That launch never happened — GitHub still
reports `JoMe92/agentsembli-specforge` as private — and a live
`specforge-sync.timer`/`.service` is running on this delivery machine right
now, holding real state under `.specforge/state/worktrees/`.

Because the repository never went public, there is no known external installer
dependency on the current technical names. That removes the compatibility
constraint that shaped the last rename and opens a clean window to align the
running system with the branding concept's promised `nogg` CLI, rather than
repeating a display-name-only change.

## Goals / Non-Goals

**Goals:**

- One coherent Nogging identity across GitHub, package/CLI, state root, git
  convention, systemd units, agent configs, docs, and a presentable branded
  README.
- Migrate this machine's already-running installation deliberately and
  verifiably, not as a side effect of a file rename.
- Resolve the governance/community-files task (`SPEC-xdnw`) that was blocked
  purely on a naming decision.
- Sequence the OpenSpec baseline correctly relative to the unarchived
  predecessor change.

**Non-Goals:**

- Rewriting the ~17 existing OpenSpec capability specs' literal `specforge`
  wording (see Decisions below).
- Migrating the Beads `SPEC-` issue-ID prefix.
- Making the repository public or resuming the blocked public-history
  sanitization work (`SPEC-c4o5`).
- Publishing to npm or claiming trademark clearance beyond GitHub
  availability.
- Renaming the still-private `JoMe92/agentsembli-specforge` via a fresh
  sanitized-clone transfer the way the last rename did — a plain GitHub
  rename is sufficient because there is no public legacy-ref history to shed.

## Discoveries reviewed (planning-session acknowledgement)

- **`SPEC-c4o5`** (blocked, Git/Dolt public-history sanitization): unrelated
  to this change — it blocks a future *public* release, not a private
  rename. Acknowledged; remains tracked for whenever public release work
  resumes.
- **`SPEC-w904`** (blocked, TASK-IDENT-005 README/doc identity refresh):
  superseded — this change performs the equivalent README/doc identity work
  for Nogging instead. Acknowledged.
- **`SPEC-xdnw`** (blocked, TASK-PUB-004 governance/community files): was
  explicitly blocked pending a naming decision. Folded into this change's
  task list (Governance group) now that the name is decided.

## Decisions

### Rename technical identifiers this time, not just the display name

Unlike the 2026-09-10 rename, this change renames the CLI, state root, git
trailer/env var, entry script, and systemd prefix, using the following
mapping as the single source of truth for implementation tasks:

| Old | New |
| --- | --- |
| repo `JoMe92/agentsembli-specforge` | `JoMe92/nogging` (GitHub rename, redirect preserved) |
| package/CLI `specforge` | `nogg` |
| state root `.specforge/` | `.nogging/` |
| commit trailer `SpecForge-Writer` | `Nogging-Writer` |
| env var `SPECFORGE_WRITER` | `NOGGING_WRITER` |
| entry script `scripts/specforge` | `scripts/nogg` |
| systemd prefix `specforge-*` | `nogg-*` (e.g. `nogg-sync.timer`, `nogg-orchestrator-<slug>`) |
| singleton session `sf-orchestrator-<slug>` | `nogg-orchestrator-<slug>` |
| Beads issue prefix `SPEC-` | unchanged |
| existing OpenSpec capability spec wording | unchanged |

Alternative considered: keep runtime identifiers for compatibility, repeating
the prior rename's approach. Rejected — there is no known external dependency
on the current names, so there is no compatibility cost, and the branding
concept explicitly promises the short `nogg` CLI.

### GitHub rename, not a fresh sanitized-clone transfer

Use GitHub's native repository rename (redirect preserved, history intact),
not the "seed a fresh empty repository from an allowlisted clean mirror"
approach the last rename used. That approach existed specifically to shed
GitHub's undeletable legacy pull-ref history before a *public* launch; this
repository stays private, so there is no history to sanitize and a plain
rename is simpler and loses nothing.

### This machine's live installation is migrated as an explicit, ordered step

This host already runs `specforge-sync.timer`/`.service` and holds real state
under `.specforge/state/worktrees/`. The migration must, in order: stop the
old unit, move/re-create state under `.nogging/`, install and enable the new
`nogg-sync.timer` unit, and verify it ticks again — before any later task
assumes the new layout exists.

### Existing OpenSpec capability specs keep their historical wording

Rewriting every literal `specforge` occurrence across ~17 already-baselined
capability specs is a large, purely mechanical, non-behavioral text sweep —
none of those capabilities' actual requirements change. The owner chose not
to do this now (see the discovery answered during planning): those specs
continue to describe the mechanism's behavior accurately, with stale
identifier text, until a later change happens to touch them for another
reason. `product-identity` gets an explicit requirement documenting this so
the divergence reads as an accepted decision, not an oversight, to anyone who
encounters it later.

### Sequence the OpenSpec baseline via the unarchived predecessor

`rename-agentsembli-specforge` completed every task but was never archived —
`openspec/specs/product-identity/spec.md` does not exist yet, which is why
this change's own `specs/product-identity/spec.md` is written as `ADDED`
Requirements (matching the current, still-empty baseline) rather than
`MODIFIED`. Task group 1 archives the predecessor *before* this change's own
product-identity work is executed, so the baseline is established from
Agentsembli SpecForge first. Whether the archive tooling then folds this
change's `ADDED` requirements cleanly on top, or needs a manual reconciliation
pass, is left for the Main Worker to verify mechanically
(`scripts/specforge validate` after each archive step) — this is a tooling
sequencing detail, not a product decision, and is flagged here rather than
guessed at.

## Risks / Trade-offs

- **Spec/code divergence**: the 17 unchanged capability specs will literally
  say "specforge" while the running tool says "nogg" → mitigated by the
  explicit `product-identity` requirement documenting this as a known,
  owner-accepted trade-off.
- **Live systemd unit downtime or double-registration** during migration →
  mitigated by making the cutover one ordered task with a verification
  step, and keeping the old unit file until the new one is confirmed ticking.
- **GitHub rename changes clone URLs**: any other local clones, CI
  references, or documented remotes must be updated → mitigated by an
  explicit audit task covering the CI workflow file and documented URLs.
- **Branding ships ahead of the technical rename**: a README advertising the
  `nogg` CLI before the CLI actually exists would be actively misleading →
  mitigated by sequencing the README task after the package/CLI rename task.
- **Baseline sequencing uncertainty** (see Decisions above): mitigated by
  making archive-then-author an explicit task with a mechanical verification
  step rather than assuming it just works.

## Migration Plan

1. Archive `rename-agentsembli-specforge` to establish the Agentsembli
   SpecForge baseline.
2. GitHub: rename the repository, update description/topics, verify the old
   URL redirects.
3. Local safety: stop `specforge-sync.timer`, inventory
   `.specforge/state/worktrees/`.
4. Package/CLI: rename `package.json` identifiers, `bin/`, CLI help text.
5. State root + entry script: `.specforge/` → `.nogging/` (including this
   machine's existing state), `scripts/specforge` → `scripts/nogg` and its
   test files.
6. Git convention: `SpecForge-Writer`/`SPECFORGE_WRITER` →
   `Nogging-Writer`/`NOGGING_WRITER` across hooks, scripts, and tests.
7. Systemd: rename templates, reinstall this machine's live units under
   `nogg-*`, verify the sync timer ticks again.
8. Agent configs: update literal references in `.claude/`, `.codex/`, `.pi/`.
9. Docs sweep (excluding README) plus a new product-identity decision
   document superseding `docs/product-identity/decision-2026-09-10.md`.
10. Branding: place the three supplied assets, write the full README with
    the banner and a `nogg`-based quick start.
11. Governance (formerly `SPEC-xdnw`): `CONTRIBUTING.md`,
    `CODE_OF_CONDUCT.md`, refreshed `SECURITY.md` route, issue/PR templates,
    GitHub description/topics.
12. CI: rename `.github/workflows/specforge-validate.yml` and its content;
    verify it stays green.
13. Full `scripts/test`, a fresh clone under the new URL, and a final
    regression scan for stray `specforge` mentions outside the accepted
    allowlist (existing capability specs, archived OpenSpec history,
    migration/provenance docs).

Rollback: every step through the GitHub rename is reversible (GitHub keeps
the redirect; `git remote set-url` restores the old URL locally). Until the
local systemd cutover (step 7) is verified, keep the old unit files so
`systemctl --user disable --now nogg-sync.timer && systemctl --user enable
--now specforge-sync.timer` restores the prior state.
