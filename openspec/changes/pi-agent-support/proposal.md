# Add Pi as a third supported agent

## Why

SpecForge's `session launch --agent {claude,codex}` is already agent-neutral
plumbing (`agent-neutral-launch`). A third CLI coding agent, Pi
(`https://pi.dev/`), fits the same shape but has a materially different
safety model that the launch mechanics must account for rather than paper
over:

- Repo-local `AGENTS.md` (plus parent directories) and repo-local prompt
  templates (`.pi/prompts/*.md`, triggered with `/name`) are read directly —
  no `CODEX_HOME`-only gap like the one `codex-followups` had to fix
  (SPEC-51d).
- Pi ships **no native sandbox**: its own docs state built-in tools "read
  files, write files, edit files, and run shell commands with the
  permissions of the pi process" — no execution-policy file, no command
  allow/deny list, no path-write restriction, no network control. Codex has
  `--sandbox`/`--ask-for-approval`/`network_access`; Claude has the
  `PreToolUse` hook. Pi has neither.
- Pi extensions (`.pi/extensions/*.ts`) can intercept the `tool_call` event
  and block a call before it runs — a genuine, in-process hook point, the
  direct analogue of Claude's `PreToolUse` guard — but project-local
  extensions load only after a one-time, per-machine "project trust"
  decision (`~/.pi/agent/trust.json`), which a non-interactive launch must
  grant explicitly per run (`--approve`) rather than as a standing
  `defaultProjectTrust: always`.

## What Changes

- `session launch --agent pi` joins `claude` and `codex` in
  `scripts/session-launch` and the `--agent` choices.
- A new `.pi/extensions/specforge-guard.ts` enforces the SpecForge command
  floor (the same denied-command class as `.codex/rules/specforge.rules`
  and the Claude floor) and the `openspec/` write boundary, using the
  `tool_call` event — this is Pi's floor, built because Pi ships none.
- **Honesty over false parity:** Pi's `restricted` authority level is
  floor-only — no network or filesystem sandbox exists under it. Docs and
  `doctor` say this plainly; it is not presented as equivalent to Codex's
  `restricted` (which does disable network).
- Repo-local `.pi/prompts/{plan,discovery-review,sync-now}.md`, mirroring
  `.claude/commands/` and `.codex/prompts/`; no `pi-prompts-link` helper is
  needed (unlike Codex) because Pi reads `.pi/prompts/` directly.
- `AGENTS.md` *Tool notes* gains a **Pi** subsection; Pi specialists run
  out-of-process (`session launch --agent pi --role specialist:<type>`),
  same as Codex, since Pi has no in-process subagent mechanism.
- `scripts/specforge doctor` reports Pi availability (informational) and
  whether the guard extension is trusted for this project.
- **Modified capability:** `agent-neutral-launch`. **New capability:**
  `pi-onboarding` (mirrors `codex-onboarding`).

## Impact

- No change to existing Claude or Codex behavior.
- New file classes for the installer: `.pi/extensions/` (verbatim),
  `.pi/prompts/` (verbatim) — both ride the package `files` list, same
  pattern as the Codex payload.
