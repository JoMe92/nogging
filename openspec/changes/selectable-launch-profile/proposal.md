# Make the launch authority of a supervised session selectable

## Why

`scripts/specforge session launch` always starts Claude under one fixed
authority: `.specforge/session-launch-profile.json` (deny `git push`, remote
Dolt sync, destructive shell, network) plus the no-autonomous-claim system
prompt `.specforge/session-launch-prompt.md`. There is no supported way to run a
supervised session with broader authority — for example a trusted autonomous run
that works a whole change, commits per Bead, pushes its own branch, and merges
to `develop` when green.

Today the only options are:

- hand-launch `claude` in tmux with a different `--settings` file, which loses
  the metadata record, the append-only log, and the whole
  `list`/`attach`/`stop`/`cleanup` lifecycle; or
- edit the shared `.specforge/session-launch-profile.json` in place, which
  changes the authority of *every* launch and is easy to forget to revert.

The same seam is needed for Codex support (`docs/source/codex-support-analysis.md`,
C7/C8): a Codex launch has to map a chosen authority level onto Codex's
`--sandbox` / `--ask-for-approval` model rather than a Claude `permissions`
file.

## What Changes

- **`session launch` accepts `--profile <name-or-path>` and `--prompt
  <name-or-path>`.** A bare name resolves under `.specforge/launch-profiles/` /
  `.specforge/launch-prompts/`; anything else is treated as a filesystem path.
  With neither flag the behaviour is exactly as today.
- **Named profiles ship in the repo.** `.specforge/launch-profiles/restricted.json`
  (the current profile, still the default) and
  `.specforge/launch-profiles/trusted.json` (allows `git push`, `git merge`,
  `git switch`, `bd`, `openspec`, `scripts/*`, `npx`; `defaultMode: acceptEdits`;
  still no `sudo`, no network). A matching
  `.specforge/launch-prompts/autonomous.md` authorises end-to-end execution of a
  named change. No `bypassPermissions` profile is shipped — that requires the
  operator to pass their own file explicitly.
- **A non-removable command floor.** `session launch` merges a fixed deny-list
  (`rm -rf` / `rm -fr`, `dd`, `mkfs*`, `sudo`, `shutdown`, `reboot`, fork bombs)
  into the effective settings of *any* profile before starting Claude. No
  profile, named or supplied, can grant these.
- **The effective settings are written per session and recorded.** `session
  launch` writes the merged, floored settings to
  `.specforge/state/sessions/<name>.settings.json`, passes that to Claude, and
  records the profile name and the effective-settings path in the metadata.
  `session list` shows the profile each session runs under.
- **`--full-access` convenience alias** = `--profile trusted --prompt autonomous`.

## Capabilities

### New Capabilities

- `launch-profiles`: a supervised session runs under a selectable, recorded
  authority profile, with a fixed command floor no profile can lift and the
  restricted profile as the default.

### Modified Capabilities

<!-- none -->

## Impact

- New code: `scripts/specforge` (`session_launch` signature, `--profile` /
  `--prompt` / `--full-access` args, name-or-path resolution, floor merge,
  effective-settings file, metadata field, `session list` column).
- New files: `.specforge/launch-profiles/{restricted,trusted}.json`,
  `.specforge/launch-prompts/autonomous.md`.
- Modified: `bin/lib/manifest.js` (ship the two new directories verbatim),
  `.specforge/config.json` (optional `session_launch_profile_dir` /
  `session_launch_prompt_dir` keys, defaulted), `docs/operating-model.md`,
  `docs/running-work-in-sessions.md`, `AGENTS.md`, `scripts/session.test.sh`.
- `.specforge/session-launch-profile.json` and `.specforge/session-launch-prompt.md`
  become thin pointers to / copies of the `restricted` entries for back-compat
  with the existing `session_launch_profile` / `session_launch_prompt` config
  keys.
- Behavioural change: the default launch is unchanged. A `trusted` /
  `--full-access` session is a deliberate authority grant the operator makes on
  the command line and can always see in `session list`.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
