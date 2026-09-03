# Tasks

## SPEC-247 — a trusted Codex session can complete an integration

- [x] TASK-CXF-001 Trim `.codex/rules/specforge.rules` to the always-on floor only per design "Decision 1": keep the `FLOOR_DENY` mirror (sudo, rm -rf/-fr, dd, mkfs+variants, shutdown, reboot, systemctl, chown, curl, wget); remove the `git push` / `git remote` / `git config` / `bd sync` / `bd|dolt` remote-sync rules; rewrite the header comment. Re-verify with `codex execpolicy check` that kept rules are `forbidden` and `git push|commit|merge` / `bd` / `npx` are unmatched.
- [x] TASK-CXF-002 Set `network_access = true` in `.specforge/launch-profiles/trusted.codex.toml` (keep `restricted.codex.toml` at `false`); update both header comments to describe the split.
- [x] TASK-CXF-003 In `scripts/session-launch`, make the codex branch emit `-c 'sandbox_workspace_write.network_access=true'` for `--network on` (not just omit it) and `=false` for `--network off`. Confirm `session_launch()` in `scripts/specforge` reads `network_access` from the `.codex.toml` and passes the matching `--network on|off`.
- [x] TASK-CXF-004 Update `docs/using-with-codex.md` per design "Decision 2": the authority table (trusted = network on / can push, restricted = network off / cannot), the execpolicy-floor section (floor = `FLOOR_DENY` mirror only), and a line that a trusted Codex Lead session now completes an integration itself (push branch, push `develop`, no PR) like the Claude trusted path.

## SPEC-51d — link the Codex prompts into `$CODEX_HOME`

- [x] TASK-CXF-005 Add `scripts/specforge codex-prompts-link [--unlink]` per design "Decision 3": symlink each `.codex/prompts/*.md` to `${CODEX_HOME:-$HOME/.codex}/prompts/specforge-<basename>.md` (mkdir target), idempotent (correct link left, wrong target repointed, non-symlink real file reported and left); `--unlink` removes only `specforge-*` symlinks. Register in the CLI dispatch and `--help`.
- [x] TASK-CXF-006 Add the `doctor` NOTE (never a failure): when `codex` is on `PATH`, `.codex/prompts/*.md` exist, and at least one is not linked into `${CODEX_HOME:-$HOME/.codex}/prompts/`, print `NOTE  codex prompts present in .codex/prompts/ but not linked into <CODEX_HOME>/prompts/ (run: ./scripts/specforge codex-prompts-link)`.
- [ ] TASK-CXF-007 Update `docs/using-with-codex.md`: replace the manual copy/symlink steps with `./scripts/specforge codex-prompts-link`; keep the note that `.agents/skills/` openspec skills are auto-loaded and upstream-aligned, and that repo-scoped `.codex/prompts/` is pending upstream (openai/codex#4734, #9848).

## Tests

- [x] TASK-CXF-008 `scripts/session.test.sh`: flip the codex-network coverage — `--full-access` codex launch emits `--network on` + `network_access=true`; restricted codex launch emits `--network off` + `network_access=false`. Update the existing `codex-full: network disabled` / `codex-wrap` assertions.
- [ ] TASK-CXF-009 `scripts/specforge.test.sh` (stub `CODEX_HOME` under `SPECFORGE_ROOT`): `codex-prompts-link` creates the `specforge-<name>.md` symlinks, is idempotent, repoints a wrong target, reports a non-symlink collision without clobbering, `--unlink` removes only `specforge-*`; `doctor` prints the prompt-link NOTE when unlinked, omits it once linked, and the NOTE never changes doctor's exit code (guard the `doctor` calls per the lint).
- [ ] TASK-CXF-010 Run `scripts/test` (confirm `cli.test.sh`: the trimmed `.codex/rules/specforge.rules` still ships with the floor classes). `npx openspec validate codex-followups --strict` green.
