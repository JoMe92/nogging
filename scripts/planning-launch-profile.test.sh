#!/usr/bin/env bash
# TASK-HPS-004: planning launches name their authority.
#
# Refuses Codex or Antigravity planning launches without --profile or --full-access
# before any side effect; explicit restricted prints NOTE; every launch prints
# profile=/prompt=; Claude implicit planning warns; restricted Codex prints Dolt note.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs

source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"
unset TMUX TMUX_TMPDIR
for var in "${!HERDR_@}"; do
  unset -v "$var"
done

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d -t nogg-planning-launch-profile.XXXXXX)
trap 'rm -rf "$work"' EXIT

main="$work/main"
mkdir -p "$main"
origin="$work/origin.git"
git init -q --bare "$origin"

git -C "$main" init -q
git -C "$main" config user.name "Nogging Fixture"
git -C "$main" config user.email "fixture@example.invalid"
git -C "$main" branch -M develop

mkdir -p "$main/.nogging" "$main/scripts" "$main/.codex/rules" "$main/.pi/extensions" "$main/.agents"
cp -r "$repo_root/.nogging/launch-profiles" "$main/.nogging/"
cp -r "$repo_root/.nogging/launch-prompts" "$main/.nogging/"
cp "$repo_root/.nogging/config.json" "$main/.nogging/"
python3 -c "import json, pathlib; p = pathlib.Path('$main/.nogging/config.json'); d = json.loads(p.read_text()); d.pop('session_launch_profile', None); d.pop('session_launch_prompt', None); p.write_text(json.dumps(d))"
cp -r "$repo_root/.codex/rules" "$main/.codex/"
cp -r "$repo_root/.pi/extensions" "$main/.pi/"
cp -r "$repo_root/.agents/hooks.json" "$main/.agents/" 2>/dev/null || true
mkdir -p "$main/scripts/hooks"
cp "$repo_root/scripts/hooks/agy-guard" "$main/scripts/hooks/" 2>/dev/null || true
cp -r "$repo_root/scripts/lib" "$main/scripts/"
cp "$repo_root/scripts/nogg" "$main/scripts/"
cp "$repo_root/scripts/nogg_usage.py" "$main/scripts/"
cp "$repo_root/scripts/session-launch" "$main/scripts/"
cp "$repo_root/scripts/session-log-writer" "$main/scripts/"
cp "$repo_root/scripts/openspec-sandbox" "$main/scripts/"

cat << 'EOF' > "$main/.gitignore"
.nogging/state/
.nogging/locks/
EOF

git -C "$main" add .
git -C "$main" commit -qm "fixture repo init"
git -C "$main" remote add origin "$origin"
git -C "$main" push -qu origin develop
git -C "$main" branch -u origin/develop develop

# Stub tmux first on PATH: records argv and exits 1.
# Refused planning launches must NEVER invoke tmux.
stub_dir="$work/bin"
mkdir -p "$stub_dir"
tmux_calls="$work/tmux_calls.log"
cat << 'EOF' > "$stub_dir/tmux"
#!/usr/bin/env bash
echo "$@" >> "$TMUX_STUB_CALLS"
exit 1
EOF
chmod 755 "$stub_dir/tmux"

export PATH="$stub_dir:$PATH"
export TMUX_STUB_CALLS="$tmux_calls"
export NOGGING_ROOT="$main"

# ---------------------------------------------------------------------------
# Part 1: CLI refusals without --profile or --full-access
# ---------------------------------------------------------------------------
for agent in codex antigravity agy; do
  pid="plan-auth-$agent"
  out="$work/launch-$agent.out"
  set +e
  "$main/scripts/nogg" session launch --role planning --planning-id "$pid" --description "scope-test" --agent "$agent" >"$out" 2>&1
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    echo "FAIL - $agent planning launch without profile succeeded unexpectedly" >&2
    cat "$out" >&2
    exit 1
  fi

  # Error message must name both flags
  if ! grep -q "\-\-profile trusted" "$out" || ! grep -q "\-\-profile restricted" "$out"; then
    echo "FAIL - $agent refusal message did not name both explicit profiles" >&2
    cat "$out" >&2
    exit 1
  fi

  expected_agent="$agent"
  if [[ "$agent" == "agy" ]]; then
    expected_agent="antigravity"
  fi
  if ! grep -q "planning with $expected_agent needs an explicit authority" "$out"; then
    echo "FAIL - $agent refusal message did not match expected phrasing" >&2
    cat "$out" >&2
    exit 1
  fi

  # No planning worktree directory created
  for wt in "$work"/main-plan-"$pid"-scope-test*; do
    if [[ -d "$wt" ]]; then
      echo "FAIL - planning worktree directory $wt was created for refused $agent launch" >&2
      exit 1
    fi
  done

  # No worktree record created
  if find "$main/.nogging/state/worktrees" -name "*$pid*" 2>/dev/null | grep -q .; then
    echo "FAIL - planning worktree record created for refused $agent launch" >&2
    exit 1
  fi

  # No session record or session log created
  if find "$main/.nogging/state/sessions" -name "*.json" 2>/dev/null | grep -v '\.settings\.json$' | grep -q .; then
    echo "FAIL - session record created for refused $agent launch" >&2
    exit 1
  fi
  if find "$main/.nogging/state/sessions" -name "*.log" 2>/dev/null | grep -q .; then
    echo "FAIL - session log created for refused $agent launch" >&2
    exit 1
  fi

  # tmux was never called
  if [[ -s "$tmux_calls" ]]; then
    echo "FAIL - tmux stub was invoked during refused $agent launch:" >&2
    cat "$tmux_calls" >&2
    exit 1
  fi
done

echo "ok - CLI planning launch refusals for codex, antigravity and agy without side effects"

# ---------------------------------------------------------------------------
# Part 2: Direct Python calls to planning_launch_authority and output helpers
# ---------------------------------------------------------------------------
python3 - "$main" << 'PY'
import contextlib
from importlib.machinery import SourceFileLoader
import io
from pathlib import Path
import sys
from unittest.mock import patch

main = Path(sys.argv[1])
sys.path.insert(0, str(main / 'scripts/lib'))
sys.path.insert(0, str(main / 'scripts'))
m = SourceFileLoader('nogg', str(main / 'scripts/nogg')).load_module()

# 1. Direct calls to planning_launch_authority that PASS:
# --profile trusted, --profile restricted, --full-access
for agent in ('codex', 'antigravity', 'agy'):
    m.planning_launch_authority('planning', agent, profile='trusted', full_access=False)
    m.planning_launch_authority('planning', agent, profile='restricted', full_access=False)
    m.planning_launch_authority('planning', agent, profile=None, full_access=True)
    m.planning_launch_authority(agent, 'trusted', False)
    m.planning_launch_authority(agent, 'restricted', False)
    m.planning_launch_authority(agent, None, True)

# Any Claude or Pi call passes without profile:
m.planning_launch_authority('planning', 'claude', profile=None, full_access=False)
m.planning_launch_authority('planning', 'pi', profile=None, full_access=False)
m.planning_launch_authority('claude', None, False)
m.planning_launch_authority('pi', None, False)

# Every non-planning role passes without profile:
for role in ('lead', 'orchestrator', 'specialist:backend-engineer', 'specialist:architect'):
    for agent in ('codex', 'antigravity', 'agy', 'claude', 'pi'):
        m.planning_launch_authority(role, agent, profile=None, full_access=False)
        m.planning_launch_authority(agent, None, False, role=role)

# 2. Direct calls to planning_launch_authority that RAISE:
for agent in ('codex', 'antigravity', 'agy'):
    disp = 'antigravity' if agent == 'agy' else agent
    try:
        m.planning_launch_authority('planning', agent, profile=None, full_access=False)
    except RuntimeError as exc:
        msg = str(exc)
        assert f"planning with {disp} needs an explicit authority" in msg, f"unexpected message: {msg}"
        assert "--profile trusted" in msg and "--profile restricted" in msg, f"missing flags: {msg}"
    else:
        raise AssertionError(f"planning_launch_authority did not raise for {agent}")

    # Also 3-arg positional call
    try:
        m.planning_launch_authority(agent, None, False)
    except RuntimeError as exc:
        msg = str(exc)
        assert f"planning with {disp} needs an explicit authority" in msg
    else:
        raise AssertionError(f"planning_launch_authority(agent, None, False) did not raise for {agent}")

# 3. Direct calls to launch-output helpers:
# Profile line
p1 = m.launch_profile_line("trusted", "/path/to/.nogging/launch-prompts/autonomous.md")
assert p1 == "  profile=trusted prompt=autonomous", f"got: {p1!r}"
p2 = m.launch_profile_line("restricted", "/path/to/.nogging/launch-prompts/planning.md")
assert p2 == "  profile=restricted prompt=planning", f"got: {p2!r}"
p3 = m.session_launch_profile_line("custom", "/path/to/custom-prompt.md")
assert p3 == "  profile=custom prompt=custom-prompt", f"got: {p3!r}"

# Notes helper
# Explicit restricted Codex planning: both notes
n1 = m.launch_notes("planning", "codex", "restricted")
assert "NOTE: restricted codex planning stops at approval prompts; attach to approve each step" in n1
assert "NOTE: restricted Codex has no network; a Dolt-server-backed bd is unreachable from its sandbox" in n1

# Explicit restricted Antigravity planning: planning note only
n2 = m.launch_notes("planning", "antigravity", "restricted")
assert "NOTE: restricted antigravity planning stops at approval prompts; attach to approve each step" in n2
assert not any("network" in note for note in n2)

# Restricted Codex non-planning role: Dolt note only
n3 = m.launch_notes("lead", "codex", "restricted")
assert "NOTE: restricted Codex has no network; a Dolt-server-backed bd is unreachable from its sandbox" in n3
assert not any("planning stops" in note for note in n3)

# Trusted Codex planning: no notes
n4 = m.launch_notes("planning", "codex", "trusted")
assert n4 == [], f"expected empty notes, got: {n4}"

# Restricted Claude lead: no notes
n5 = m.launch_notes("lead", "claude", "restricted")
assert n5 == [], f"expected empty notes, got: {n5}"

# 4. Launch output integration in _session_launch
calls = []
with patch.object(m, 'tmux', side_effect=lambda *a, **kw: calls.append(a)), \
     patch.object(m, 'tmux_sessions', return_value=set()), \
     patch.object(m, 'tmux_has_session', return_value=False), \
     patch.object(m, 'bead_records', return_value=[]):

    # Claude planning default (implicit restricted):
    # prints profile line and manual-mode warning
    with contextlib.redirect_stdout(io.StringIO()) as out:
        m.session_launch('planning', None, None, False, None,
                         agent='claude', planning_id='plan-claude-test', description='scope-test')
    claude_out = out.getvalue()
    assert "profile=restricted prompt=planning" in claude_out, f"missing profile line in: {claude_out}"
    assert "launched in restricted/manual mode" in claude_out, f"missing manual mode warning in: {claude_out}"
    assert "NOTE: restricted" not in claude_out

    # Explicit restricted Codex planning:
    # prints profile line, both notes, and NOT the manual-mode warning
    with contextlib.redirect_stdout(io.StringIO()) as out:
        m.session_launch('planning', None, None, False, None,
                         agent='codex', profile='restricted',
                         planning_id='plan-codex-test', description='scope-test')
    codex_out = out.getvalue()
    assert "profile=restricted prompt=planning" in codex_out
    assert "NOTE: restricted codex planning stops at approval prompts; attach to approve each step" in codex_out
    assert "NOTE: restricted Codex has no network; a Dolt-server-backed bd is unreachable from its sandbox" in codex_out
    assert "launched in restricted/manual mode" not in codex_out

    # Explicit restricted Antigravity planning:
    # prints profile line, planning note, and NOT the Codex Dolt note
    with contextlib.redirect_stdout(io.StringIO()) as out:
        m.session_launch('planning', None, None, False, None,
                         agent='antigravity', profile='restricted',
                         planning_id='plan-agy-test', description='scope-test')
    agy_out = out.getvalue()
    assert "profile=restricted prompt=planning" in agy_out
    assert "NOTE: restricted antigravity planning stops at approval prompts; attach to approve each step" in agy_out
    assert "NOTE: restricted Codex" not in agy_out
    assert "launched in restricted/manual mode" not in agy_out

    # Trusted Codex planning:
    # prints profile line, no notes, no manual-mode warning
    with contextlib.redirect_stdout(io.StringIO()) as out:
        m.session_launch('planning', None, None, False, None,
                         agent='codex', profile='trusted',
                         planning_id='plan-codex-trusted', description='scope-test')
    trusted_out = out.getvalue()
    assert "profile=trusted prompt=planning" in trusted_out
    assert "NOTE:" not in trusted_out
    assert "launched in restricted/manual mode" not in trusted_out

print("ok - direct calls and launch output integration tests passed")
PY

echo "all planning launch authority tests passed"
