## Context

`scripts/session-launch` builds the Codex sandbox from a fixed set of writable roots (shared Git directory, the worktree's own gitdir) plus the operator opt-in `NOGG_CODEX_EXTRA_WRITABLE_ROOTS` (SPEC-e7oa), which `scripts/nogg session launch` forwards into the tmux session. The opt-in is per shell, invisible in the session record and must be remembered by hand on every launch. The Antigravity runtime keeps state, including its OAuth token, in `~/.gemini/antigravity-cli`; a Codex Lead cannot run `agy` without it being writable.

The SPEC-9085 and SPEC-2e64 incidents showed that Codex sandbox capability (writable `.git`, SSH through the user namespace, test hermeticity) is only discovered when a worker fails. The SPEC-93hk work established that project settings cannot configure Claude `autoMode`, and that broad allow rules do not make auto mode equivalent to bypass. SPEC-u57h delivered owner-requested autonomous Claude defaults without an approved task.

## Goals / Non-Goals

**Goals:** configuration-driven, validated, visible agent state roots applied without manual environment variables; early, non-failing visibility of Codex sandbox capability; a reviewed permission template for interactive orchestrator sessions; formal traceability for SPEC-u57h.

**Non-Goals:** widening any session by default; granting `$HOME` or paths outside it; changing Claude, Pi or Antigravity sandboxes; writing user-global settings; making `scripts/test` hermetic (separate follow-up); changing SSP/SCM/CSL/GSU/AGR tasks.

## Decisions

### Decision 1 — `agent_state_roots` config key, grant by explicit relation

`.nogging/config.json` gains `agent_state_roots`: an object mapping a normalized agent name (`antigravity`; the `agy` alias normalizes to it; `claude`, `codex`, `pi` accepted for symmetry) to a list of directory strings, each absolute or `~/`-prefixed. The shipped template declares `{"antigravity": ["~/.gemini/antigravity-cli"]}` so a fresh install needs no hand edit. A missing key means `{}`.

Declaring a root grants nothing. A session is *related* to agent X, and receives X's roots, only when its Bead carries the label `agent-state:<X>` or the launch passes `--agent-state <X>` (repeatable; needed for Bead-less planning sessions). The label is read from the same read-only `bd show` that launch already performs. This keeps the SPEC-e7oa "no default widening" property: the OAuth token directory becomes writable only for sessions that are deliberately tied to Antigravity work, while the operator no longer has to export anything.

Rejected: an agy-profile key (`state_roots` in `*.agy.toml`) — the roots describe the runtime, not an authority level, and would be duplicated across restricted/trusted profiles and invisible to Codex profile selection; granting to every Codex session whenever agy is installed — silent widening, exposes the token to unrelated work; a change-name list in config — coarser than the per-task label and drifts as changes are archived.

### Decision 2 — Validation fails closed before the agent starts

Every granted entry is `~`-expanded, must be absolute, is resolved with `realpath`, and must be an existing directory strictly under `realpath($HOME)` (never `$HOME` itself). A malformed key, an unknown agent name, or a violating entry for a requested relation refuses the launch before any tmux session or record is created, naming the key and entry. A declared but missing directory refuses only when that relation is requested. The granted resolved roots and their source (`label` / `option`) are written to the session record and shown by `session list`. Only Codex consumes them (as additional `sandbox_workspace_write.writable_roots`); for agents without a filesystem sandbox the grant is recorded as a no-op.

### Decision 3 — `NOGG_CODEX_EXTRA_WRITABLE_ROOTS` is retired

`session launch` no longer forwards the variable and the wrapper no longer reads it. If it is set non-empty in the launching environment, launch refuses with a message naming `agent_state_roots` and `agent-state:<agent>`, so an old habit cannot silently produce a narrower sandbox than expected.

### Decision 4 — One resolver for launch and doctor

The writable-root computation (shared Git directory, worktree gitdir, granted state roots, network setting, `GIT_SSH_COMMAND` default) moves into one resolver used by both `scripts/session-launch` and `doctor`, so diagnosis exercises exactly the policy a session gets.

### Decision 5 — Doctor sandbox diagnosis is NOTE-only, cheap by default

When `codex` is installed and exposes `codex sandbox`, plain `doctor` runs offline probes under the resolved trusted-level Codex policy: create and remove a uniquely named temporary file in the shared Git directory and in the current worktree's gitdir. `doctor --sandbox` additionally runs `git ls-remote origin` with the launcher's SSH setting (only for an SSH remote, bounded timeout) and `scripts/test` (bounded by `doctor_sandbox_test_timeout_seconds`, default 900) inside the same sandbox, reporting the failing suite names. Every outcome — pass, fail, skipped with reason — is a `NOTE` line and never changes doctor's exit status; plain doctor prints a NOTE pointing at `--sandbox` for the network and test probes. Network and full-suite probes stay opt-in because doctor runs inside `/plan` and must stay fast and offline.

### Decision 6 — Orchestrator permission template is shipped, documented, never installed

`templates/claude/orchestrator-permissions.example.json` is a Claude user-settings fragment: allow rules for the repository's sibling worktree path pattern (`<parent>/<repo>-*/**`) and `scripts/nogg` commands, and a deny list that contains every `FLOOR_DENY` entry plus history-destroying Git operations. The documentation states that allow rules do not bypass the auto-mode classifier (broad shell grants are suspended in auto mode and the classifier can still refuse, e.g. security-boundary edits), that `autoMode` is read only from user settings, and that the template is applied by the operator by hand. A test keeps the template valid JSON and its deny list a superset of `FLOOR_DENY`. The installer never writes it into any settings file. The implementing task verifies every claim against the installed Claude Code version and official documentation and records any disagreement as a discovery instead of documenting an unverified claim.

### Decision 7 — SPEC-u57h is mapped, not re-implemented

A task and requirement describe the delivered behavior (configured default profile/prompt, profile label taken from the configured file's name, documented hosted-Cloud settings). The planning session labels the existing Bead SPEC-u57h with this change and task before materialization, so materialize creates no duplicate. The Main Worker verifies commit 1ae9dab on develop and closes it through the normal LIMBO playbook without new implementation.

## Risks / Trade-offs

- A labelled Antigravity session can overwrite the Antigravity OAuth token → scoped to deliberately labelled work, recorded and listed; documented in the security model.
- `codex sandbox` behavior differs between Codex builds → probes report `skipped (unsupported)` rather than failing.
- Removing the environment variable breaks an operator's shell habit → explicit refusal message names the replacement.

## Migration Plan

New installs receive the template default. An existing config without the key resolves to `{}` and is never rewritten by `nogg update`; `doctor` prints a NOTE when `agy` is installed but no `antigravity` root is declared, naming the key to add.
