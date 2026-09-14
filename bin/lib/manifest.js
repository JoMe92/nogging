'use strict';

// The install manifest. Source paths are relative to the package root
// (the checkout of this repo that `npx` runs); destination paths are relative
// to the target git repository root.
//
// File classes:
//   verbatim  - copied and overwritten on every `init` and `update`
//   docs      - reference docs, copied verbatim into docs/nogging/
//   scaffold  - written only when absent, never overwritten
//   merge     - foreign files edited idempotently (see lib/merge.js)
//   rendered  - generated from templates/ with target-specific values

module.exports = {
  // Individual files copied verbatim.
  verbatim: [
    'scripts/nogg',
    'scripts/install-hooks',
    'scripts/test',
    'scripts/nogg.test.sh',
    'scripts/worktree-workflow.test.sh',
    'scripts/check-branch-name',
    'scripts/hooks/commit-msg',
    'scripts/hooks/pre-commit',
    'scripts/hooks/pre-push',
    'scripts/hooks/pre-tool-use-openspec-guard',
    'scripts/hooks/commit-msg.test.sh',
    'scripts/hooks/branch-name.test.sh',
  ],

  // Directories copied verbatim (recursive).
  verbatimDirs: [
    { from: '.agents/skills', to: '.agents/skills' },
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
    { from: 'docs/failure-recovery.md', to: 'docs/nogging/failure-recovery.md' },
    { from: 'docs/using-with-codex.md', to: 'docs/nogging/using-with-codex.md' },
    { from: 'docs/worktree-workflow.md', to: 'docs/nogging/worktree-workflow.md' },
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
  ],

  // chmod 0755 after copying (destination-relative).
  executable: [
    'scripts/nogg',
    'scripts/install-hooks',
    'scripts/test',
    'scripts/check-branch-name',
    'scripts/hooks/commit-msg',
    'scripts/hooks/pre-commit',
    'scripts/hooks/pre-push',
    'scripts/hooks/pre-tool-use-openspec-guard',
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
  ],
};
