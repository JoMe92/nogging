# Design — codex-followups

## Context

Two discoveries from `codex-onboarding`:

- **`SPEC-247`** — `.codex/rules/specforge.rules` forbids `git push`
  unconditionally, and `scripts/session-launch` passes
  `sandbox_workspace_write.network_access=false` for every Codex authority
  level (both `.codex.toml` profiles carry `network_access = false`). A trusted
  Codex Lead session therefore cannot push a branch or push `develop`.
- **`SPEC-51d`** — Codex v0.148 loads custom prompts only from
  `$CODEX_HOME/prompts/`; repo `.codex/prompts/` is inert (upstream
  openai/codex#4734, #9848), and custom prompts are being deprecated for skills.

`codex execpolicy` on v0.148 has no per-profile or alternate-directory rules
selection — it is all project+user `.rules`, or `--ignore-rules` (which drops
*both* project and user rules and cannot re-supply a floor). So a "trusted rules
variant" is not achievable on this version.

## Decision 1 — the Codex `.rules` file carries only the always-on floor

`.codex/rules/specforge.rules` is trimmed to mirror the Claude `FLOOR_DENY`
set exactly — the classes that are denied in *every* Claude session regardless
of profile:

```
sudo · rm -rf · rm -fr · dd · mkfs(+variants) · shutdown · reboot · systemctl · chown · curl · wget
```

Removed from the file: `git push`, `git remote`, `git config`, `bd sync`,
`bd dolt push|pull|clone`, `dolt push|pull|remote`. These mirror the
**restricted profile** (`restricted.json`), not the floor.

**Rationale.** For a Codex session every one of those removed commands is a
remote/network operation (or, for `git remote`/`git config`, a local op that is
harmless and that the Claude trusted path allows anyway). The restricted-profile
boundary for remote operations is already enforced by the **network-off
workspace-write sandbox** (`network_access=false`): `git push`, `bd sync`,
`dolt push|pull` all fail with no network. Keeping a second, execpolicy-level
copy of that denial is only meaningful if it can be made profile-specific — and
on codex 0.148 it cannot, so it just blocks the trusted path. One mechanism per
concern: the floor is the `.rules` file, the profile is the sandbox.

`session-launch` still never passes `--ignore-rules`; the floor always applies.

## Decision 2 — the trusted / `--full-access` Codex path enables network

`trusted.codex.toml` sets `network_access = true`; `restricted.codex.toml` keeps
`network_access = false`. `scripts/session-launch` is made explicit in both
directions: `--network on` now emits
`-c 'sandbox_workspace_write.network_access=true'` (rather than omitting the
override and depending on the codex default), `--network off` emits
`=false` as today.

A trusted Codex Lead session can then run `git push` (branch) and
`git push origin develop` to complete an integration, exactly like the Claude
trusted path. A restricted Codex session still has no network and still cannot
push.

**Symmetry with Claude.** Claude `trusted.json` allows `git push` and does not
sandbox the network at the OS level; `curl`/`wget`/`WebFetch` stay denied. Codex
trusted mirrors this: network on for `git`, but `curl`/`wget` remain in the
floor `.rules` and are still refused.

## Decision 3 — a repo helper links the Codex prompts into `$CODEX_HOME`

New subcommand:

```
scripts/specforge codex-prompts-link [--unlink]
```

- Links every `.codex/prompts/*.md` in the repo to
  `${CODEX_HOME:-$HOME/.codex}/prompts/specforge-<basename>.md` as a symlink
  (creating the target dir if needed). Idempotent: an existing correct symlink
  is left; a wrong target is repointed; a real file that is not our symlink is
  left untouched and reported.
- `--unlink` removes only the `specforge-*` symlinks this command created.
- Prints what it linked / would need the operator to resolve.

`scripts/specforge doctor` gains one informational line — never a failure:

```
NOTE  codex prompts present in .codex/prompts/ but not linked into <CODEX_HOME>/prompts/
      (run: ./scripts/specforge codex-prompts-link)
```

printed only when `codex` is on `PATH`, the repo has `.codex/prompts/*.md`, and
at least one is not linked.

**Why opt-in, not automatic in `init`/`update`.** `npx github:… init` writing
into `$HOME` is a surprise and a machine-specific side effect that does not
belong in a repo-scoped install. The helper is one command, documented, and
reversible. `docs/using-with-codex.md` also keeps the pointer that the
auto-loaded `.agents/skills/` openspec skills are the upstream-aligned way to
run the same flows from Codex, so an operator who does not link prompts is not
stuck.

## Risks / open questions

- Removing the execpolicy `git push` rule means a *restricted* Codex session
  that somehow had network (misconfigured `network_access`) could push. Mitigated
  by `restricted.codex.toml` pinning `network_access = false` and a test that
  asserts the restricted launch emits the `=false` override.
- If upstream codex adds repo-scoped prompts or per-profile rules, the helper
  and Decision 1 can be revisited; both are small and self-contained.

## Test plan

- `codex execpolicy check --rules .codex/rules/specforge.rules -- git push`
  → no decision (unmatched); `-- sudo apt` / `-- rm -rf /` → `forbidden`.
- `scripts/session.test.sh`: a `--full-access` codex launch emits
  `--network on` / `network_access=true`; a restricted codex launch emits
  `--network off` / `network_access=false`. (Flips the current
  `codex-full: network disabled` assertion.)
- `scripts/specforge.test.sh`: `codex-prompts-link` creates the symlinks under a
  stubbed `CODEX_HOME`, is idempotent, `--unlink` removes them, a non-symlink
  collision is reported not clobbered; `doctor` prints the NOTE when prompts are
  unlinked and omits it once linked, and the NOTE never changes the exit code.
- `scripts/cli.test.sh`: the trimmed `.codex/rules/specforge.rules` still ships
  and still contains the floor classes.
