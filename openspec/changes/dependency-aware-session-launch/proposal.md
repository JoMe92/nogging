# Dependency-aware session launch

## Source

[#37](https://github.com/JoMe92/nogging/issues/37) — `scripts/nogg session
launch --role lead --bead <id>` only checks that the Bead *exists*, never
whether Beads itself considers it *ready* (no open, unmet dependencies). A
downstream project materialized 9 sequential changes with a cross-change
dependency chain recorded only in `design.md` prose, then launched 4 Lead
sessions in parallel for exactly the four chained tasks — nothing in the
launch path objected, because the dependency was never recorded in Beads at
materialization time.

## Why

The gap is real and the evidence is concrete, but it is worth being precise
about what `session launch` can and cannot catch: it can only refuse a Bead
whose dependency is **already recorded** in Beads. The incident's actual
root cause — `materialize` has no way to infer an ordering relationship
written only as prose in one change's `design.md` ("nach TASK-API-018",
referring to a task in a *different* change) — is explicitly out of scope
for this change, exactly as #37 itself scopes it: a planning session that
writes such a cross-change reference already has the context and should run
`bd dep add` right after `materialize`. This change makes `session launch`
actually enforce whatever dependency *was* recorded, which today it simply
never consults.

## Research performed

Verified directly against the installed `bd` (not taken on #37's own
description alone):

- `bd show <id> --json` does **not** return a `dependencies` array by
  default — confirmed live: it returns only `dependency_count` /
  `dependent_count` as integers. #37's proposed solution names this as the
  read path; it is not quite right as written.
- The real, correct read path is `bd dep list <id> --json` (confirmed via
  `bd dep list --help` and a live call against a dependency-free Bead,
  which returned `[]`): "a flat array of dependency records," read-only,
  with `--direction down` (the default) returning what the named Bead
  depends on. This repository's own Beads DB currently has zero recorded
  dependencies anywhere, so the populated record shape (in particular the
  exact key name for the blocking Bead's own status) could not be observed
  live during this planning session — `tasks.md` below has the implementing
  session confirm it hands-on in the first few minutes of TASK-DAL-001,
  rather than this design guessing at a field name it cannot verify.
- Confirmed `session_launch()`'s current Bead check
  (`scripts/nogg`, `bead_exists()`) only runs `bd show <id> --json` and
  checks the ID is present in the result — no status or dependency
  consultation at all, for any role.

## What changes

- **`session_launch()` itself** (`scripts/nogg`): for `role in ("lead",
  "specialist:*")` only, after the existing `bead_exists` check and before
  creating the tmux session, fetch the target Bead's dependencies via `bd
  dep list <id> --json` and refuse (no tmux session, no metadata record;
  same failure shape as an unresolvable `--profile`/`--prompt`) if any
  dependency's blocker Bead is not `closed`, naming the blocking Bead ID(s)
  in the error. `--role orchestrator` is unaffected (it is Bead-less).
- **A Claude-only `PreToolUse` fast backstop**
  (`scripts/hooks/pre-tool-use-lead-launch-guard`), mirroring the existing
  `scripts/hooks/pre-tool-use-openspec-guard` pattern: detects a `scripts/nogg
  session launch` invocation carrying `--role lead`/`specialist:` and
  `--bead <id>`, shells out to the same `bd dep list` check, and `exit 2`s
  with the same message one step earlier — before the `Bash` tool call that
  would invoke `session launch` even runs.
- **`scripts/nogg doctor`**: flags any currently `running` Lead/specialist
  session whose `--bead` has since become blocked by a dependency recorded
  *after* the session started — the exact situation three of the incident's
  sessions were in at the moment the gap was caught.

## Out of scope

- Inferring cross-change dependencies from `design.md`/`tasks.md` prose.
  Explicitly #37's own out-of-scope note: the planning session that writes
  such a reference should record it with `bd dep add` right after
  `materialize`; this change only enforces dependencies already recorded.
- Any change to `harden-trusted-session-authority` or
  `session-liveness-and-kickoff` (planned separately, same session). This is
  a small, independent launch-time safety check.
