## Why

Nogging currently hard-codes Claude Code as its always-on Orchestration Agent. Operators cannot start a Codex orchestrator or reach that managed orchestrator through Happier; a separately created Happier session lacks Nogging's singleton, supervision and lifecycle guarantees.

## What Changes

- Support Claude Code and Codex under the same orchestrate-only persona, with explicit runtime selection and the existing takeover and human sign-off rules.
- Add an operator-facing `orchestrator start --agent claude|codex` command, preserve `run`, `status`, `stop` and `restart`, and persist the selection across service restart and reboot. Legacy installations default to Claude.
- Separate runtime selection from remote access: retain native Claude Remote Control, support native Codex on tmux, and add an explicitly selected Happier control mode for Codex. The documented mobile path is `orchestrator start --agent codex --control happier`.
- Preserve one canonical supervisor, lock and managed tmux session per repository across runtimes. Switching requires a confirmed stop; selection never replaces a live orchestrator implicitly.
- Resume only the selected runtime's recorded orchestrator conversation. Record runtime identity, remote session identity, readiness, effective authority and failure evidence without treating a regular Happier session as an orchestrator.
- Ship a Codex host-access orchestrator profile that retains existing execpolicy denials; keep Claude's existing unrestricted exception. Show effective authority per runtime.
- Refuse unattended startup before launching a runtime unless the exact repository and required runtime configuration layers are already explicitly trusted by the operator. Startup must not create global trust.
- Sanitize inherited Happier initial-input, session and lifecycle environment; verify both owned local processes and remote state when stopping.
- Retest the incomplete compatibility checks from SPEC-8prb under this revised contract before dependent implementation.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `orchestration-agent`: dual-runtime lifecycle, explicit start and switch behavior, exact conversation recovery, Codex Happier access and remote readiness.
- `launch-profiles`: runtime-specific authority: Claude retains its existing exception; Codex retains the command floor under a role-scoped host-access profile, without widening ordinary roles.

## Impact

Affected surfaces include `scripts/nogg`, `scripts/session-launch`, orchestrator session records and canonical state, the systemd template and installer, `.nogging/launch-profiles`, the shared orchestrator prompt, Codex/Claude operator entry points, package payloads, diagnostics and operations/security documentation. Happier remains optional for native control. Its supported CLI lifecycle, exact resume and effective Codex policy must be verified in a bounded compatibility task before implementation depends on them.

The 2026-10-21 report in draft PR #269 (commit `9ea8e91`) is historical negative evidence: danger-full-access/never retained execpolicy, wrapped startup added global scratch trust, and inherited pending input contaminated a new session. Exact Happier resume remains unverified. These findings are folded into this revision, not treated as successful acceptance.

This change plans behavior only. It does not start a service, convert the existing standalone Happier session, migrate conversations between providers, add other runtimes, or sign human acceptance.
