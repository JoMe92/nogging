'use strict';

// The install manifest. Source paths are relative to the package root
// (the checkout of this repo that `npx` runs); destination paths are relative
// to the target git repository root.
//
// File classes:
//   verbatim  - copied and overwritten on every `init` and `update`
//   docs      - reference docs, copied verbatim into docs/nogging/
//   scaffold  - written only when absent, never overwritten (by `update` too
//               when the item sets onUpdate)
//   merge     - foreign files edited idempotently (see lib/merge.js)
//   rendered  - generated from templates/ with target-specific values

module.exports = {
  // Individual files copied verbatim.
  verbatim: [
    'scripts/nogg',
    'scripts/nogg_usage.py',
    'scripts/nogg_usage_zai.py',
    'scripts/lib/session_backend.py',
    'scripts/lib/agent_routing.py',
    'scripts/lib/loop_schedule.py',
    'scripts/lib/loop_config.py',
    'scripts/lib/loop_state.py',
    'scripts/lib/loop_runner.py',
    'scripts/lib/loop_cli.py',
    'scripts/lib/session_backend_tmux.py',
    'scripts/lib/session_backend_herdr.py',
    'scripts/lib/session_codex_delivery.py',
    'scripts/lib/session_signals.py',
    'scripts/lib/session_hooks.py',
    'scripts/lib/session_dispatch.py',
    'scripts/lib/session_pause.py',
    'scripts/lib/session_wake.py',
    'scripts/lib/session_warm.py',
    'scripts/lib/token_usage_adapters.py',
    'scripts/lib/token_usage_antigravity.py',
    'scripts/lib/token_usage_collect.py',
    'scripts/lib/token_usage_report.py',
    'scripts/lib/token_usage_store.py',
    'scripts/lib/token_usage_sync.py',
    'scripts/lib/test-env.sh',
    'scripts/lib/test-fixture-config.sh',
    'scripts/session-launch',
    'scripts/openspec-sandbox',
    'scripts/session-log-writer',
    'scripts/session-pty-recorder',
    'scripts/install-hooks',
    'scripts/test',
    'scripts/nogg.test.sh',
    'scripts/loop-cli.test.sh',
    'scripts/agent-routing.test.sh',
    'scripts/loop-tick.test.sh',
    'scripts/loop-docs.test.sh',
    'scripts/worktree-workflow.test.sh',
    'scripts/check-branch-name',
    'scripts/hooks/commit-msg',
    'scripts/hooks/pre-commit',
    'scripts/hooks/pre-push',
    'scripts/hooks/pre-rebase',
    'scripts/hooks/agy-guard',
    'scripts/hooks/pre-tool-use-openspec-guard',
    'scripts/hooks/pre-tool-use-lead-launch-guard',
    'scripts/hooks/session-start-cloud-bootstrap',
    'scripts/hooks/commit-msg.test.sh',
    'scripts/pre-rebase-guard.test.sh',
    'scripts/hooks/branch-name.test.sh',
    'scripts/hooks/pre-tool-use-lead-launch-guard.test.sh',
    'scripts/hooks/session-start-cloud-bootstrap.test.sh',
    'templates/claude/orchestrator-permissions.example.json',
  ],

  // Directories copied verbatim (recursive).
  verbatimDirs: [
    { from: '.agents/skills', to: '.agents/skills' },
    { from: 'templates/antigravity/skills', to: '.agents/skills' },
    // The Claude Code payload: specialist definitions and repository-scoped
    // workflow commands. Settings remain under mergeClaudeSettings() so a
    // target repository's unrelated Claude configuration is preserved.
    { from: '.claude/agents', to: '.claude/agents' },
    { from: '.claude/commands', to: '.claude/commands' },
    // The Codex payload: the execpolicy floor (.codex/rules/) and the workflow
    // prompts (.codex/prompts/). Both ride the package "files" list.
    // mergeCodex() preserves a `bd`-written .codex/hooks.json separately.
    { from: '.codex/rules', to: '.codex/rules' },
    { from: '.codex/prompts', to: '.codex/prompts' },
    // The Pi payload: the workflow prompts (.pi/prompts/) and the guard
    // extension (.pi/extensions/), Pi's project-local floor since it has no
    // native sandbox or execution-policy mechanism. Both ride the package
    // "files" list.
    { from: '.pi/prompts', to: '.pi/prompts' },
    { from: '.pi/extensions', to: '.pi/extensions' },
    // The Nogging Pi extension home (.pi/nogging/): opt-in extensions such as
    // glm-usage, enabled per repository through `pi_extensions`. Shipping the
    // tree enables nothing; templates/nogging-config.json scaffolds [].
    { from: '.pi/nogging', to: '.pi/nogging' },
    // launch-profiles ships both the Claude settings files (<level>.json) and
    // the Codex launch specs (<level>.codex.toml); the whole directory rides
    // along, and package.json "files" lists it.
    { from: '.nogging/launch-profiles', to: '.nogging/launch-profiles' },
    { from: '.nogging/launch-prompts', to: '.nogging/launch-prompts' },
  ],

  // Reference docs: package docs/<name> -> target docs/nogging/<name>.
  docs: [
    { from: 'docs/operating-model.md', to: 'docs/nogging/operating-model.md' },
    { from: 'docs/architecture.md', to: 'docs/nogging/architecture.md' },
    { from: 'docs/compatibility.md', to: 'docs/nogging/compatibility.md' },
    { from: 'docs/failure-recovery.md', to: 'docs/nogging/failure-recovery.md' },
    { from: 'docs/using-with-codex.md', to: 'docs/nogging/using-with-codex.md' },
    { from: 'docs/using-with-pi.md', to: 'docs/nogging/using-with-pi.md' },
    { from: 'docs/using-with-antigravity.md', to: 'docs/nogging/using-with-antigravity.md' },
    { from: 'docs/using-with-herdr.md', to: 'docs/nogging/using-with-herdr.md' },
    { from: 'docs/security-model.md', to: 'docs/nogging/security-model.md' },
    { from: 'docs/worktree-workflow.md', to: 'docs/nogging/worktree-workflow.md' },
    { from: 'docs/model-selection.md', to: 'docs/nogging/model-selection.md' },
    { from: 'docs/token-usage.md', to: 'docs/nogging/token-usage.md' },
    { from: 'docs/scheduled-loops.md', to: 'docs/nogging/scheduled-loops.md' },
    { from: 'docs/session-wake.md', to: 'docs/nogging/session-wake.md' },
  ],

  // Written only when the destination does not already exist.
  scaffold: [
    { from: 'openspec/config.yaml', to: 'openspec/config.yaml' },
    { from: 'templates/openspec-project.md', to: 'openspec/project.md' },
    {
      from: 'templates/nogging-config.json',
      to: '.nogging/config.json',
      transform: 'noggingConfig',
    },
    // onUpdate: also scaffolded by `update`, so upgraded installs gain it.
    {
      from: 'templates/model-selection.json',
      to: '.nogging/model-selection.json',
      onUpdate: true,
    },
  ],

  // chmod 0755 after copying (destination-relative).
  executable: [
    'scripts/nogg',
    'scripts/session-launch',
    'scripts/openspec-sandbox',
    'scripts/session-log-writer',
    'scripts/install-hooks',
    'scripts/test',
    'scripts/check-branch-name',
    'scripts/hooks/commit-msg',
    'scripts/hooks/pre-commit',
    'scripts/hooks/pre-push',
    'scripts/hooks/pre-rebase',
    'scripts/hooks/agy-guard',
    'scripts/hooks/pre-tool-use-openspec-guard',
    'scripts/hooks/pre-tool-use-lead-launch-guard',
    'scripts/hooks/session-start-cloud-bootstrap',
  ],

  // Lines ensured present in the target .gitignore (under a Nogging comment).
  gitignore: [
    '.nogging/locks/',
    '.nogging/state/',
    '.nogging/reports/',
    '__pycache__/',
    '*.py[cod]',
  ],

  // Marker block maintained inside CLAUDE.md and AGENTS.md.
  markerBegin: '<!-- nogging:begin -->',
  markerEnd: '<!-- nogging:end -->',

  // Rendered systemd units: template -> target basename pattern ({slug} filled in).
  systemd: [
    {
      from: 'templates/systemd/nogg-sync.service.tmpl',
      to: 'systemd/nogg-sync-{slug}.service',
    },
    {
      from: 'templates/systemd/nogg-sync.timer.tmpl',
      to: 'systemd/nogg-sync-{slug}.timer',
    },
    {
      from: 'templates/systemd/nogg-orchestrator.service.tmpl',
      to: 'systemd/nogg-orchestrator-{slug}.service',
    },
    {
      from: 'templates/systemd/nogg-loops.service.tmpl',
      to: 'systemd/nogg-loops-{slug}.service',
    },
    {
      from: 'templates/systemd/nogg-loops.timer.tmpl',
      to: 'systemd/nogg-loops-{slug}.timer',
    },
  ],
};
