## Why

SpecForge defines Claude Code specialist agents and workflow commands, and its
installed documentation tells consumer repositories to use them, but the
installer does not copy those files and the packed distribution excludes them.
Consumer repositories therefore receive an incomplete Claude integration.

## What Changes

- Ship `.claude/agents/` and `.claude/commands/` as versioned installer payloads.
- Refresh both directories on `init` and `update`, consistently with the Codex
  and Pi prompt payloads.
- Include the Claude payload in the package produced for `npx github:` installs.
- Add installer tests covering fresh, packed, update, and idempotent delivery.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `installer`: Require the installer and packed distribution to deliver and
  refresh the complete Claude Code agent and command payload.

## Impact

The install manifest, npm package allowlist, and installer CLI tests change.
Fresh and existing consumer repositories gain the repository-owned Claude Code
definitions on their next `init` or `update`; no runtime API or dependency is
changed.
