# Design

## Context

`session_launch(role, bead, cwd, read_only, owner)` in `scripts/specforge`
resolves two files from config with hard-coded keys:

```python
profile = (ROOT / scfg("session_launch_profile", ".specforge/session-launch-profile.json")).resolve()
prompt  = (ROOT / scfg("session_launch_prompt",  ".specforge/session-launch-prompt.md")).resolve()
inner   = [wrapper, "--settings", profile, "--prompt", prompt, "--cwd", workdir, "--bead", bead]
```

`scripts/session-launch` (the tmux entrypoint) already takes `--settings` and
`--prompt` as arguments and does nothing profile-specific itself, so the change
is entirely in the Python one level up: choose which files to pass, and post-
process them into a per-session effective settings file.

The restricted profile denies `git push`, `git remote`, `bd`/`dolt` remote sync,
a set of destructive shell commands, `sudo`, `systemctl`, `curl`/`wget`,
`WebFetch`, with `defaultMode: default` (prompt before acting). The paired
prompt tells the session that being launched is not permission to claim a Bead.

## Goals / Non-goals

- Goal: run a supervised session under a broader, named authority without losing
  the supervision lifecycle or editing a shared file.
- Goal: the authority a session runs under is always visible after the fact.
- Goal: a small set of destructive commands can never be enabled by any profile.
- Goal: the default (no flags) is byte-for-byte the current behaviour.
- Goal: the abstraction is tool-neutral enough that a future Codex launch maps a
  profile name onto Codex sandbox/approval flags.
- Non-goal: a security sandbox. A `trusted` session can push and merge; the floor
  and the visibility are guard rails, not a boundary against a hostile agent.
- Non-goal: shipping a `bypassPermissions` profile.
- Non-goal: changing `scripts/session-launch`, the metadata lifecycle, the log
  pipe, or `attach`/`stop`/`cleanup`.
- Non-goal: materializing Beads or editing implementation files in this planning
  session.

## Decisions

### Name-or-path resolution

`--profile X`: if `.specforge/launch-profiles/X.json` exists, use it; else treat
`X` as a path (absolute, or relative to the repo root). Same rule for
`--prompt X` against `.specforge/launch-prompts/` with a `.md` suffix. The
directories are overridable via `session_launch_profile_dir` /
`session_launch_prompt_dir` config keys, defaulted to those paths. Resolution
failure is a hard error before any tmux session is created.

### Shipped profiles

| File | `defaultMode` | Adds vs restricted | Still denied |
| --- | --- | --- | --- |
| `restricted.json` | `default` | — (identical to today's file) | push, remote sync, destructive shell, `sudo`, `systemctl`, network |
| `trusted.json` | `acceptEdits` | `allow`: `Bash(git push:*)`, `Bash(git merge:*)`, `Bash(git switch:*)`, `Bash(git rebase:*)`, `Bash(bd:*)`, `Bash(openspec:*)`, `Bash(npx:*)`, `Bash(scripts/*)` | the floor (below), `sudo`, `systemctl`, `curl`/`wget`, `WebFetch` |

`restricted` stays the resolved default so an un-flagged `session launch` is
unchanged. `.specforge/session-launch-profile.json` is kept as a copy of
`restricted.json` (or a pointer) so the existing `session_launch_profile` config
key keeps working for anyone who set it.

### The non-removable floor

Before writing the effective settings, `session_launch` unions a fixed
`FLOOR_DENY` list into `permissions.deny`:

```
Bash(rm -rf:*)  Bash(rm -fr:*)  Bash(sudo:*)  Bash(dd:*)  Bash(mkfs:*)
Bash(mkfs.*:*)  Bash(shutdown:*)  Bash(reboot:*)  Bash(:(){ :|:& };:)
```

The floor is applied to `--profile`-supplied files too, including arbitrary
paths. It is deliberately short — enough to stop an accident or a prompt-injected
`rm -rf ~`, not a substitute for OS-level isolation. Document it as such.

### Effective-settings file

`session_launch` reads the chosen profile JSON, unions the floor into
`permissions.deny`, and writes the result to
`.specforge/state/sessions/<name>.settings.json`. That path — not the source
profile — is passed to `scripts/session-launch --settings`. The source profiles
are never mutated. The metadata record gains:

```json
"profile": "trusted",
"effective_settings_path": ".specforge/state/sessions/<name>.settings.json"
```

`_archive_log` / `cleanup` also removes the effective-settings file when the
record is retired.

### Prompt pairing and `--full-access`

`--profile` and `--prompt` are independent; either can be given alone.
`.specforge/launch-prompts/autonomous.md` states: *you are authorised to execute
the named change end to end — claim each Bead the operator named or that the
change scopes, implement, run `scripts/test`, commit per Bead with the
`[<id>]` token, push this branch, and merge to `develop` once the change is
complete and green; you still never edit `openspec/`, you still record
discoveries, you still never touch another change's Beads.*

`--full-access` is sugar for `--profile trusted --prompt autonomous`. It exists
so the common case is one obvious flag rather than two.

### `session list` display

Add a short `PROFILE` column (values are short: `restricted`, `trusted`, or the
basename of a supplied path). Keep the row within a sensible width by trimming
the `WORKING_DIR` column if needed; `restricted` may render as `-` to keep the
default case quiet.

## Risks / open questions

- A `trusted` autonomous session that pushes and merges is a real authority
  grant. Mitigations: the operator types the flag, `session list` shows it, the
  floor holds, and `session log --follow` still works. This is the Product
  Owner's call, consistent with "merge by an authorised session" in `CLAUDE.md`.
- **Interaction with `enforce-conventional-branching`.** A `trusted` session that
  pushes a branch carrying pre-fix `chore(sync)` commits (no `SpecForge-Writer:`
  trailer) can trip the CI `invariants` job — the W5 / `SPEC-3ur` discovery in
  `docs/source/crash-resilience-handoff.md`. The `autonomous` prompt should tell
  the session to fast-forward-merge locally (as the human operator has been
  doing) rather than open a PR, or to stop the sync timer for the branch. Call
  this out in the prompt and the docs; do not try to solve the timer problem
  here.
- **Codex mapping (forward-looking, not built here).** `--profile restricted` →
  Codex `--sandbox workspace-write --ask-for-approval on-request` (network off);
  `--profile trusted` → `--sandbox workspace-write --ask-for-approval never`
  with a network/`danger` decision. The profile *name* is the tool-neutral
  handle; the per-tool translation belongs to the Codex change.
- `claude` settings schema drift: keep both shipped profiles minimal and the
  floor list short so a schema change is a small edit.
- If `--profile` names a path that does not parse as JSON with a `permissions`
  object, fail before launch with a clear message rather than starting Claude
  unconstrained.
