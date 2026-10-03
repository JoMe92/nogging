# Tasks — harden trusted session authority

- [x] TASK-HTA-001 In `.nogging/launch-profiles/trusted.json`, change
      `permissions.defaultMode` from `"auto"` to `"bypassPermissions"` and
      add a top-level `"skipDangerousModePermissionPrompt": true` key
      (sibling to `permissions`, matching exactly how
      `.nogging/launch-profiles/orchestrator.json` already carries it). Leave
      `allow`/`deny`/`additionalDirectories` unchanged. Closes GitHub issue
      #40.

- [x] TASK-HTA-002 In `scripts/nogg` (Python), add a `doctor` check: for every
      `.json` file directly under `.nogging/launch-profiles/` (skip
      `*.codex.toml`/`*.pi.toml` siblings), load it and print a `NOTE` when
      (a) `permissions.defaultMode == "bypassPermissions"` and the top-level
      `skipDangerousModePermissionPrompt` key is missing or not `true`, or
      (b) the file's basename is `trusted.json` or `orchestrator.json` and
      its `defaultMode` does not match the value `docs/security-model.md`
      documents for that profile (`bypassPermissions` for both, after
      TASK-HTA-001). Never raises these to a failure — `NOTE`-level only, same
      as every other `doctor` advisory.

- [x] TASK-HTA-003 Update the three places that describe `trusted`'s default
      mode as `auto`:
      `docs/operating-model.md` (*Launch profiles* section, the
      `` `trusted` (`auto`; allows ...) `` parenthetical) and
      `docs/running-work-in-sessions.md` (*Running with broader authority*,
      the `` **`trusted`** starts in `auto` and allows... `` bullet). Both
      become `bypassPermissions`, keeping the rest of each sentence (the
      `allow`/`deny` lists are unchanged). Do not change
      `docs/running-work-in-sessions.md`'s *Autonomous vs. step-by-step*
      section — that describes the generic `Shift-Tab` manual mode cycle for
      an attached session, not `trusted.json`'s configured default, and is
      unaffected by this change.

- [x] TASK-HTA-004 Add a short paragraph to `docs/security-model.md`'s
      *Vendor-specific limits* section, beside the existing "The orchestrator
      deliberately uses bypass-permission mode" sentence, extending it to
      `trusted`: both profiles ship `bypassPermissions` with
      `skipDangerousModePermissionPrompt: true`; the project's `deny` list and
      fixed command floor, not the permission mode, are the actual boundary
      for either; a project that wants the `auto`-mode classifier's extra
      review back for its own copy of `trusted` can set it, trading away the
      unattended reliability `--full-access` otherwise promises (see
      `design.md`, Decision 1, for why that tradeoff was rejected as the
      shipped default).

- [ ] TASK-HTA-005 Update the `launch-profiles` spec delta (see
      `specs/launch-profiles/spec.md` in this change) and run
      `scripts/nogg validate`. Add/extend `scripts/session.test.sh` and
      `scripts/nogg.test.sh` cases: `trusted.json` carries
      `defaultMode: "bypassPermissions"` and `skipDangerousModePermissionPrompt:
      true`; a session launched with `--full-access` runs an arbitrary
      previously-unseen shell command with no `allow`-rule match and no
      interactive prompt is simulated (effective settings written reflect
      `bypassPermissions`); the new `doctor` check fires a `NOTE` for a fixture
      profile missing `skipDangerousModePermissionPrompt`, and for a fixture
      `trusted.json`-named file with a drifted `defaultMode`, and is silent for
      the real shipped files. Run `scripts/test` and confirm it passes.
