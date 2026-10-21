## Context

Facts on `develop` at `4a88209`:

- `bin/lib/install.js` `copyVerbatim` passes `{ mode: 0o755 }` to
  `fsops.copyFile` only when the destination is in `manifest.executable`.
  `copyDir` (the `.agents`, `.claude`, `.nogging` payload directories) and
  `copyDocs` pass no mode. `fsops.copyFile` applies a mode only when the
  action is not `unchanged`, to the written path (`<dest>` or
  `<dest>.nogging-new`). It writes the `.orig` backup with `copyFileSync`,
  which carries the source file's mode bits.
- `scripts/session-pty-recorder` is `100755` in git, listed in
  `manifest.verbatim` and `package.json` `files`, but not in
  `manifest.executable`. `scripts/session-log-writer` is in all three. A
  comparison of the manifest with the file modes in the tree shows the
  asymmetry both ways: `session-pty-recorder` and six shipped `*.test.sh` files
  are executable upstream but unlisted, and `scripts/hooks/agy-guard` is listed
  but `100644` upstream (it runs through `python3`, so the listing is
  harmless and must keep working).
- `evaluateFileState` returns `unchanged` when the destination's digest equals
  upstream. v3.0.0 left `session-pty-recorder` with the right content and mode
  `0664`, so a second `update` takes the `unchanged` path and never reaches the
  chmod. That matches the report that re-running `update` does not help.
- `scripts/nogg doctor` checks the session helpers for
  existence and the executable bit; that is the FAIL in the issue.
- `scripts/worktree-workflow.test.sh` and `scripts/nogg.test.sh` ship to
  consumers (`manifest.verbatim`, `package.json` `files`); both source
  `scripts/lib/test-env.sh`, which ships too. Most other suites do not ship.
- Fixtures copy the host config in three shapes: `cp` in bash, `shutil.copy2` or
  `read_text/write_text` in Python heredocs, and `python3 - src dest` heredocs
  that load the JSON, edit keys and write it back. `scripts/lib/test-agents.sh`
  stubs agent binaries (`stub_agent_binaries`, `use_agent_stubs`); CI has no
  `codex` or `agy`.
- The sweep for this change copied `develop` into a scratch directory, set
  `session_backend` to `herdr` in its `.nogging/config.json` and ran every
  suite that references the host config (offline, `scripts/lib/test-env.sh`
  sourced, four in parallel). Of 68 suites, 24 failed. Re-run with the unmodified config, 21 of
  them pass, so those 21 are herdr-attributable: `antigravity-usage`,
  `codex-exact-resume`, `direct-guard-isolation`, `planning-launch-profile`,
  `planning-role`, `session`, `session-effort`, `session-launch-agent-binary`,
  `session-model-forwarding`, `session-model-record`, `session-models`,
  `session-observability`, `session-pid-identity`, `session-startup`,
  `session-tier`, `session-tier-overrides`, `session-tmux-fenced-server`,
  `session-usage-collection`, `usage-gate`, `usage-history` and
  `worktree-workflow`. The other three (`nogg`, `direct-planning-isolation`,
  `installed-diagnostics`) also fail with the unmodified config in that
  scratch copy (it was made with `git archive`, without `.git`), so the sweep
  proves nothing for them; `nogg.test.sh` copies the host config and ships to
  consumers, so it is in scope and the implementer verifies it in a full
  checkout. The flaw is therefore not specific to `worktree-workflow`: any
  fixture that launches a session through the copied config selects herdr.

## Decisions

1. **Derive the mode from the package, keep the list as an override.**
   `fsops.copyFile` decides the mode itself: an explicit `mode` argument wins
   (so `manifest.executable` keeps forcing `0755`, including `agy-guard`);
   otherwise a source file with any executable bit installs as `0755`;
   otherwise no chmod. `copyDir` and `copyDocs` need no change because the
   decision lives in `copyFile`. Source of truth is `fs.statSync(srcAbs).mode`
   of the file the installer reads, which for `npx` is the package cache, where
   npm preserves the executable bit (the issue confirms the cache holds
   `100755`). Rejected: adding `session-pty-recorder` to `manifest.executable`
   alone. It fixes today's file, not the class, and the next helper would repeat
   the bug.

2. **Which paths get the mode.** The written path in all three write actions:
   `create`, `update` and `force-overwrite` write `<dest>`, and `preserve`
   writes `<dest>.nogging-new`; each gets the decided mode. `<dest>.orig` stays
   the mode-preserving `copyFileSync` copy of the local file it backs up, and
   a test pins that, because it must not turn a local `0664` file executable.
   A preserved (locally modified) `<dest>` is never chmod-ed; it is
   target-owned.

3. **Repair in place when content already matches.** In the `unchanged` state
   the destination content equals the packaged content, so adjusting its mode is
   safe by construction. If the decided mode includes the executable bit and the
   destination lacks any of `0o111`, `copyFile` chmods it (adds the bits, never
   removes them) and logs the action as `update` with the note
   `mode 0755`, so the run report and the manifest accounting treat it as a
   change; a second run is `unchanged`. Under `--dry-run` the same entry is
   logged and nothing is written. This is what repairs the repositories that
   already ran the v3.0.0 `update`. It does not touch files that are not
   managed (no manifest entry and no baseline match end in `preserve`).

4. **A failing-first, packed regression for #263.** New
   `scripts/installer-file-mode.test.sh`, offline, no tmux or Dolt. It packs
   the repository (`npm pack --ignore-scripts`, as `packed-session-launch`
   does), extracts it, and builds an old-shaped consumer: `init` from the
   package, then delete `scripts/session-pty-recorder`, rewrite
   `.nogging/config.json` `nogging_version` to `2.2.0` and delete the installed
   manifest, so the update goes through the bundled v2.2.0 baseline exactly as
   the real upgrade did (`manifest-legacy-upgrade.test.sh` shows the fixture
   shape). Cases: legacy update creates the recorder executable; the doctor
   helper check passes for it (a fixture `bd` is not needed because the check
   inspects the file; run only that check or the doctor with the existing
   stubs, whichever the suite can do offline); a `0664` copy with matching
   content is repaired once and then `unchanged`; `--dry-run` leaves it
   `0664`; a locally modified executable helper keeps its mode and content and
   its `.nogging-new` and a `--force` overwrite are executable with the `.orig`
   keeping the local mode; and a sweep asserting that every packaged file that
   is executable in the package is executable in a fresh `init`, and that every
   `manifest.executable` entry is. The new suite must fail on `develop` before
   the fix: the recorder case and the sweep are the red cases.

5. **One helper pins the fixture backend; backend suites select explicitly.**
   Add `scripts/lib/test-fixture-config.sh`, sourced next to `test-env.sh`,
   with `copy_host_config <src> <dest> [backend]`: it reads the host JSON,
   sets `session_backend` to `backend` (default `tmux`), keeps every other key
   and value, and writes `<dest>` (creating the directory). Python-heredoc
   fixtures call it through `bash -c` or its small CLI entry so there is one
   implementation, not a bash and a Python copy. Because `nogg.test.sh` and
   `worktree-workflow.test.sh` ship, the helper is added to
   `manifest.verbatim` and `package.json` `files` next to `test-env.sh`, so an
   installed repository can run its shipped suites; the helper is covered by
   the existing package-manifest consistency checks. Rejected: also copying
   `session_backend_herdr.py` into `worktree-workflow.test.sh`. The test is not
   about the backend, the issue's own suggestion leans the same way, and
   copying herdr libraries would not give the scratch repo a herdr recorder or
   server anyway.

6. **Which suites change.** Every suite in the sweep that failed with
   `session_backend` `herdr` and whose fixture copies the host config, plus
   `worktree-workflow.test.sh` (the reported one). Each switches its host-config
   copy to `copy_host_config`. Suites that write their own minimal config
   (`printf '{}'`, `json.dumps({...})`) are not the flaw and stay as they are.
   Suites that exist to exercise herdr pass `herdr` explicitly where they copy
   the host config. The scope is the 21 suites in the Context sweep plus `nogg.test.sh`; the
   static guard of Decision 7 is the net for any copy site the sweep missed.

7. **A regression check that runs the suites under herdr.** New
   `scripts/fixture-backend-pin.test.sh`: (a) unit-checks the helper (pins
   `tmux`, honours an explicit backend, preserves `personas`, `tier_overrides`
   and unknown keys, creates the destination directory); (b) builds a scratch
   checkout from `git ls-files` (so it does not copy untracked state), sets
   `session_backend` to `herdr` in its `.nogging/config.json`, and runs the
   affected suites from that checkout offline, with `test-env.sh` sourced and
   `scripts/lib/test-agents.sh` stubs on `PATH` (CI has no `codex` or `agy`),
   failing on any nonzero exit and naming the suite; (c) a static guard that
   fails, naming the file, when a `scripts/*.test.sh` references the host
   `.nogging/config.json` as a copy source without `copy_host_config` and
   without an explicit allowlist comment. The list of suites run in (b) is the
   one in `tasks.md` and is kept in a single array in the suite; the guard in (c)
   keeps it complete. Runtime is bounded: the affected suites are run once, not
   per backend.

8. **Test discipline.** Everything here follows the offline CI rules in the
   `test-isolation` capability: no network, no real `codex`, `agy`, `claude`,
   `bd`, Dolt, tmux or herdr; agent binaries come from
   `scripts/lib/test-agents.sh`; sockets stay under 108 bytes; no PID-range or
   user-namespace assumptions.

9. **Changelog and branches.** Each task adds its own bullet under a
   `### Fixed` heading in `## [Unreleased]` of `CHANGELOG.md` (the section has
   no `### Fixed` yet; whichever task lands second appends to the existing
   heading and rebases over the first). The bullets describe the user-visible
   effect: the recorder executable after update and repaired by the next run;
   `scripts/test` no longer red under the herdr backend. Distinct branch
   prefixes: `fix/install-mode-test-pin` for the installer, `test/install-mode-test-pin`
   for the fixtures.

## Risks and open points

- npm normalises file modes on pack; the packed-install case in Decision 4
  proves the end-to-end bit and guards against a packaging change that drops it.
- Decision 3 changes the run report for repositories that hold a `0664` helper:
  they see one `update` line with `mode 0755`. That is the intended signal.
- Both tasks edit the `[Unreleased]` section of `CHANGELOG.md`; a textual
  conflict on that hunk is expected and trivial, so no ordering edge is wired.
