# Close the two Codex follow-up gaps found during codex-onboarding

## Why

`codex-onboarding` shipped and archived with two non-blocking discoveries
recorded against it (`SPEC-247`, `SPEC-51d`). Both are real limitations that
make the Codex path second-class today:

- **A `--full-access` (trusted) Codex Lead session cannot complete an
  integration.** `.codex/rules/specforge.rules` forbids `git push`
  unconditionally, and the Codex launch passes
  `sandbox_workspace_write.network_access=false` for *every* authority level. So
  a trusted Codex session can commit and `git merge --ff-only` locally but can
  neither `git push` its branch nor `git push origin develop`. The Claude
  trusted path handles this through `trusted.json`'s allow list; the Codex path
  has no equivalent. `agent-neutral-launch` mapped the authority *names* but not
  this behavioural difference.
- **Codex v0.148 does not read repo-scoped `.codex/prompts/`.** It loads custom
  prompts only from `$CODEX_HOME/prompts/` (`~/.codex/prompts/`). The three
  shipped prompt files (`plan`, `discovery-review`, `sync-now`) are
  version-controlled but inert until the operator hand-copies them, and upstream
  is deprecating custom prompts in favour of skills anyway
  (openai/codex#4734, #9848).

Neither blocked `codex-onboarding`, but both should be closed before the Codex
path is presented as an equal to Claude Code.

## What Changes

- **The Codex execpolicy floor is trimmed to the always-on `FLOOR_DENY`
  mirror.** `.codex/rules/specforge.rules` keeps only the command classes the
  Claude launch floor *always* denies (`sudo`, recursive force-delete, `dd`,
  `mkfs`/variants, `shutdown`, `reboot`, `systemctl`, `chown`, `curl`, `wget`).
  The `git push` / `git remote` / `git config` / `bd sync` / `bd dolt
  push|pull|clone` / `dolt push|pull|remote` rules — which mirror the
  *restricted profile*, not the floor — are removed. For a Codex session, the
  restricted-profile boundary for every remote operation is the **network-off
  workspace-write sandbox**, exactly as `network_access=false` already provides.
- **The trusted / `--full-access` Codex path enables network.** `scripts/session-launch`
  (and `restricted.codex.toml` / `trusted.codex.toml`) set
  `sandbox_workspace_write.network_access=true` for the trusted authority level
  and keep it `false` for restricted. A trusted Codex Lead session can then
  `git push` its branch and `git push origin develop` to finish an integration,
  matching the Claude trusted path.
- **A repo helper links the Codex prompts into `$CODEX_HOME`.**
  `scripts/specforge codex-prompts-link [--unlink]` idempotently symlinks
  `.codex/prompts/*.md` into `~/.codex/prompts/` as `specforge-<name>.md`.
  `scripts/specforge doctor` prints an informational NOTE when the repo prompts
  exist but are not linked, naming the helper; the absence of the link is never
  a failure. `docs/using-with-codex.md` replaces the manual copy instructions
  with the helper and keeps the note that the auto-loaded `.agents/skills/`
  openspec skills are the upstream-aligned path.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `codex-onboarding`: the authority floor requirement is narrowed to the
  always-on `FLOOR_DENY` mirror (remote-operation denial for a restricted Codex
  session is the network-off sandbox); a new requirement states a trusted Codex
  session can complete an integration; a new requirement covers the
  prompt-linking helper and its `doctor` NOTE.

## Impact

- Modified code: `.codex/rules/specforge.rules`, `scripts/session-launch` /
  `load_codex_spec` and `.specforge/launch-profiles/{restricted,trusted}.codex.toml`,
  `scripts/specforge` (`codex-prompts-link` subcommand, `doctor` NOTE),
  `scripts/session.test.sh` / `scripts/specforge.test.sh`,
  `docs/using-with-codex.md`.
- Behavioural change: a restricted Codex session loses the execpolicy-level
  `git push` refusal but keeps the *effective* refusal (network is off); a
  trusted Codex session gains working network so it can push.
- Resolves `SPEC-247` and `SPEC-51d`.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
