## Context

Facts on `develop` at `1f8baa2`:

- `scripts/nogg` `_session_launch` rejects `--effort` for any agent but Claude
  (`--effort is Claude-only; launch refused`) and calls
  `validate_claude_effort`. For Codex, `reasoning_effort` starts as the
  profile's `model_reasoning_effort` (source `profile`) and a `--tier` table
  effort replaces it (source `launch`). The wrapper `scripts/session-launch`
  already takes `--reasoning-effort` for Codex, and `CODEX_REASONING_EFFORTS`
  already lists the accepted values.
- `select_session_model` already puts an explicit `--model` above the tier
  model. `selection_tier` is recorded independently of which fields the tier
  actually supplied, so `--tier X --model M` already keeps `tier=X`.
- Existing tests that assert the old refusal for Codex:
  `scripts/session-effort.test.sh` (`codex-cli-effort`, config-agent-codex,
  agy alias lines). Tier tests live in `scripts/session-tier.test.sh`.
  Fixtures use `scripts/lib/test-agents.sh` stubs; CI has no `codex` binary.
- `docs/model-selection.md` has a per-field precedence table; the Codex row
  reads `tier > profile model_reasoning_effort > runtime default`.
  `docs/running-work-in-sessions.md` says "`--effort` is Claude-only".
- The orchestrator prompt (`.nogging/launch-prompts/orchestrator.md`) says
  "Pass an explicit `--model` only on Product Owner instruction" and does not
  mention effort or the Codex policy. `scripts/model-selection.test.sh` asserts
  snippets of that prompt and of `docs/model-selection.md`.

## Decisions

1. **One flag, per-agent validation.** `--effort` stays one option. For the
   resolved agent `claude` it validates against `CLAUDE_EFFORTS` (unchanged);
   for `codex` against `CODEX_REASONING_EFFORTS`; for `pi`, `antigravity` and
   `agy` it still refuses with `--effort is Claude- and Codex-only; launch
   refused`. Validation runs before any side effect, as today, and the old
   Claude-only refusal wording is replaced in code, tests and docs together.
2. **Codex effort precedence.** `--effort` over tier over profile
   `model_reasoning_effort` over runtime default; this mirrors Claude's
   order. An explicit effort is recorded with `reasoning_effort_source`
   `launch`. The value is forwarded as `--reasoning-effort <level>`. An invalid
   `--effort` refuses even when a profile or tier would also supply a valid
   value.
3. **Tier attribution is independent of overrides.** With `--tier X --model M
   --effort E` the record keeps `selection_tier` X and `selection_tier_effort`
   (the table's effort, for attribution only), while `requested_model` is M and
   `reasoning_effort` is E, each with source `launch`. No new record field.
   Complexity attribution (`--complexity`) is unchanged.
4. **Exact resume.** A Codex exact `--resume` keeps whatever the existing resume
   path does for model and effort today; `--effort` on a Codex resume follows
   the same rule as `--model` there. If the installed wrapper or Codex resume
   cannot carry a reasoning effort, the launch refuses before any side effect
   instead of dropping it. The implementer reads `validate_codex_resume_options`
   and the resume branch and states the outcome in the Bead note.
5. **Policy lives in guidance, not code.** The Luna-default / Sol-low-only
   rule is documented as: launch Codex with `--tier <tier> --model
   gpt-6-luna --effort <level>` by default, keeping the honest tier; use
   `--model gpt-6.1-sol --effort low` only for an extremely hard task, and
   only on Product Owner instruction. The table is not edited (see Non-goals).
   The prompt keeps "explicit `--model` or `--effort` only on Product Owner
   instruction", and gains the Codex policy and the two command spellings.
6. **Tests use stubs.** Focused checks reuse the `session-effort.test.sh` /
   `session-tier.test.sh` fixtures (stub `bd`, `tmux`, `test-agents.sh`
   agents) and assert on the recorded launch argv and session record. No
   network, no real Codex, no real tmux.

## Dependencies and parallel lanes

All three tasks are independent of each other and have no Beads edges:

| Task | Lane (branch) |
| --- | --- |
| 001 launch flag and tests | `feat/codex-effort-flag` |
| 002 operator docs | `docs/codex-effort-flag` |
| 003 orchestrator guidance | `chore/codex-effort-flag` |

The docs and prompt text are written against this design's command spelling,
so neither waits for the code. Their checks are string assertions, not launch
behaviour.

## Risks

- A doc or prompt assertion in `scripts/model-selection.test.sh` or
  `scripts/runtime-guidance-docs.test.sh` may pin the old wording. Each task
  updates the assertions it changes in the same commit.
- Codex rejects an effort a model does not support. That stays the runtime's
  call: the session fails visibly and Nogging never retries at another effort.
