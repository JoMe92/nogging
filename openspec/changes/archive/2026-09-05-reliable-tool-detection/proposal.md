# Reliable tool-presence detection in doctor

## Why

`scripts/specforge` decides whether `git`, `python3`, `bd`, `dolt`, and `codex`
are available by shelling out to a **login shell**:

```python
subprocess.run(["sh", "-lc", f"command -v {cmd}"], capture_output=True)
```

`sh -lc` re-sources `/etc/profile` and `/etc/profile.d/*` before running the
command. On a stock Debian/Raspberry Pi OS host those scripts unconditionally
reassign `PATH`, discarding anything the invoking process had prepended (a
local `~/bin`, `nvm`, `asdf`, or — reproduced below — a test's stub binary).
The result: `doctor` can report a tool as "not installed" even though it is on
the caller's actual `PATH`.

Reproduced directly:

```
$ PATH="/tmp/x/bin:$PATH" sh -c  'command -v codex'   # -> found
$ PATH="/tmp/x/bin:$PATH" sh -lc 'command -v codex'   # -> exit 127, PATH reset by /etc/profile.d
```

This is not theoretical — it is why `scripts/specforge.test.sh`'s
`cxf-doctor` scenario (the "codex prompts unlinked" NOTE, added by
`codex-followups`) **fails on this host today**, while presumably passing in
CI, because GitHub's `ubuntu-latest` runners don't reset `PATH` the same way
Raspberry Pi OS's `/etc/profile.d` scripts do. A detection mechanism whose
correctness depends on which profile scripts happen to run on the host is not
reliable, in tests or in the field.

There are two call sites with the exact same pattern: the base prerequisite
checks (`OK git` / `python3` / `bd` / `dolt`) and the Codex-prompt-link NOTE
added by `codex-onboarding`.

## What Changes

- Replace both `sh -lc "command -v <tool>"` call sites in `scripts/specforge`
  with a single `tool_on_path(name)` helper backed by Python's `shutil.which`
  — no subprocess, no shell, so detection can no longer be defeated by a
  login shell's profile scripts.
- Add a regression test that proves detection never shells out to `sh -l`,
  instead of relying on the test host's own profile scripts happening to
  agree or disagree with the bug (the reason this slipped through CI).
- **Modified capability:** `run-recovery` (doctor's tool-presence checks gain
  an explicit PATH-fidelity requirement covering all five checked tools).

## Impact

- No behavior change for a healthy host where PATH already agrees between
  contexts. On any host where it doesn't (the common case that motivated
  this fix), `doctor` becomes strictly more correct, never less.
- No new dependency — `shutil` is stdlib.
