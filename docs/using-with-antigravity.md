# Using Nogging with Antigravity

The optional `agy` integration uses the same Beads, Git and OpenSpec workflow
as other Nogging agents. The investigated Linux runtime is **agy 1.3.2**.
Unsigned core live evidence is recorded in the
[core acceptance report](https://github.com/JoMe92/nogging/blob/develop/docs/acceptance/2026-10-10-antigravity-core.md); quota support and full
issue #54 completion remain pending TASK-AGR-005. This guide does not declare
those checks complete. See the [contract investigation](https://github.com/JoMe92/nogging/blob/develop/docs/acceptance/antigravity-contract-investigation.md)
for sanitized live evidence and unsupported contracts.

## Launch and prerequisites

Install and authenticate `agy` using its provider instructions, then run
`./scripts/nogg doctor`. Its availability is informational; other agent paths
work without it. Python 3, Git, tmux and the usual Beads/Dolt prerequisites
still apply. Run Nogging `update` in older consumer repositories and ensure the
selected implementation worktree includes the guard payload before launch.

```bash
scripts/nogg session launch --agent antigravity --role lead \
  --bead <claimed-bead> --cwd <implementation-worktree> --profile restricted
```

`--agent agy` is an alias recorded as `antigravity`. Launch does not claim a
Bead. Authority to execute comes from the operator and is limited to the named
Bead or change. Allocate implementation worktrees with `nogg worktree implement`
before editing; never use an agent-created sandbox worktree as a substitute.

## Profiles, trust and boundaries

Profiles are `.nogging/launch-profiles/{restricted,trusted}.agy.toml`.
They accept `mode` (`accept-edits` or `plan`), `approval` (`ask` or `auto`),
`sandbox` (`false` only), and an optional quoted `model` forwarded to agy.
Mode `plan` and `--read-only` are tool restrictions, not OS isolation.

| Level | Permissions | Filesystem / network isolation |
| --- | --- | --- |
| restricted | `ask`; requires global `toolPermission` to be absent or `request-review` | None validated |
| trusted | `auto`; passes `--dangerously-skip-permissions` | None validated |

`--full-access` selects trusted plus the autonomous prompt. Both levels keep
the hook command floor and execution OpenSpec boundary active. Restricted is
weaker than an OS sandbox: shell tools run with the process's host permissions.
Restricted refuses `always-proceed`, `strict`, unknown or malformed global
permission settings; restore the verified `request-review` setting before
retrying. Nogging does not silently change the global permission mode.

Before starting, Nogging validates `.agents/hooks.json` and
`scripts/hooks/agy-guard`, then atomically adds only the selected workspace to
`~/.gemini/antigravity-cli/settings.json` trustedWorkspaces. Unrelated settings
and restrictive file permissions are preserved. Missing guards or failed trust
writes refuse launch before tmux creation. Do not grant trust to an entire
parent directory as a workaround.

The Python PreToolUse guard denies malformed/unknown write-capable payloads,
command-floor matches and execution writes under `openspec/`. Planning writes
require the planning role and a fresh canonical main-checkout planning lock;
closed sentinels take precedence. Linked worktrees share canonical lock state.
An execution session remains read-only even while another planner has a lock.
Multi-edit tool payloads remain unsupported until validated live.

**Sandbox operation is unsupported.** A profile requesting `sandbox = true`
or the wrapper receiving `--sandbox true` refuses explicitly. No linked-worktree
sandbox lifecycle has passed acceptance. Neither authority level promises
filesystem or network isolation, and read-only mode does not supply it.

## Installed workflows and lifecycle

Install/update merges named Nogging entries in `.agents/hooks.json`, preserving
unrelated hooks and their order; remove deletes only managed entries. Helpers
include `scripts/hooks/agy-guard`, `scripts/nogg session emit turn_end`, and the
session/boundary helpers. Workflow skills install under `.agents/skills/`:
`nogging-plan`, `nogging-discovery-review`, and `nogging-sync-now`. They run the
same `scripts/nogg` steps as other runtimes. Planning commits precede
materialization, and safe integrated-worktree cleanup precedes `plan-end`.

Each supervised process sets `AGY_CLI_DISABLE_AUTO_UPDATE=true`. Stop events
capture the actual conversationId and append lifecycle events. Resume uses an
exact recorded ID, never a latest-conversation fallback:

```bash
scripts/nogg session launch --agent agy --role lead --bead <claimed-bead> \
  --cwd <implementation-worktree> --resume <recorded-conversation-id>
```

Use `session list`, `session log <name>`, `session send <name> <message>` and
`session stop <name>` for supervision. The initial interactive turn must finish
and emit Stop before kickoff/send proceeds; kickoff is delivered once.
A bare launch grants no claim or implementation permission.

Antigravity specialists run as separate supervised sessions, each on exactly
one Bead already claimed by the Main Worker:

```bash
scripts/nogg session launch --agent agy --role specialist:<type> \
  --bead <claimed-bead> --cwd <implementation-worktree>
```

Specialists never claim, re-status, close or commit; they never write OpenSpec.
They return a structured result and discoveries to the Main Worker, who owns
validation, evidence, closure and commits. Do isolated small slices inline
when a separate session is unnecessary. The orchestrator remains Claude-only.

## Validation limits

Headless exit zero and `status: SUCCESS` do not prove execution: observed hook
denials and timeouts can still produce those values without `denied_actions`.
Check expected effects, captured hook events and timeout stderr. Exact resume
has supervised core acceptance evidence, including exact-ID memory recall.
`/usage` observations include weekly and five-hour group buckets,
but quota gating, exhausted-credit classification and complete model mapping
are pending AGR-005. Do not advertise them as available or close issue #54
from core runtime evidence alone. Human acceptance signatures stay blank.
