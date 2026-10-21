## Why

Nogging currently hard-codes Claude Code as its always-on Orchestration Agent. Operators cannot start a Codex orchestrator or reach that managed orchestrator through Happier; a separately created Happier session lacks Nogging's singleton, supervision and lifecycle guarantees.

## What Changes

- Support Claude Code and Codex under the same orchestrate-only persona, with explicit runtime selection and the existing takeover and human sign-off rules.
- Add an operator-facing `orchestrator start --agent claude|codex` command, preserve `run`, `status`, `stop` and `restart`, and persist the selection across service restart and reboot. Legacy installations default to Claude.
- Separate runtime selection from remote access: retain native Claude Remote Control, support native Codex on tmux, and add an explicitly selected Happier control mode for Codex. The documented mobile path is `orchestrator start --agent codex --control happier`.
- Preserve one canonical supervisor, lock and managed tmux session per repository across runtimes. Switching requires a confirmed stop; selection never replaces a live orchestrator implicitly.
- Resume only the selected runtime's recorded orchestrator conversation. Record runtime identity, remote session identity, readiness, effective authority and failure evidence without treating a regular Happier session as an orchestrator.
- Ship a role-scoped Codex orchestrator authority profile, compatible payloads, updated operating guidance and isolated regression/live acceptance coverage.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `orchestration-agent`: dual-runtime lifecycle, explicit start and switch behavior, exact conversation recovery, Codex Happier access and remote readiness.
- `launch-profiles`: Codex orchestrator authority and strict isolation of the existing orchestrator exception from every other role.

## Impact

Affected surfaces include `scripts/nogg`, `scripts/session-launch`, orchestrator session records and canonical state, the systemd template and installer, `.nogging/launch-profiles`, the shared orchestrator prompt, Codex/Claude operator entry points, package payloads, diagnostics and operations/security documentation. Happier remains optional for native control. Its supported CLI lifecycle, exact resume and effective Codex policy must be verified in a bounded compatibility task before implementation depends on them.

This change plans behavior only. It does not start a service, convert the existing standalone Happier session, migrate conversations between providers, add other runtimes, or sign human acceptance.
