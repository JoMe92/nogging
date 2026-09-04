# Tasks

- [x] TASK-RTD-001 Add a `tool_on_path(name)` helper to `scripts/specforge` using `shutil.which(name) is not None`; replace both `subprocess.run(["sh", "-lc", f"command -v {cmd}"], ...)` call sites (the base prerequisite checks and the codex-prompts NOTE) with it; import `shutil` if not already imported.
- [x] TASK-RTD-002 Extend `scripts/specforge.test.sh`: add a hostile `sh` stub ahead of the real one in the test's stubbed `$work/bin` that always fails a `-lc "command -v ..."` invocation regardless of the target command; assert the base `OK git` prerequisite check and the `cxf-doctor` codex-prompts NOTE both still correctly detect their stubbed targets with this hostile `sh` in PATH, proving detection never shells out to a login shell.
- [ ] TASK-RTD-003 Run `scripts/test` clean on a host whose real `/etc/profile.d` resets PATH (this repo's current host qualifies); record the before/after result (failing `cxf-doctor` checks now passing) as the Bead's evidence note.
