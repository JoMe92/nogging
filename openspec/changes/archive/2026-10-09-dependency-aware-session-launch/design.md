# Design — dependency-aware session launch

## Decision 1 — the read path is `bd dep list`, not a field on `bd show`

#37's proposed solution assumed `bd show <id> --json` already carries a
`dependencies` array. A live check against the installed `bd` shows this is
not so: `bd show --json` returns only `dependency_count` as an integer. The
actual, confirmed read path is `bd dep list <id> --json` (default
`--direction down`, i.e. "what this Bead depends on"), documented by `bd dep
list --help` as returning "a flat array of dependency records." This
repository's own Beads DB has no recorded dependency anywhere today, so the
populated record's exact key names (in particular, how the blocking Bead's
own current status is represented — inline on the record, or requiring a
follow-up `bd show` per blocker) could not be observed live during this
planning session.

**Verification deferred to implementation, deliberately**: TASK-DAL-001
below opens with "create one real `bd dep add` between two scratch Beads,
inspect `bd dep list --json`'s actual output, then delete the scratch
dependency" as its first step, before writing any `session_launch()` code
against an assumed shape. This mirrors how this project already handles a
genuinely unverifiable-at-planning-time technical fact (e.g. `TASK-BOUNDARY-
006`'s hands-on PreToolUse verification) rather than this design guessing
and risking a second round of rework.

## Decision 2 — the check runs for `lead` and `specialist:*` only, read-only, cheap

Scoped exactly as #37 proposes: `--role orchestrator` is Bead-less and
unaffected (`normalize_role` already keeps it on a separate branch).
`session_launch()`'s existing `bead_exists()` call is the natural insertion
point — add the dependency check immediately after it, before any tmux
session or metadata record is created, so a refusal here produces exactly
the same "nothing was created" guarantee the existing Bead-existence check
already gives. The check is one additional `bd dep list` subprocess call
(the same cost class as the existing `bd show` call `bead_exists` already
makes) — no new Beads mutation, no network call, matching #37's own stated
constraint.

A dependency counts as blocking when its record's own status is not
`closed` — mirrors `bd ready`'s own notion of readiness, so `session launch`
refuses exactly the Beads `bd ready` would not list as ready, nothing
broader.

## Decision 3 — the Claude-only hook is a second, independent layer, not a refactor of the first

`scripts/hooks/pre-tool-use-lead-launch-guard` duplicates the dependency
check rather than shelling out to `scripts/nogg` to ask it — this is the
same layering `pre-tool-use-openspec-guard` already uses for the `openspec/`
boundary (a fast hook-level backstop on top of, not a replacement for, the
tool-agnostic guarantee). It matches on the `Bash` tool (`.tool_input.command`,
not `.tool_input.file_path` — a different field on the same stdin JSON
shape `pre-tool-use-openspec-guard` already reads), recognizes a `scripts/nogg
session launch` invocation carrying `--role lead`/`specialist:` and
`--bead <id>` by simple argument scanning (not a full shell parse — matching
`pre-tool-use-openspec-guard`'s own level of rigor for its file-path case),
and runs the identical `bd dep list` check inline.

**Installable, not just repo-local**: the existing guard is wired through
three places a new hook must mirror exactly, confirmed by reading each:
`bin/lib/manifest.js`'s two verbatim-file lists (`verbatim` and the install-
only subset, both already naming `pre-tool-use-openspec-guard`),
`package.json`'s `files` array (same name already present), and
`bin/lib/merge.js`'s `GUARD_MARKER`/`GUARD_ENTRY` idempotent-merge pattern
for `.claude/settings.json` (today keyed to the `Edit|Write` matcher only).
This repo's own `.claude/settings.json` is the first installation of the
new entry, exercised the same way `init`/`update` would exercise it
downstream.

## Decision 4 — `doctor`'s check is read-only and reports, never acts

For every `running` Lead/specialist session, resolve its `bead_id` and run
the same `bd dep list` check `session_launch()` now runs at launch time.
Report a `NOTE` for any session whose Bead has since become blocked — this
is exactly the "three sessions still at startup when the chain was recorded
retroactively" scenario in #37's own evidence. `doctor` never stops a
session; the operator or the Orchestration Agent decides what to do with
the `NOTE`, consistent with this project's existing `doctor` philosophy
everywhere else.

## Non-goals

- Inferring a cross-change dependency from `design.md`/`tasks.md` prose.
  Explicitly out of scope per #37 and `proposal.md`.
- Any change to `bd materialize`'s own Beads-creation logic. This change is
  entirely about *consulting* dependency state that already exists, never
  about how it gets recorded.
