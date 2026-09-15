# Compatibility policy and matrix

This page defines the supported environment for Nogging 2.0.x. “Supported”
means the project claims the combination and supplies CI or recorded manual
evidence. “Optional” means the core local workflow works without the component.
Versions newer than the validated baseline are expected to work within the same
major release but remain unverified until CI or acceptance records them.

## Runtime and tool baseline

| Component | Supported baseline | Evidence |
| --- | --- | --- |
| Node.js | 18, 20, and 22 LTS; minimum 18.0.0 | CI compatibility matrix; `package.json` engine |
| Python | 3.9 through 3.13; minimum 3.9 | CI compatibility matrix |
| Git | 2.30 or newer | CI on Ubuntu; acceptance host |
| GNU Bash | 4.4 or newer | CI on Ubuntu; acceptance host |
| OpenSpec CLI | 1.11.x; validated with 1.11.0 | `npm ci` lock plus OpenSpec validation CI |
| Beads (`bd`) | 1.2.x; validated with 1.2.2 | real-backend acceptance; mechanically stubbed unit tests |
| Dolt | 2.3.x; validated with 2.3.1 | real-backend acceptance; mechanically stubbed unit tests |
| tmux | 3.2 or newer, optional | supervised-session tests plus acceptance host |
| systemd user manager | systemd 252 or newer, optional | generated-unit tests plus Linux acceptance host |

Node 18 is sufficient for the installer. The optional Pi CLI has its own higher
Node requirement (22.19 or newer), which does not raise Nogging's core minimum.
Run `./scripts/nogg doctor`; it reports missing required tools and points to
this baseline. Exact upstream CLI version formats are deliberately not used as
a hard gate, because they are not stable APIs.

## Platforms and architectures

| Environment | Status | Evidence or boundary |
| --- | --- | --- |
| Ubuntu Linux, x86_64 | Supported | GitHub Actions runs functional, install, validation, and acceptance jobs |
| Debian-family Linux, aarch64 | Supported | dated Raspberry Pi acceptance report and maintainer-host full suite |
| Other Linux distributions / architectures | Experimental | run `doctor`, the full suite, and the acceptance runbook before relying on them |
| macOS, Windows, WSL | Unsupported for 2.0.x | no release gate covers path, shell, service-manager, or sandbox behavior |
| systemd user services | Optional, supported on declared Linux hosts | install may use `--no-systemd`; generated units are tested |
| Other service managers | Unsupported | use manual `./scripts/nogg sync --now`; no persistent-unit claim |

Architecture-neutral shell and Python code does not by itself establish
support. A platform moves to supported only after its automated or dated manual
acceptance evidence is linked here.

## Agent integrations

| Agent path | Status and validated version | Important boundary |
| --- | --- | --- |
| Claude Code | Supported; validated with 2.1.260 | restricted/trusted profiles and hooks are tested; orchestrator is Claude-only |
| OpenAI Codex CLI | Supported; validated with 0.148.0 | repo rules require workspace trust; prompt discovery needs the documented link helper |
| Pi coding agent | Supported on Linux; validated with 0.85.0 | requires Node 22.19+ and has no filesystem/network sandbox |
| Other agents | Unsupported | they may read `AGENTS.md`, but no adapter or release evidence is supplied |

The word “supported” covers Nogging's integration, not a guarantee about an
agent vendor's model behavior or service availability. Review the
[security and threat model](security-model.md) before selecting an authority
level.

## Evidence policy

CI exercises every supported Node and Python version. The main workflow covers
Ubuntu x86_64; the release-candidate acceptance report supplies real-backend,
aarch64, tmux, systemd, and agent-path evidence. If that evidence is missing,
expired, or records a deviation, the corresponding row is not release-ready.
Optional paths may be absent, but a path claimed as supported may not be silently
skipped.

Current evidence entry points:

- [CI workflow](https://github.com/JoMe92/nogging/actions/workflows/nogging-validate.yml)
- [Acceptance runbook](https://github.com/JoMe92/nogging/blob/develop/docs/acceptance.md)
- [Latest recorded Raspberry Pi acceptance](https://github.com/JoMe92/nogging/blob/develop/docs/acceptance/2026-09-14-raspberrypi.md)
- [Codex integration evidence and limitations](using-with-codex.md)
- [Pi integration evidence and limitations](using-with-pi.md)
