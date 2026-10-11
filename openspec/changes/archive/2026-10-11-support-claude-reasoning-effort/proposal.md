## Why

Claude Code exposes a session-scoped `--effort` flag, but Nogging currently supports reasoning effort only for Codex. Operators need a validated Claude launch setting with predictable precedence and durable provenance, without changing their global configuration.

## What Changes

- Accept optional `effort` in Claude JSON launch profiles and `session launch --effort <level>` for Claude.
- Select launch override, then profile effort, then native runtime behavior; validate the five advertised Claude levels.
- Forward the selection through the supervised wrapper as Claude's native `--effort`, including exact-conversation resumes.
- Record reasoning effort and its source and show both in session listings; preserve legacy records.
- Keep Codex `model_reasoning_effort` and its existing forwarding intact and reject cross-agent effort settings.
- Add helper compatibility negotiation, installed-payload regressions and operator documentation.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `launch-profiles`: Claude effort selection, validation, forwarding, provenance and compatibility.

## Impact

Execution will update `scripts/nogg`, `scripts/session-launch`, launch-profile examples and maintained session/architecture documentation, plus focused and installed-payload tests. No new dependencies or user-global settings writes are required. Shipped profiles retain their current defaults. This change plans implementation only.
