# Using Nogging with Antigravity

The optional `agy` integration uses the same Beads, Git and OpenSpec workflow
as other Nogging agents. The investigated Linux runtimes are **agy 1.3.2**
(core) and **agy 1.3.3** (quota). Unsigned core and quota live evidence is
recorded in the
[core acceptance report](https://github.com/JoMe92/nogging/blob/develop/docs/acceptance/2026-10-10-antigravity-core.md);
human acceptance is separate and not declared here. See the
[contract investigation](https://github.com/JoMe92/nogging/blob/develop/docs/acceptance/antigravity-contract-investigation.md)
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
Human acceptance signatures stay blank.

Runtime state grants are configured with `agent_state_roots` in
`.nogging/config.json`. Declaration does not grant access: a Bead label
`agent-state:antigravity` or launch option `--agent-state antigravity` selects
Antigravity state for a related session. Codex receives those existing
HOME-contained directories as sandbox writable roots. Records and listings
show the source and paths. Treat granting credential-bearing state as write
access to those credentials. See [Codex runtime state grants](using-with-codex.md).

## Quota and the launch gate

Launch admission uses the runtime's read-only `/usage` result for the model
group that contains the selected model: the weekly and five-hour buckets are
evaluated separately against `usage_gate`, and a denial exits 75 **before** the
guard check, trust preparation, worktree or tmux work, naming the latest
limiting reset. Groups are independent pools. Set a model with `--model`, a
profile `model` or `--tier`: with no model, or one outside the known families
(Gemini Flash/Pro, Claude Opus/Sonnet, GPT-OSS), usage is **unknown** and the
launch warns (or is denied under `usage_gate.on_unknown: "deny"`), never
admitted on another group's headroom. A failed, timed-out, denied or
non-`SUCCESS` probe is unknown as well; exit status zero is not trusted.

```bash
scripts/nogg usage --agent agy --model gemini-3.8-flash-medium --json
```

The probe runs `agy --print /usage` from a private directory with runtime
auto-update disabled and caches only sanitized buckets (owner-only) under
`$XDG_CACHE_HOME/nogging/usage/`. `AGY_NOGG_USAGE_PROBE=0` disables the
probe. `session resume-when-ready` waits for the latest reset among all
exhausted buckets, so a still-exhausted weekly bucket outlasts the 5h reset.
The pane adapter reports `idle`, `working`, `needs_input` and `limit` to
`session list`/`watch`; the limit wording is imported, not observed live.
Quota percentages are provider estimates for this account, not cost.
