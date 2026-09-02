# Design

## Context

The launch path today:

```
specforge session launch --role … --bead … [--profile …] [--prompt …] [--full-access]
  └─ session_launch()  (scripts/specforge)
       resolved_launch_pair()  → (profile_path .json, label, prompt_path .md)
       load_profile_settings() → dict with a "permissions" object
       merge_floor()           → FLOOR_DENY unioned into permissions.deny
       writes .specforge/state/sessions/<name>.settings.json  (the effective file)
       inner = [scripts/session-launch, --settings <eff>, --prompt <md>, --cwd …, --bead …]
       tmux new-session -d -s <name> -c <cwd> -- <inner>
       tmux pipe-pane -o  → scripts/session-log-writer
  └─ scripts/session-launch
       exec claude --settings <eff> --append-system-prompt "$(cat <md>)" [--permission-mode plan]
```

Everything above `scripts/session-launch` is agent-neutral. The wrapper is the
only place `claude` is named and the only place a Claude-specific flag
(`--settings`, `--append-system-prompt`, `--permission-mode`) appears.

Codex CLI (v0.148.0, verified on the Pi):

| Need | Claude Code | Codex |
| --- | --- | --- |
| working root | (cwd) | `-C, --cd <dir>` |
| authority | `--settings <permissions.json>` (`allow`/`deny`, `defaultMode`) | `-s, --sandbox read-only\|workspace-write\|danger-full-access`, `-a, --ask-for-approval untrusted\|on-request\|never`, `--approve-for-me` |
| extra system instruction | `--append-system-prompt <text>` | leading `[PROMPT]` arg, or an `AGENTS.override.md` |
| network | in the `deny` list (`WebFetch`, `curl`, `wget`) | `--sandbox-state-disable-network`, or config `sandbox_workspace_write.network_access = false` |
| per-command allow/deny | `permissions.allow` / `permissions.deny` globs | execpolicy `.rules` — `prefix_rule(pattern=[…], decision="allow"\|"deny")`, loaded from `~/.codex/rules/` and project `.rules` |
| plan/read-only mode | `--permission-mode plan` | `--sandbox read-only` |
| config overrides | (n/a) | `-c key=value` (dotted TOML path) |
| headless | (n/a) | `codex exec [PROMPT]` |

Codex reads `AGENTS.md` hierarchically (`AGENTS.override.md` > `AGENTS.md` >
fallbacks). It has SessionStart/UserPromptSubmit/PreCompact/PostCompact hooks
via `.codex/hooks.json` (already shipped by `bd init`) but **no per-tool-call
pre-hook** — execpolicy `.rules` is the pre-exec mechanism.

## Goals / Non-goals

- Goal: `session launch --agent codex` starts Codex under the same supervision
  (tmux server, record, log, lifecycle) and the same authority levels as Claude.
- Goal: the default and `--agent claude` are byte-for-byte unchanged.
- Goal: the operator always sees which agent a session runs.
- Goal: `restricted` / `trusted` mean the same *intent* for both agents.
- Non-goal: the write boundary — `openspec/` protection is
  `tool-agnostic-write-boundary`. This change only wires the agent.
- Non-goal: shipping the `.codex/rules/specforge.rules` floor file or any
  installer `.codex/` merge — that is `codex-onboarding`.
- Non-goal: in-process specialists for Codex, or MCP. A Codex specialist run is
  an out-of-process `session launch --agent codex --role specialist:<type>`,
  which this change makes possible; `codex-onboarding` documents it.
- Non-goal: `codex exec` (headless) as the launch mode — see the decision below.
- Non-goal: materializing Beads or editing implementation files in this planning
  session.

## Decisions

### `--agent` selection and default

`session launch` gains `--agent {claude,codex}`. When absent it reads
`session_agent` from `.specforge/config.json`, default `"claude"`. The metadata
record gains `"agent": "<name>"`. `session list` gains an `AGENT` column between
`OWNER` and `PROFILE` (a `_agent_display` sibling to `_profile_display`; a record
from before this column existed shows `claude`, the historical default).

### Codex launch profiles as `.codex.toml` fragments

`.specforge/launch-profiles/` gains, alongside `restricted.json` /
`trusted.json`, a Codex spec per level:

```toml
# restricted.codex.toml
sandbox            = "workspace-write"
ask_for_approval   = "on-request"
network_access     = false

# trusted.codex.toml
sandbox            = "workspace-write"
ask_for_approval   = "never"
network_access     = false
```

`session_launch` resolves the level with the existing name-or-path rules, then:

- **`--agent claude`**: exactly today — resolve `<level>.json`, `merge_floor`,
  write the effective settings, pass `--settings`.
- **`--agent codex`**: resolve `<level>.codex.toml` (same directory,
  `.codex.toml` suffix; a supplied `--profile /path.toml` is used directly). Map
  its keys to wrapper arguments. There is no per-session "effective settings"
  file to write for Codex — the floor is enforced by the `.codex/rules/`
  directory (see below), and `--profile /some.json` for a Codex launch is a hard
  error ("that is a Claude profile"). The record still stores `profile` (the
  level label); `effective_settings_path` is null for a Codex session.

`--full-access` fills `trusted` / `autonomous` for whichever flag is unset,
per agent.

### The floor, for Codex

FLOOR_DENY (`rm -rf`, `sudo`, `dd`, `mkfs`, `shutdown`, `reboot`) has no Codex
`--settings` equivalent. For a Codex session, `session_launch` starts Codex with
`CODEX_HOME` unchanged but ensures the repo's `.codex/rules/` is on Codex's
project-rules search path (Codex loads project `.rules` from the working tree by
default; `--cd <repo>` is enough). The `.codex/rules/specforge.rules` file that
expresses the floor as `prefix_rule(..., decision="deny")` lines is shipped by
`codex-onboarding`; this change only asserts (a `session.test.sh` check with a
stub `codex`) that the wrapper does **not** pass `--ignore-rules` and does **not**
pass `--dangerously-bypass-approvals-and-sandbox` unless the operator explicitly
supplied a profile that asks for it. If `.codex/rules/specforge.rules` is absent
at launch time (e.g. before `codex-onboarding` lands, or a hand-set repo),
`session launch --agent codex` prints a warning naming the missing floor file
and continues.

### The wrapper dispatch

`scripts/session-launch` gains `--agent <name>` (default `claude` for
back-compat). New args for the codex branch: `--sandbox`, `--approval`,
`--network` (`on`/`off`), passed by `session_launch`. Structure:

```sh
case "$agent" in
  claude)
    set -- --settings "$settings"
    [ -f "$prompt" ] && set -- "$@" --append-system-prompt "$(cat "$prompt")"
    [ "$read_only" -eq 1 ] && set -- "$@" --permission-mode plan
    exec claude "$@" ;;
  codex)
    set -- --cd "$cwd" --sandbox "${read_only:+read-only}${read_only:-$sandbox}" \
           --ask-for-approval "$approval"
    [ "$network" = off ] && set -- "$@" -c 'sandbox_workspace_write.network_access=false'
    # leading prompt: the tool-neutral instruction file, verbatim
    exec codex "$@" "$( [ -f "$prompt" ] && cat "$prompt" )" ;;
esac
```

Interactive `codex` (not `codex exec`) is chosen so the operator can `session
attach` and drive it exactly as with Claude today; `codex exec` is headless and
would break the attach workflow. No secret is ever an argument (unchanged rule);
any token Codex needs comes from its own `CODEX_HOME/auth.json`.

### Redaction

`redact_argv` already scrubs secret-named env values from the recorded
`command`. Extend `SECRET_NAME_RE` coverage is not needed, but add a check that a
`-c` override value is redacted the same way (a `-c 'foo.token="…"'` must not
reach the record verbatim).

### `doctor`

`doctor()` iterates a fixed tool list (`git`, `python3`, `bd`, `dolt`). Add
`codex` — but as a **warning**, not a checked failure, since Codex is optional.
The simplest shape: keep the existing loop for the required tools, then a
separate "optional tools" line that reports `codex` present/absent without
affecting the exit code.

## Risks / open questions

- **`--sandbox read-only` vs `--permission-mode plan`.** For a `--read-only`
  Codex session the sandbox is forced to `read-only` regardless of the level.
  Confirm Codex still lets the model *propose* edits in that mode (it should,
  they just cannot be applied) so an operator can review a plan.
- **Codex project `.rules` discovery.** The design assumes Codex loads
  `<repo>/.codex/rules/*.rules` when run with `--cd <repo>`. Execution must
  verify this against v0.148 (a `codex --cd <tmp> …` smoke test with a deny rule)
  before relying on it for the floor; if project `.rules` are not auto-loaded,
  fall back to `-c 'projects."<path>".rules_path=…'` or a `CODEX_HOME` overlay
  and record the finding.
- **`AGENTS.md` as the Codex system channel.** The `autonomous` /
  `no-autonomous-claim` prompt is passed as the leading `[PROMPT]`. If a future
  Codex version ignores a long leading prompt, the fallback is a transient
  `AGENTS.override.md` written into the working tree for the session and removed
  on cleanup — noted, not built.
- **`session_agent` config default.** Kept `claude` so no existing install
  changes behaviour. An installed repo that wants Codex sets the key or passes
  `--agent codex`.
- Stub `codex` for the tests the same way `session.test.sh` stubs `tmux` / `bd`
  (a PATH-injected script that logs its argv), so the suite stays offline.
