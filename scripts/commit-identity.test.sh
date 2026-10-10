#!/usr/bin/env bash
# Regression checks for distinct commit identities per Nogging persona
# (openspec/changes/agent-commit-identity), Tier 1 only (TASK-ACI-001..006):
#
#   - the persona roster loads from `.nogging/config.json`'s `personas` key,
#     and an unconfigured slug fails loudly rather than committing under no
#     identity (TASK-ACI-001).
#
# Later Tier-1 tasks append their own scenarios to this file as they land.
# TASK-ACI-003 (the orchestrator's own identity at `orchestrator run`
# startup) is covered in scripts/orchestrator.test.sh, which already drives
# that command end to end.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
check()  { if grep -qF -- "$2" "$out"; then echo "ok   - $1"; else echo "FAIL - $1 (missing: $2)"; cat "$out"; fail=1; fi; }
refute() { if grep -qF -- "$2" "$out"; then echo "FAIL - $1 (present: $2)"; cat "$out"; fail=1; else echo "ok   - $1"; fi; }

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list) cat "${BD_FIXTURE:?}" ;;
  *) echo "unexpected bd call: $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/bin/dolt" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

# make_root <dir> — a minimal Nogging checkout with one change and a git repo.
make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/.nogging/locks" "$r/openspec/changes/demo"
  cp "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  printf '%s\n' '# Tasks' '' '- [ ] TASK-DEMO-001 Do the demo thing' >"$r/openspec/changes/demo/tasks.md"
  printf '# Execution log\n' >"$r/openspec/changes/demo/execution-log.md"
  git -C "$r" init -q
  git -C "$r" config user.email operator@example.invalid
  git -C "$r" config user.name 'Operator'
  git -C "$r" add -A && git -C "$r" commit -q -m "chore: scratch root [SPEC-000]"
  git -C "$r" checkout -q -b work
}

# ===========================================================================
# Scenario: the persona roster loads as data; an unconfigured slug fails loud
# ===========================================================================
root="$work/roster"; make_root "$root"
roster_out=$(NOGGING_ROOT="$root" python3 - "$nogg" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_roster", sys.argv[1]).load_module()
name, email = m.persona_identity("lead")
assert (name, email) == ("Nogging Lead", "lead@nogging.bot"), (name, email)
print("ok   - roster: lead persona resolves to Nogging Lead <lead@nogging.bot>")
try:
    m.persona_identity("no-such-persona")
    print("FAIL - roster: unknown slug should have raised")
except RuntimeError:
    print("ok   - roster: an unconfigured persona slug raises rather than silently committing")
PY
)
echo "$roster_out" >"$out"
check "roster: lead persona resolves correctly" "ok   - roster: lead persona resolves to Nogging Lead"
check "roster: unknown persona raises" "ok   - roster: an unconfigured persona slug raises"
refute "roster: no FAIL lines" "FAIL"
unset NOGGING_ROOT

unset NOGGING_ROOT

# ===========================================================================
# Scenario: worktree plan sets the planner identity inside the new worktree
# ===========================================================================
root="$work/wt-plan"; make_root "$root"
remote="$work/wt-plan-origin.git"; git init -q --bare "$remote"
git -C "$root" branch develop
git -C "$root" remote add origin "$remote"
git -C "$root" push -q origin develop
export NOGGING_ROOT="$root"
destination="$work/wt-plan-destination"
"$nogg" worktree plan agent-identity commit-identity --path "$destination" >"$out" 2>&1 \
  || { echo "FAIL - wt-plan: allocation errored"; cat "$out"; fail=1; }
[[ "$(git -C "$destination" config --worktree --get user.name)" == "Nogging Planner" ]] \
  && echo "ok   - wt-plan: worktree-scoped user.name is Nogging Planner" \
  || { echo "FAIL - wt-plan: user.name is $(git -C "$destination" config --get user.name 2>/dev/null || echo unset)"; fail=1; }
[[ "$(git -C "$destination" config --worktree --get user.email)" == "planner@nogging.bot" ]] \
  && echo "ok   - wt-plan: worktree-scoped user.email is planner@nogging.bot" \
  || { echo "FAIL - wt-plan: user.email is $(git -C "$destination" config --get user.email 2>/dev/null || echo unset)"; fail=1; }
[[ "$(git -C "$root" config --get extensions.worktreeConfig)" == "true" ]] \
  && echo "ok   - wt-plan: extensions.worktreeConfig enabled on the shared repo" \
  || { echo "FAIL - wt-plan: extensions.worktreeConfig not enabled"; fail=1; }
[[ "$(git -C "$root" config --get user.name)" == "Operator" ]] \
  && echo "ok   - wt-plan: the shared checkout's own identity is untouched" \
  || { echo "FAIL - wt-plan: shared checkout identity changed to $(git -C "$root" config --get user.name)"; fail=1; }
printf 'planned\n' >"$destination/plan-evidence.txt"
git -C "$destination" add plan-evidence.txt
git -C "$destination" commit -q -m 'docs: validated plan' -m 'Nogging-Writer: planning'
[[ "$(git -C "$destination" log -1 --format='%an <%ae>')" == "Nogging Planner <planner@nogging.bot>" ]] \
  && echo "ok   - wt-plan: a commit made with no author flag carries the planner identity" \
  || { echo "FAIL - wt-plan: commit author is $(git -C "$destination" log -1 --format='%an <%ae>')"; fail=1; }
git -C "$root" worktree remove --force "$destination"
unset NOGGING_ROOT

# ===========================================================================
# Scenario: worktree implement sets the lead identity inside the new worktree
# ===========================================================================
root="$work/wt-implementation"; make_root "$root"
remote="$work/wt-implementation-origin.git"; git init -q --bare "$remote"
git -C "$root" branch develop
git -C "$root" remote add origin "$remote"
git -C "$root" push -q origin develop
export NOGGING_ROOT="$root"
export BD_FIXTURE="$work/wt-implementation-beads.json"
printf '[{"id":"SPEC-impl","status":"in_progress","labels":[]}]\n' >"$BD_FIXTURE"
destination="$work/wt-implementation-destination"
"$nogg" worktree implement SPEC-impl feat/demo --path "$destination" >"$out" 2>&1 \
  || { echo "FAIL - wt-implementation: allocation errored"; cat "$out"; fail=1; }
[[ "$(git -C "$destination" config --worktree --get user.name)" == "Nogging Lead" ]] \
  && echo "ok   - wt-implementation: worktree-scoped user.name is Nogging Lead" \
  || { echo "FAIL - wt-implementation: user.name is $(git -C "$destination" config --get user.name 2>/dev/null || echo unset)"; fail=1; }
[[ "$(git -C "$destination" config --worktree --get user.email)" == "lead@nogging.bot" ]] \
  && echo "ok   - wt-implementation: worktree-scoped user.email is lead@nogging.bot" \
  || { echo "FAIL - wt-implementation: user.email is $(git -C "$destination" config --get user.email 2>/dev/null || echo unset)"; fail=1; }
git -C "$root" worktree remove --force "$destination"
unset NOGGING_ROOT BD_FIXTURE

unset NOGGING_ROOT BD_FIXTURE

# ===========================================================================
# Scenario: the sync mirror commit carries the Nogging Sync identity
# ===========================================================================
root="$work/sync-identity"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): first demo thing [SPEC-d01]"
export NOGGING_ROOT="$root"
export BD_FIXTURE="$work/sync-identity-beads.json"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-d01", "status": "closed",
   "closed_at": "2026-09-01T10:00:00Z", "updated_at": "2026-09-01T10:00:00Z",
   "notes": "commit abc1234; implemented the first demo thing",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$nogg" sync >"$out" 2>&1 || { echo "FAIL - sync-identity: sync errored"; cat "$out"; fail=1; }
[[ "$(git -C "$root" log -1 --format='%an <%ae>')" == "Nogging Sync <sync@nogging.bot>" ]] \
  && echo "ok   - sync-identity: mirror commit author is Nogging Sync" \
  || { echo "FAIL - sync-identity: commit author is $(git -C "$root" log -1 --format='%an <%ae>')"; fail=1; }
[[ "$(git -C "$root" log -1 --format='%cn <%ce>')" == "Nogging Sync <sync@nogging.bot>" ]] \
  && echo "ok   - sync-identity: mirror commit committer is Nogging Sync" \
  || { echo "FAIL - sync-identity: commit committer is $(git -C "$root" log -1 --format='%cn <%ce>')"; fail=1; }
unset NOGGING_ROOT BD_FIXTURE

unset NOGGING_ROOT BD_FIXTURE

# ===========================================================================
# Scenario: doctor NOTEs a worktree whose identity doesn't match its persona
# ===========================================================================
root="$work/doctor-mismatch"; make_root "$root"
remote="$work/doctor-mismatch-origin.git"; git init -q --bare "$remote"
git -C "$root" branch develop
git -C "$root" remote add origin "$remote"
git -C "$root" push -q origin develop
export NOGGING_ROOT="$root"
export BD_FIXTURE="$work/doctor-mismatch-beads.json"; printf '[]\n' >"$BD_FIXTURE"
destination="$work/doctor-mismatch-destination"
"$nogg" worktree plan agent-identity doctor-note --path "$destination" >/dev/null 2>&1
"$nogg" doctor >"$out" 2>&1 || true
refute "doctor-mismatch: no NOTE while the identity matches its persona" \
  "user.name is Nogging Planner, expected Nogging Planner"
# simulate a pre-change worktree / silently failed identity-set
git -C "$destination" config --worktree user.name 'Workflow Test'
"$nogg" doctor >"$out" 2>&1 || true
check "doctor-mismatch: NOTEs a worktree whose user.name does not match its persona" \
  "user.name is Workflow Test, expected Nogging Planner"
git -C "$root" worktree remove --force "$destination"
unset NOGGING_ROOT BD_FIXTURE

# ===========================================================================
# Scenario: Tier 2 — worktree plan/implement with github_app (TASK-ACI-009)
# ===========================================================================
root="$work/tier2"; make_root "$root"
remote="$work/tier2-origin.git"; git init -q --bare "$remote"
git -C "$root" branch develop
git -C "$root" remote add origin "$remote"
git -C "$root" push -q origin develop

tier2_out=$(NOGGING_ROOT="$root" python3 - "$nogg" "$work" <<'PY'
import io, json, os, pathlib, subprocess, sys
from importlib.machinery import SourceFileLoader
from unittest.mock import patch

nogg_path = sys.argv[1]
work_dir = pathlib.Path(sys.argv[2])
m = SourceFileLoader("sf_tier2", nogg_path).load_module()

key_path = work_dir / "tier2_key.pem"
subprocess.run(["openssl", "genrsa", "-out", str(key_path), "2048"], check=True, capture_output=True)

class Tier2Opener:
    def open(self, req, timeout=20):
        auth = req.get_header("Authorization") or ""
        assert auth.startswith("Bearer "), f"expected Bearer token, got {auth}"
        if req.full_url.endswith("/app"):
            jwt = auth.split()[1]
            payload = jwt.split(".")[1]
            claims = json.loads(m.base64.urlsafe_b64decode(payload + "==="))
            iss = claims["iss"]
            if iss == "42":
                return io.StringIO(json.dumps({"id": 42, "slug": "planner-app"}))
            elif iss == "88":
                return io.StringIO(json.dumps({"id": 88, "slug": "lead-app"}))
        raise AssertionError(f"unexpected request URL: {req.full_url}")

with patch.object(m.urllib.request, "build_opener", return_value=Tier2Opener()):
    real_run = m.run
    def mock_run(*args, **kwargs):
        if len(args) >= 4 and args[:4] == ("git", "fetch", "origin", "develop"):
            return subprocess.CompletedProcess(args, 0, "", "")
        return real_run(*args, **kwargs)

    with patch.object(m, "run", side_effect=mock_run):
        # 1. worktree plan with github_app for planner
        m.CFG["personas"]["planner"]["github_app"] = {
            "app_id": 42,
            "private_key_path": str(key_path)
        }
        m.run("git", "remote", "set-url", "origin", "git@github.com:owner/repo.git")
        plan_dest = work_dir / "tier2-plan-dest"
        m.planning_worktree("tier2-plan", "test-plan", location=str(plan_dest))

        p_name = subprocess.run(["git", "-C", str(plan_dest), "config", "--worktree", "--get", "user.name"], capture_output=True, text=True).stdout.strip()
        p_email = subprocess.run(["git", "-C", str(plan_dest), "config", "--worktree", "--get", "user.email"], capture_output=True, text=True).stdout.strip()
        p_helper = subprocess.run(["git", "-C", str(plan_dest), "config", "--worktree", "--get", "credential.helper"], capture_output=True, text=True).stdout.strip()
        p_remote = subprocess.run(["git", "-C", str(plan_dest), "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
        p_push = subprocess.run(["git", "-C", str(plan_dest), "remote", "get-url", "--push", "origin"], capture_output=True, text=True).stdout.strip()
        root_remote = subprocess.run(["git", "-C", str(m.ROOT), "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()

        assert p_name == "Nogging Planner", f"got {p_name}"
        assert p_email == "42+planner-app[bot]@users.noreply.github.com", f"got {p_email}"
        assert p_helper == "!scripts/nogg credential-helper planner", f"got {p_helper}"
        assert p_remote == "https://github.com/owner/repo.git", f"got {p_remote}"
        assert p_push == "https://github.com/owner/repo.git", f"got {p_push}"
        assert root_remote == "git@github.com:owner/repo.git", f"root remote changed to {root_remote}"
        print("ok   - tier2-plan: bot email, https remote, and credential helper wired")

        # Commit author check
        (plan_dest / "test.txt").write_text("hello")
        subprocess.run(["git", "-C", str(plan_dest), "add", "test.txt"], check=True)
        subprocess.run(["git", "-C", str(plan_dest), "commit", "-q", "-m", "docs: plan [SPEC-001]"], check=True)
        commit_author = subprocess.run(["git", "-C", str(plan_dest), "log", "-1", "--format=%an <%ae>"], capture_output=True, text=True).stdout.strip()
        assert commit_author == "Nogging Planner <42+planner-app[bot]@users.noreply.github.com>", f"got {commit_author}"
        print("ok   - tier2-plan: commit author matches bot identity")

        # 2. worktree implement with github_app for lead
        m.CFG["personas"]["lead"]["github_app"] = {
            "app_id": 88,
            "private_key_path": str(key_path)
        }
        m.run("git", "remote", "set-url", "origin", "ssh://git@github.com/owner/repo.git")
        impl_dest = work_dir / "tier2-impl-dest"
        m.beads = lambda: [{"id": "SPEC-t2", "status": "in_progress", "labels": []}]
        m.implementation_worktree("SPEC-t2", "feat/tier2-impl", location=str(impl_dest))

        l_name = subprocess.run(["git", "-C", str(impl_dest), "config", "--worktree", "--get", "user.name"], capture_output=True, text=True).stdout.strip()
        l_email = subprocess.run(["git", "-C", str(impl_dest), "config", "--worktree", "--get", "user.email"], capture_output=True, text=True).stdout.strip()
        l_helper = subprocess.run(["git", "-C", str(impl_dest), "config", "--worktree", "--get", "credential.helper"], capture_output=True, text=True).stdout.strip()
        l_remote = subprocess.run(["git", "-C", str(impl_dest), "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
        root_remote2 = subprocess.run(["git", "-C", str(m.ROOT), "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()

        assert l_name == "Nogging Lead", f"got {l_name}"
        assert l_email == "88+lead-app[bot]@users.noreply.github.com", f"got {l_email}"
        assert l_helper == "!scripts/nogg credential-helper lead", f"got {l_helper}"
        assert l_remote == "https://github.com/owner/repo.git", f"got {l_remote}"
        assert root_remote2 == "ssh://git@github.com/owner/repo.git", f"root remote changed to {root_remote2}"
        print("ok   - tier2-impl: lead bot email, https remote, and credential helper wired")

        # Execute git credential fill to prove leading ! invokes helper correctly
        (impl_dest / "scripts").mkdir(parents=True, exist_ok=True)
        stub_helper = impl_dest / "scripts" / "nogg"
        stub_helper.write_text("""#!/bin/sh
if [ "$1" = "credential-helper" ] && [ "$2" = "lead" ] && [ "$3" = "get" ]; then
  echo "username=x-access-token"
  echo "password=synthetic-installed-token"
fi
""")
        stub_helper.chmod(0o755)
        cred_env = os.environ.copy()
        cred_env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        fill_res = subprocess.run(
            ["git", "-C", str(impl_dest), "credential", "fill"],
            input="protocol=https\nhost=github.com\n\n",
            capture_output=True, text=True, env=cred_env
        )
        assert fill_res.returncode == 0, fill_res.stderr
        assert "username=x-access-token" in fill_res.stdout, fill_res.stdout
        assert "password=synthetic-installed-token" in fill_res.stdout, fill_res.stdout
        print("ok   - tier2-impl: git credential fill executed stub helper successfully")

        # 3. Persona without github_app stays Tier 1
        del m.CFG["personas"]["lead"]["github_app"]
        tier1_dest = work_dir / "tier1-fallback-dest"
        m.beads = lambda: [{"id": "SPEC-t1", "status": "in_progress", "labels": []}]
        m.implementation_worktree("SPEC-t1", "feat/tier1-fallback", location=str(tier1_dest))
        t1_email = subprocess.run(["git", "-C", str(tier1_dest), "config", "--worktree", "--get", "user.email"], capture_output=True, text=True).stdout.strip()
        t1_helper = subprocess.run(["git", "-C", str(tier1_dest), "config", "--worktree", "--get", "credential.helper"], capture_output=True, text=True).stdout.strip()
        assert t1_email == "lead@nogging.bot", f"got {t1_email}"
        assert t1_helper == "", f"expected no helper, got {t1_helper}"
        print("ok   - tier2-fallback: persona without github_app stays on Tier 1")

        # 4. Fail closed on missing private key
        m.CFG["personas"]["planner"]["github_app"]["private_key_path"] = str(work_dir / "nonexistent.pem")
        fail_dest = work_dir / "fail-dest"
        try:
            m.planning_worktree("tier2-fail", "missing-key", location=str(fail_dest))
            print("FAIL - tier2: missing key should fail closed")
        except Exception:
            print("ok   - tier2: missing private key fails closed")

        # 5. NOGGING_GITHUB_API_URL security: allow loopback only, reject others
        with patch.dict(os.environ, {"NOGGING_GITHUB_API_URL": "http://127.0.0.1:8080"}):
            assert m.github_api_base_url() == "http://127.0.0.1:8080"
        with patch.dict(os.environ, {"NOGGING_GITHUB_API_URL": "http://localhost:9000"}):
            assert m.github_api_base_url() == "http://localhost:9000"
        for bad_target in ("http://attacker.com:8080", "https://attacker.com", "http://localhost", "http://192.168.1.1:8080"):
            with patch.dict(os.environ, {"NOGGING_GITHUB_API_URL": bad_target}):
                try:
                    m.github_api_base_url()
                    print(f"FAIL - api-target: {bad_target} should have been rejected")
                except ValueError:
                    pass
        print("ok   - tier2-security: NOGGING_GITHUB_API_URL accepts only loopback targets")
PY
)
echo "$tier2_out" >"$out"
check "tier2-plan: bot email, https remote, and credential helper wired" "ok   - tier2-plan: bot email, https remote, and credential helper wired"
check "tier2-plan: commit author matches bot identity" "ok   - tier2-plan: commit author matches bot identity"
check "tier2-impl: lead bot email, https remote, and credential helper wired" "ok   - tier2-impl: lead bot email, https remote, and credential helper wired"
check "tier2-impl: git credential fill executed stub helper successfully" "ok   - tier2-impl: git credential fill executed stub helper successfully"
check "tier2-fallback: persona without github_app stays on Tier 1" "ok   - tier2-fallback: persona without github_app stays on Tier 1"
check "tier2: missing private key fails closed" "ok   - tier2: missing private key fails closed"
check "tier2-security: NOGGING_GITHUB_API_URL accepts only loopback targets" "ok   - tier2-security: NOGGING_GITHUB_API_URL accepts only loopback targets"
refute "tier2: no FAIL lines" "FAIL"
unset NOGGING_ROOT

if [[ $fail -ne 0 ]]; then echo "commit-identity checks failed" >&2; exit 1; fi
echo "commit identity: ok"
