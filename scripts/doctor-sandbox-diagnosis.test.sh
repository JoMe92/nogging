#!/usr/bin/env bash
# TASK-ASD-002: doctor's NOTE-only Codex sandbox diagnosis.
#
# Every probe must run INSIDE `codex sandbox` under the shared resolver's
# policy, so a root the sandbox does not grant must be reported as not
# writable even though the host itself can write it. Checked against a
# deterministic `codex` stub (always) and the real `codex sandbox` (when this
# host has a build that supports it): writable and not-granted roots, absent
# and unsupported codex, non-SSH remote, bounded scripts/test probe with
# failing-suite names and timeout, no residue, agent_state_roots WARN/NOTE,
# and an unchanged doctor exit status.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")" && pwd)/nogg" <<'PY'
import contextlib, io, json, os, shutil, stat, subprocess, sys, tempfile
from pathlib import Path
from importlib.machinery import SourceFileLoader

m = SourceFileLoader("nogg_sandbox_test", sys.argv[1]).load_module()
fails = 0
def check(cond, msg):
    global fails
    print(("ok - " if cond else "not ok - ") + msg)
    if not cond: fails += 1

def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()

STUB = r'''#!/usr/bin/env python3
# Minimal `codex sandbox` stand-in: honours writable_roots for touch probes and
# runs everything else unchanged. UNSUPPORTED=1 mimics a build without it.
import json, os, sys
a = sys.argv[1:]
if os.environ.get("STUB_UNSUPPORTED") or not a or a[0] != "sandbox":
    sys.exit(2)
if a[1:] == ["--help"]:
    sys.exit(0)
cmd = a[a.index("--") + 1:]
roots = [json.loads(v.split("=", 1)[1]) for k, v in zip(a, a[1:])
         if k == "-c" and v.startswith("sandbox_workspace_write.writable_roots=")][0]
if cmd[:2] == ["sh", "-c"] and "touch" in cmd[2]:
    target = os.path.dirname(cmd[-1])
    if not any(target == r or target.startswith(r + "/") for r in roots):
        print(f"touch: cannot touch '{cmd[-1]}': Read-only file system", file=sys.stderr)
        sys.exit(1)
os.execvp(cmd[0], cmd)
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp).resolve()
    repo, wt = tmp / "repo", tmp / "linked"
    git("init", "-q", str(repo))
    git("-C", str(repo), "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "init", "--allow-empty")
    git("-C", str(repo), "worktree", "add", "-qb", "linked", str(wt))
    common = Path(git("-C", str(wt), "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    own = Path(git("-C", str(wt), "rev-parse", "--absolute-git-dir")).resolve()
    stubdir = tmp / "stub"; stubdir.mkdir()
    (stubdir / "codex").write_text(STUB); (stubdir / "codex").chmod(0o755)
    real_codex = shutil.which("codex")
    real_path = os.environ["PATH"]
    orig_policy = m.codex_sandbox_policy

    def residue():
        return [p for d in (common, own, wt) for p in d.rglob("nogg-doctor-probe-*")]

    def diag(workdir, *, codex="stub", with_sandbox=False, grant=True, extra=(), cfg=None, env=None):
        os.environ["PATH"] = (str(stubdir) + os.pathsep + real_path) if codex == "stub" else real_path
        if codex is None:
            os.environ["PATH"] = "/nonexistent"
        saved_env = {k: os.environ.get(k) for k in (env or {})}
        os.environ.update(env or {})
        m.CFG = cfg or {}
        m.codex_sandbox_policy = orig_policy if grant else (
            lambda w, grants=(), network=True: {**orig_policy(w, grants, network), "writable_roots": []})
        try:
            return m.codex_sandbox_diagnosis(workdir, with_sandbox=with_sandbox, sandbox_extra=extra)
        finally:
            m.codex_sandbox_policy = orig_policy
            os.environ["PATH"] = real_path
            for k, v in saved_env.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v

    # --- stub: granted roots are writable, both git dirs probed, no residue.
    notes = diag(wt)
    check(any(f"shared Git dir: writable ({common})" in n for n in notes)
          and any(f"worktree gitdir: writable ({own})" in n for n in notes), f"stub: granted roots writable: {notes}")
    check(any("run doctor --sandbox" in n for n in notes), "plain doctor points at --sandbox for network/test probes")
    check(not residue(), "stub: no probe residue")

    # --- stub: a root the sandbox does not grant is NOT writable even though the host can write it.
    notes = diag(wt, grant=False)
    check(any(f"{own} is NOT writable in the Codex sandbox" in n for n in notes)
          and any(f"{common} is NOT writable" in n for n in notes), f"stub: ungranted roots reported: {notes}")
    check(not residue(), "stub: no residue after failed probes")

    # --- absent and unsupported codex: a single skip NOTE with the reason.
    notes = diag(wt, codex=None)
    check(notes == ["codex sandbox diagnosis skipped: codex not installed"], f"absent codex: {notes}")
    notes = diag(wt, env={"STUB_UNSUPPORTED": "1"})
    check(len(notes) == 1 and "no `codex sandbox` subcommand" in notes[0], f"unsupported codex: {notes}")

    # --- resolver failure (not a git checkout) is a skip NOTE, never an exception.
    notes = diag(tmp / "stub")
    check(len(notes) == 1 and "resolver error" in notes[0], f"resolver error: {notes}")

    # --- --sandbox: non-SSH remote skips the fetch; scripts/test runs bounded and names failing suites.
    git("-C", str(wt), "remote", "add", "origin", "https://example.invalid/x/y.git")
    (wt / "scripts").mkdir()
    test = wt / "scripts/test"
    test.write_text("#!/usr/bin/env bash\necho 'PASS - scripts/a.test.sh'\necho 'FAIL - scripts/b.test.sh'\nexit 1\n")
    test.chmod(0o755)
    notes = diag(wt, with_sandbox=True)
    check(any("origin is not an SSH remote" in n for n in notes), f"non-SSH remote skipped: {notes}")
    check(any(n == "codex sandbox test probe: FAILED suites: scripts/b.test.sh" for n in notes),
          f"failing suite named: {notes}")
    test.write_text("#!/usr/bin/env bash\nsleep 30\n")
    notes = diag(wt, with_sandbox=True, cfg={"doctor_sandbox_test_timeout_seconds": 1})
    check(any(n == "codex sandbox test probe: timed out after 1 s" for n in notes), f"test probe bounded: {notes}")
    test.write_text("#!/usr/bin/env bash\necho 'PASS - scripts/a.test.sh'\n")
    git("-C", str(wt), "remote", "set-url", "origin", "git@example.invalid:x/y.git")
    notes = diag(wt, with_sandbox=True, env={"GIT_SSH_COMMAND": "false"})
    check(any(n.startswith("codex sandbox SSH fetch probe: FAILED") for n in notes), f"SSH probe attempted: {notes}")
    check(git("-C", str(wt), "status", "--porcelain") == "?? scripts/", "probes changed no tracked file or config")
    shutil.rmtree(wt / "scripts")

    # --- real codex sandbox (when available): granted vs not granted, /tmp excluded
    # so the temp checkout is writable only through writable_roots.
    supported = real_codex and subprocess.run([real_codex, "sandbox", "--help"],
                                              capture_output=True).returncode == 0
    if not supported:
        print("ok - real codex sandbox checks skipped: codex sandbox unavailable on this host")
    else:
        extra = ("-c", "sandbox_workspace_write.exclude_slash_tmp=true",
                 "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true")
        notes = diag(wt, codex="real", extra=extra)
        check(any(f"worktree gitdir: writable ({own})" in n for n in notes), f"real sandbox: granted root writable: {notes}")
        notes = diag(wt, codex="real", extra=extra, grant=False)
        check(any(f"{own} is NOT writable in the Codex sandbox" in n for n in notes),
              f"real sandbox: ungranted root reported (probe really runs inside the sandbox): {notes}")
        check(not residue(), "real sandbox: no probe residue")

    # --- doctor end to end: NOTEs printed, agent_state_roots WARN/NOTE, exit status unchanged.
    def run_doctor(diag_notes, cfg):
        m.validate = lambda: ({}, [], [], [])
        m.session_helper_diagnostics = lambda: []
        m.recover_scan = lambda: ([], [])
        m.archive_ready_changes = lambda tasks, issues: []
        m.multi_machine_enabled = lambda: False
        m.boundary_state_line = lambda: "openspec write boundary: LOCKED"
        for f in ("persona_mismatch_notes", "launch_profile_notes", "supervised_launch_permission_notes",
                  "blocked_running_sessions_notes", "stale_codex_rule_lines"):
            setattr(m, f, lambda: [])
        m.tool_on_path = lambda name: name in ("git", "python3", "bd", "dolt", "agy")
        m.codex_sandbox_diagnosis = lambda w, with_sandbox=False: diag_notes
        m.CFG = {"beads_command": "bd", **cfg}
        buf, code = io.StringIO(), 0
        with contextlib.redirect_stdout(buf):
            try: m.doctor()
            except SystemExit as exc: code = exc.code or 0
            except Exception as exc: print(f"doctor raised: {exc!r}"); code = "raised"
        return buf.getvalue(), code
    out_ok, code_ok = run_doctor(["codex sandbox write-probe shared Git dir: writable (/x)"], {})
    out_bad, code_bad = run_doctor(["codex sandbox write-probe shared Git dir: /x is NOT writable in the Codex sandbox"],
                                   {"agent_state_roots": {"antigravity": ["~/definitely-missing-nogg-dir"]}})
    check("NOTE  codex sandbox write-probe shared Git dir: /x is NOT writable" in out_bad, "doctor prints probe outcome as NOTE")
    check(code_ok == code_bad and code_ok != "raised", f"probe outcome never changes doctor exit status ({code_ok} vs {code_bad})")
    check("NOTE  agy is installed but agent_state_roots.antigravity is not declared" in out_ok,
          "agy installed without antigravity root: NOTE naming the key")
    check("WARN  agent_state_roots antigravity: invalid directory ~/definitely-missing-nogg-dir" in out_bad
          and "agy is installed but" not in out_bad, "invalid declared state root: WARN, not FAIL")
    out_mal, code_mal = run_doctor([], {"agent_state_roots": "bad"})
    check("WARN  agent_state_roots must be an object" in out_mal and "FAIL  agent_state_roots" not in out_mal
          and code_mal == code_ok, "malformed agent_state_roots: WARN, exit status unchanged")

if fails:
    print(f"doctor-sandbox-diagnosis: {fails} check(s) FAILED", file=sys.stderr); sys.exit(1)
print("doctor-sandbox-diagnosis: all checks passed")
PY
