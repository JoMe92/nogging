# Design

## Decision 1: a single `shutil.which`-backed helper, no shell-out

Replace both call sites with:

```python
def tool_on_path(name):
    return shutil.which(name) is not None
```

`shutil.which` walks the process's own `os.environ["PATH"]` in-process. It
cannot be defeated by a login shell's `/etc/profile.d` scripts because it
never spawns a shell at all. It is also strictly cheaper (no subprocess).

Rejected alternative: keep `sh -c` (drop only `-l`). This would fix the
reproduced bug, but still spawns a shell and inherits its `hash` table /
builtins semantics for no benefit over the stdlib call — `shutil.which` is
the simpler fix and removes a whole class of "which shell, which profile"
questions.

## Decision 2: a regression test that cannot pass by accident

The existing `cxf-doctor` scenario stubs a `codex` binary into a `$work/bin`
prepended to `PATH` and expects `doctor` to see it. That test's pass/fail
today depends on whether the *test host's* real `sh -l` resets `PATH` —
exactly the nondeterminism this change removes from production code, so the
test must not reintroduce it.

Instead, the added test places a **hostile `sh` stub** ahead of the real one
in the test's `$work/bin`: given `-lc "command -v ..."` it always exits 1
regardless of the command, simulating the worst case (a profile script that
wipes `PATH` entirely). Both the base prerequisite check (`OK git`) and the
`codex`-prompts NOTE must still detect their targets correctly with this
hostile `sh` in `PATH` ahead of the real one — proving detection never
shells out to `sh -l` at all. This test fails against the pre-fix code
(which calls the hostile stub and gets a false "not found") and passes
after.

## Decision 3: one new spec requirement, not two

`codex-onboarding`'s existing requirement ("`doctor` SHALL report whether
`codex` is on `PATH`") is still true after this fix and needs no wording
change. The gap is that *nothing* previously specified how any of doctor's
five tool checks must determine "on PATH" — that requirement is new, added
to `run-recovery` (doctor's existing capability home), and it covers all
five checks by construction since they share one helper.
