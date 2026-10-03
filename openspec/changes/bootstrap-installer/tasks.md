# Tasks — one-command bootstrap installer

- [ ] TASK-BSI-001 Create `scripts/bootstrap`: a standalone POSIX-compatible
      shell script. First action: check `/etc/os-release` and `uname -m`
      against the supported set (Debian/Ubuntu-family Linux, x86_64 or
      aarch64, per `docs/compatibility.md`); on a mismatch, print the exact
      supported-platform statement and exit non-zero before doing anything
      else.

- [ ] TASK-BSI-002 Add Node provisioning via `nvm`: install `nvm` itself
      (its own official installer, pinned to a specific `nvm` release) only
      if not already present; then `nvm install <pinned-LTS>` using the
      current compatibility-baseline LTS line, only if an already-present
      Node does not already satisfy it. Report which action was taken
      (skipped / installed / upgraded).

- [ ] TASK-BSI-003 Add the three npm-distributed CLI installs:
      `npm install -g @anthropic-ai/claude-code@<pin>`,
      `@openai/codex@<pin>`, `@fission-ai/openspec@<pin>` — each checked
      against an existing install's version first (skip if satisfying,
      install/upgrade otherwise). Add `@earendil-works/pi-coding-agent@<pin>`
      behind an explicit `--with-pi` flag, not installed by default.

- [ ] TASK-BSI-004 Add `bd` and `dolt` provisioning: call each project's own
      official install script at an exact pinned release-tag URL (not
      `latest`), only if an existing install does not already satisfy the
      pinned range. Verify both pinned-tag install script URLs resolve
      before relying on them (confirmed reachable during planning; recheck
      at implementation time in case either project's release-asset layout
      changed).

- [ ] TASK-BSI-005 Ensure `git`, `tmux`, and `gh` are present: check first,
      install via the system package manager only for what's missing, with
      a clear message that `sudo` will be requested and why — never a
      silent privilege escalation.

- [ ] TASK-BSI-006 Wire the final two steps: run
      `npx github:JoMe92/nogging@<pinned-tag> init` against the target
      repository (`--repo <path>` option; default current directory;
      `git init` it first if the path doesn't exist yet as a repository),
      then run `scripts/nogg doctor` and print a clear final pass/fail
      summary naming anything still missing or out of range.

- [ ] TASK-BSI-007 Add a pin-consistency test (new or appended to
      `scripts/compatibility.test.sh`) that parses `scripts/bootstrap`'s
      pinned version strings and `docs/compatibility.md`'s version table and
      fails if any pin disagrees with the documented baseline.

- [ ] TASK-BSI-008 Document the one-line command in `README.md` and
      `docs/installation.md`: `curl -fsSL
      https://raw.githubusercontent.com/JoMe92/nogging/<tag>/scripts/bootstrap
      | bash`, always pinned to a tagged release in the documented form, not
      `main`/`develop`. Document `--repo`, `--with-pi`, and re-run
      idempotency.

- [ ] TASK-BSI-009 Run `scripts/test`. Manually verify end to end in a
      throwaway container or VM matching the supported platform: a clean
      machine with nothing installed reaches a working `bd ready` inside a
      fresh target repository via the one-line command alone; a second run
      on the same machine reports everything already satisfied and changes
      nothing. Verify the platform gate (TASK-BSI-001) on an unsupported
      platform exits cleanly with the stated message and installs nothing.
