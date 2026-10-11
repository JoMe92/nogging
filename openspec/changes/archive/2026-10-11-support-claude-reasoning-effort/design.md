## Context

Research on 2026-10-11, baseline develop `91ba73c`:

- Installed `claude --version`: **2.1.296 (Claude Code)**. `claude --help` advertises `--effort <level>`: “Effort level for the current session (low, medium, high, xhigh, max)”. This is not a print-only flag.
- Anthropic's [effort tutorial](https://academy.claude.com/tutorials/choosing-the-right-effort-level-in-claude-code) describes `--effort` as session-only; persistent alternatives include `effortLevel` settings and the effort environment variable. Nogging will use the native flag, not those persistent alternatives. Model/backend support remains the runtime's responsibility; help does not prove every model accepts every level.
- `load_profile_settings()` currently rejects `model_reasoning_effort` for Claude. `session_launch()` only selects effort from Codex's profile. There is currently no public effort override on `session launch` (only `--model`).
- Claude's actual route is `session_launch()` → tmux argv → `scripts/session-launch` → Bash `set --` → `exec claude "$@"`. The wrapper adds settings, exact resume/session ID, appended prompt, permission mode, Remote Control and model. Its existing `--reasoning-effort` is explicitly Codex-only and becomes `-c 'model_reasoning_effort="…"'` on Codex.
- The helper advertises `model-forwarding` but that feature does not imply Claude effort support. An explicit new feature is needed to prevent mixed installed versions dropping a requested setting.
- Discovery review: SPEC-9txl documents inherited supervised environment pollution in test suites, and SPEC-sxjv (TASK-SCM-002) describes helper forwarding and stale-wrapper hazards. Incorporate isolated test environments and contract checks; leave unrelated discoveries pending. Existing SCM support is already integrated, so do not recreate those tasks. Ready archive `configure-agent-state-and-diagnostics` was validated and archived before this change.

## Goals / Non-Goals

**Goals:** Provide session-scoped Claude effort with validation before launch side effects, exact argv forwarding, honest requested-setting provenance, and installed-consumer coverage.

**Non-Goals:** Add a Codex CLI effort override, change agent/model defaults or authority, choose effort automatically, maintain a model compatibility table, change Claude's persistent `effortLevel`, manage `/effort` interactions, or claim runtime-effective telemetry. Execution implementation and human acceptance remain separate.

## Decisions

1. **Claude profile key is `effort`; public override is `--effort`.** Accept only exact strings `low`, `medium`, `high`, `xhigh`, `max`. This matches Claude's native flag and avoids reusing the Codex-only `model_reasoning_effort`. The alternative native settings key `effortLevel` is not the Nogging profile interface: effort is consumed by Nogging and removed from the generated Claude settings JSON, then supplied through argv. Do not introduce aliases. Shipped profiles omit effort so defaults stay unchanged; document complete custom JSON examples with permissions.

2. **Validate before selecting.** Validate the selected profile's effort even when overridden, then select explicit launch value, profile value, or no value (`runtime-default`). A present null, boolean, number, container, empty/whitespace string, case variant, flag-like string, `auto`, `ultra`, `none` or `minimal` is invalid for Claude. Keep `model_reasoning_effort` rejected in Claude and Pi; reject `effort` in Codex/Pi/Antigravity profiles and reject public `--effort` for every non-Claude agent, including implicit configured agent selection. Add equivalent effort-key checks to the Antigravity loader, which currently uses a distinct parser. Reject before worktree allocation, settings/record writes or tmux creation. Model and effort selection remain independent.

3. **Use a dedicated wrapper `--effort <level>`.** Extend parsing, usage and contract options, advertise a new `claude-effort-forwarding` feature, and require it whenever Claude effort is emitted. Keep Codex's `--reasoning-effort` semantics and `model-forwarding` unchanged. Update doctor helper diagnostics to probe the new option/feature. Repeat agent/value validation at direct wrapper entry, including explicitly empty arguments; use an argument-presence marker so an empty value cannot silently turn into omission. Claude receives exactly two extra argv elements `--effort`, `<level>`, using `set -- "$@" …`; never shell interpolation or environment mutation. Forward on both cold launch and exact `--resume` while preserving all authority, fencing, prompt and identity flags. A wrapper missing the new feature must refuse before session creation with an update remedy. If the real Claude version rejects the flag/model combination, preserve the existing scrubbed startup-failure path; never silently retry without effort.

4. **Reuse metadata with additive provenance.** `reasoning_effort` stores the requested value for Claude and Codex, null when absent. Add `reasoning_effort_source`: `launch`, `profile`, or `runtime-default`; Codex uses `profile` or `runtime-default` without a new public override. Keep requested_model/model_source intact. New Claude/Codex list rows show `effort=<level> (source)` or `effort=runtime-default`. For old records lacking the source, a present effort shows `effort=<level> (unknown)` and absent effort preserves the prior listing; never infer historical provenance. Other agents' list display remains unchanged. Record/list describe launch requests, not later interactive changes, inherited environment overrides or resolved model defaults.

5. **Verification separates transport from model behavior.** Offline runtime stubs capture exact argv through the full launch path, plus direct-wrapper rejection and contract negotiation. Compare authority flags with and without effort. Packed init/update fixtures verify the actual installed helpers and source-profile/global-config byte preservation. A bounded real Claude probe uses an isolated temporary HOME/config and an inert print prompt at a supported model/level to confirm native acceptance; record versions and unsigned evidence without broad claims about all models/levels. Quota/auth failure is a blocking discovery for the live acceptance task, not a fabricated pass. Run full scripts/test with inherited NOGG_* / NOGGING_ROOT removed from the child test environment (never remove ownership context from this planning or execution session), and check tests work with bd absent as CI does.

## Dependencies and execution order

Explicit edges: TASK-CRE-002 depends on TASK-CRE-001; TASK-CRE-003 depends on TASK-CRE-002; TASK-CRE-004 depends on TASK-CRE-003. The serial chain prevents overlapping edits to shared launcher/wrapper/metadata fixtures. No new cross-change edge is needed: SCM profile/model/record support is already integrated at the researched baseline. Each dependent execution worktree must start only after its prerequisite implementation is integrated into develop, not merely closed.

## Risks / Trade-offs

- CLI/model support changes → document observed version; runtime-native errors stay visible and failed launches remain failed.
- Stale wrapper accepts but drops values → dedicated capability negotiation and installed-payload negative test.
- A profile's `effort` leaking into Claude settings may be ignored or rejected → remove the Nogging key from a copy before generating per-session settings; retain the source profile unchanged.
- Existing runtime settings/environment can affect actual effort → record requested provenance only; omit flags when unspecified and do not overwrite user state.
- Shared launcher work may advance during execution → allocate after prerequisite integration and review conflicts without weakening fencing.

## Migration Plan

Ship through the normal init/update payload; existing profiles and records remain readable. Do not add effort to shipped defaults. New profiles may opt in with `"effort": "high"`; a one-off `--effort low` overrides it. Restore older tool payload to roll back, removing the new profile key before launching through old Nogging. Keep source profiles, user config and durable historical session records intact.
