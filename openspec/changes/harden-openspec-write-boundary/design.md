# Design

## Context

SpecForge separates three authority zones: OpenSpec (what was agreed), Beads
(what is happening), Git (what was built). The write boundary that keeps
execution agents out of `openspec/` is currently only a prompt instruction plus
a `pre-commit` check on `SPECFORGE_WRITER`. The concept conversation asked for
defence in depth: a mechanical result invariant and a tool-level block, layered
so that no single bypass defeats the boundary.

## Goals / Non-goals

- Goal: discoveries use only native Beads label + note semantics.
- Goal: every execution commit carries a real Beads issue ID; planning and sync
  commits are exempted through `SPECFORGE_WRITER`.
- Goal: `Edit`/`Write` into `openspec/` is blocked by a Claude Code
  `PreToolUse` hook when the planning lock is absent.
- Non-goal: materializing Beads for this change.
- Non-goal: touching implementation files in this planning session.
- Non-goal: automating discovery classification or changing the change
  lifecycle (`open`, `done`, `archived`).

## Decisions

### Discovery signalling: native label + note

Adopt the conversation's section 3/8 decision verbatim:
`bd update <id> --add-label discovery --append-notes "<human-readable summary>"`.
The mechanical sync only needs to *find* discoveries (`bd list --label
discovery`) and surface them to the next planning session; it does not parse
them. Dropping the `specforge-discovery` JSON block removes a schema the tool
does not need and that Beads does not validate.

- Blocking discoveries additionally set `--status blocked` (section 8, case B).
- The note is required and must be human-readable prose, not serialized data.
- `docs/architecture.md` and `AGENTS.md` are updated to match; the JSON block is
  removed from both.

### Execution commit invariant: Beads ID token, `SPECFORGE_WRITER` exemption

`scripts/hooks/commit-msg` gains a second check after the Conventional Commit
shape check:

- If `SPECFORGE_WRITER` is `planning` or `sync`, accept without a Beads ID.
  These are the only two writers already trusted to touch `openspec/`
  (`scripts/hooks/pre-commit`), and they commit deterministic mirror/plan state,
  not execution work.
- Otherwise the commit subject MUST contain a Beads issue ID token of the form
  `[<PREFIX>-<id>]`, e.g. `[SPEC-abc]`. The token is matched with a bracketed
  pattern such as `\[[A-Z][A-Z0-9]*-[0-9a-z]+\]`; a bare `[]` or a placeholder
  like `[BEAD-XXX]` does not satisfy it (`XXX` is upper-case, not a real id).
- The rejection message names the rule and shows the exemption mechanism.

This is "proof at the result": an execution agent that edited `openspec/` cannot
land the work without either a Beads ID (which ties the change to claimed work)
or the `SPECFORGE_WRITER` exemption (which the boundary already governs).

### Tool-level boundary: `PreToolUse` hook

Add to `.claude/settings.json` under `hooks.PreToolUse` a single entry:

- `matcher`: `"Edit|Write"`
- `command`: a shell one-liner that reads the tool input file path, and if it is
  under `openspec/` and `.specforge/locks/planning.lock` is missing, prints a
  blocking message to stderr and exits `2`.

Exit code `2` is the documented Claude Code signal that reliably blocks the tool
call before it runs; static `permissions` rules are avoided because of known
matcher bugs (conversation section 10). The lock path is the existing planning
lock `.specforge/locks/planning.lock` (not the pre-simplification
`.openspec/.session.lock` shown in the export snippet). The `SessionStart` hook
already present in `.claude/settings.json` is preserved.

## Interaction of the three layers

| Layer | Enforces | Bypass covered by |
| --- | --- | --- |
| `PreToolUse` hook | no `openspec/` edit without planning lock | prompt drift, accidental edits |
| `pre-commit` hook | no `openspec/` commit unless `SPECFORGE_WRITER` in {planning, sync} | edits made outside Claude Code |
| `commit-msg` hook | execution commits carry a real Beads ID | execution work with no tracked Bead |

## Risks / open questions

- The Beads ID prefix is assumed to be `SPEC` per the conversation example
  (`[SPEC-abc]`); the pattern is kept prefix-agnostic so a different Beads
  prefix still works. Execution should confirm the actual prefix from
  `.beads/`.
- The `PreToolUse` env var name for the file path
  (`CLAUDE_TOOL_INPUT_FILE_PATH` vs `$CLAUDE_PROJECT_DIR`-relative JSON on
  stdin) must be verified against the installed Claude Code version during
  implementation; the requirement is stated behaviourally so the mechanism can
  adapt.
