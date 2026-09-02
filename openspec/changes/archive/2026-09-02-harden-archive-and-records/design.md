# Design

## Context

`scripts/specforge` on `develop`:

```python
def changes():
    base = ROOT / "openspec/changes"
    return [p for p in base.iterdir() if p.is_dir() and p.name != "archive"] if base.exists() else []

def task_map():
    found, duplicates = {}, []
    for change in changes():
        file = change / "tasks.md"
        ...
        found[task] = {"change": change.name, "file": file, "title": title}
    return found, duplicates

FLOOR_DENY = [
    "Bash(rm -rf:*)", "Bash(rm -fr:*)", "Bash(sudo:*)", "Bash(dd:*)",
    "Bash(mkfs:*)", "Bash(mkfs.*:*)", "Bash(shutdown:*)", "Bash(reboot:*)",
    "Bash(:(){ :|:& };:)",
]

def session_records():
    out = []
    for p in sorted(sessions_dir().glob("*.json")):
        try: out.append((p, json.loads(p.read_text())))
        except (ValueError, OSError): continue
    return out
```

`validate()` iterates `beads()` (full status set, closed included) and, for each
mapped Bead, checks `task not in tasks` → "maps missing task" and
`tasks[task]["change"] != change` → "change label disagrees with task".

`openspec archive <name>` produces `openspec/changes/archive/YYYY-MM-DD-<name>/`
with `proposal.md`, `design.md`, `tasks.md`, `execution-log.md`, and folds the
capability delta into `openspec/specs/<cap>/spec.md`.

## Goals / Non-goals

- Goal: `./scripts/specforge validate` and `sync` stay clean after a completed
  change is archived.
- Goal: `session list` / `cleanup` / the launch collision guard see only real
  session records.
- Goal: every `FLOOR_DENY` entry is a valid Claude Code permission rule.
- Non-goal: changing what `openspec archive` itself does (it is the OpenSpec
  CLI).
- Non-goal: `materialize` or `sync` acting on archived changes — they must keep
  ignoring `archive/`.
- Non-goal: a full permission-rule validator; the test only needs to catch the
  bare-`:( )` class of malformed entry.
- Non-goal: actually archiving the six completed changes (a separate PO action).
- Non-goal: materializing Beads or editing implementation files in this planning
  session.

## Decisions

### SPEC-fc4 — archived-inclusive `task_map`

Add `task_map(include_archived=False)`. When `True`, after the `changes()` loop,
also walk `openspec/changes/archive/*/tasks.md`. For each archived directory,
derive the change name by stripping a leading `^\d{4}-\d{2}-\d{2}-` from the
directory name, and record `{"change": <derived-name>, "file": <path>,
"title": ..., "archived": True}`. A live change always wins over an archived one
with the same task ID (the live loop runs first and archived entries do not
overwrite).

`validate()` calls `task_map(include_archived=True)`. Its existing checks then
pass for an archived-change Bead:

- `task not in tasks` — now `False`, the archived task line resolves.
- `tasks[task]["change"] != change` — now `False`, the derived name matches the
  `openspec:change:` label.
- The "checked task must have a closed Bead" reverse check already only looks at
  live `tasks` for the file it reads; archived `tasks.md` files are marked
  `archived` so `validate()` skips the reverse check for them (they were true
  when archived; nothing can change them now).

`changes()` is untouched. `materialize()` (iterates `changes()`) and `sync()`
(derives `execution-log.md` paths from the live change name) keep ignoring
`archive/` — a regression test locks this in.

The duplicate-task-ID check (`duplicates`) must not fire when a live task and an
archived task share an ID (that is normal after archiving). Only same-scope
duplicates count: keep the existing behaviour for the live loop; do not add
archived task IDs to the `found`/`duplicates` collision set beyond recording
them.

### SPEC-fgf — `session_records()` ignores non-record files

Replace `sessions_dir().glob("*.json")` with a filter that keeps only true
record files: exclude any path whose name ends in `.settings.json`. (Record
names are `sf-<role>-<bead>-<nonce>.json`; the effective-settings file is
`<same>.settings.json`.) A stricter check — the parsed object has a `name` and
`bead_id` — is a reasonable belt-and-braces addition but the suffix exclusion is
the fix. `session list`, `session cleanup` (both variants), and the
`session_launch` collision guard all go through `session_records()` so they are
fixed together.

Test: with a `<name>.settings.json` present in the sessions dir, `session list`
shows exactly the real sessions and no `unknown` row; `cleanup` with no name
still correctly kills the tmux server when no real record remains active.

### SPEC-bxq — a valid floor

Remove `"Bash(:(){ :|:& };:)"` from `FLOOR_DENY`. A fork bomb is a shell
construct, not a command prefix, so it cannot be written as a Claude Code
`Bash(<prefix>:*)` rule; Claude Code rejects the bare `:(` as "Empty
parentheses" and skips it, so it was never enforced. The remaining eight entries
stay.

Add a `session.test.sh` assertion: every `FLOOR_DENY` entry matches a simple
"valid rule" shape — `^Bash\([^()]*\S[^()]*\)$` or `^Bash$` or a small
allowlist (`WebFetch`) — i.e. no entry has empty or nested parentheses. Also
assert the effective-settings file written by a launch contains every
`FLOOR_DENY` entry verbatim (so a future bad entry is caught before it ships).

### Docs

`docs/failure-recovery.md` "Orphaned Beads and bad mirrors" / a short new note:
archiving a completed change is supported — its closed Beads keep resolving
through the archived `tasks.md`. `docs/operating-model.md` state/lifecycle
section: `archived` changes remain auditable.

## Risks / open questions

- OpenSpec's archive directory naming (`YYYY-MM-DD-<name>`) is assumed. If a
  future OpenSpec version changes it, the prefix-strip regex needs updating;
  keep it in one place and covered by a fixture.
- If two archived changes ever share a task ID (should not happen — task IDs are
  globally unique by convention), the last one walked wins in `task_map`. The
  invariant "task IDs are unique" makes this moot; the archived walk should
  still not crash on it.
- `validate()` gains one call-site change; `doctor()` calls `validate()` so it
  benefits automatically. `audit` (same path) too.
