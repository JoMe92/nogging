'use strict';

// The install manifest. Source paths are relative to the package root
// (the checkout of this repo that `npx` runs); destination paths are relative
// to the target git repository root.
//
// File classes:
//   verbatim  - copied and overwritten on every `init` and `update`
//   docs      - reference docs, copied verbatim into docs/specforge/
//   scaffold  - written only when absent, never overwritten
//   merge     - foreign files edited idempotently (see lib/merge.js)
//   rendered  - generated from templates/ with target-specific values

module.exports = {
  // Individual files copied verbatim.
  verbatim: [
    'scripts/specforge',
    'scripts/install-hooks',
    'scripts/test',
    'scripts/specforge.test.sh',
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
    { from: '.specforge/launch-profiles', to: '.specforge/launch-profiles' },
    { from: '.specforge/launch-prompts', to: '.specforge/launch-prompts' },
  ],

  // Reference docs: package docs/<name> -> target docs/specforge/<name>.
  docs: [
    { from: 'docs/operating-model.md', to: 'docs/specforge/operating-model.md' },
    { from: 'docs/architecture.md', to: 'docs/specforge/architecture.md' },
    { from: 'docs/failure-recovery.md', to: 'docs/specforge/failure-recovery.md' },
    { from: 'docs/using-with-codex.md', to: 'docs/specforge/using-with-codex.md' },
  ],

  // Written only when the destination does not already exist.
  scaffold: [
    { from: 'openspec/config.yaml', to: 'openspec/config.yaml' },
    { from: 'templates/openspec-project.md', to: 'openspec/project.md' },
    {
      from: 'templates/specforge-config.json',
      to: '.specforge/config.json',
      transform: 'specforgeConfig',
    },
  ],

  // chmod 0755 after copying (destination-relative).
  executable: [
    'scripts/specforge',
    'scripts/install-hooks',
    'scripts/test',
    'scripts/check-branch-name',
    'scripts/hooks/commit-msg',
    'scripts/hooks/pre-commit',
    'scripts/hooks/pre-push',
    'scripts/hooks/pre-tool-use-openspec-guard',
  ],

  // Lines ensured present in the target .gitignore (under a SpecForge comment).
  gitignore: [
    '.specforge/locks/',
    '.specforge/state/',
    '.specforge/reports/',
    '__pycache__/',
    '*.py[cod]',
  ],

  // Marker block maintained inside CLAUDE.md and AGENTS.md.
  markerBegin: '<!-- specforge:begin -->',
  markerEnd: '<!-- specforge:end -->',

  // Rendered systemd units: template -> target basename pattern ({slug} filled in).
  systemd: [
    {
      from: 'templates/systemd/specforge-sync.service.tmpl',
      to: 'systemd/specforge-sync-{slug}.service',
    },
    {
      from: 'templates/systemd/specforge-sync.timer.tmpl',
      to: 'systemd/specforge-sync-{slug}.timer',
    },
  ],
};
