"""How each arm kind's agent is installed and started inside the container (design Decision 7).

The run copies ``/work/bench/`` into the container and starts
``sh ../bench/agent.sh`` from ``/work/repo`` under ``timeout``. The agent's only
brief is ``/work/brief.md`` (the arm's prompt with the issue text); web tools
are disabled through the agent's own flags. Container paths are written
relative to the working directory or ``$HOME`` so the same scripts run in a
real container and under the test stub.
"""

from __future__ import annotations

import shlex

from nogg_bench.arms import Arm

# The agent runs as an unprivileged user: Claude Code refuses unattended
# permission modes as root, and the agent has no business owning the container.
AGENT_USER = "bench"
HOME = f"/home/{AGENT_USER}"
CONFIG_DIRS = {"claude": ".claude", "codex": ".codex"}
# The only files a credential directory may hand over, per agent CLI.
CREDENTIAL_FILES = {"claude": (".credentials.json",), "codex": ("auth.json",)}
# Run as root once the repository, the agent and its credentials are in place.
USER_SETUP = (
    f"id {AGENT_USER} >/dev/null 2>&1 || useradd --create-home --shell /bin/sh {AGENT_USER} "
    f"|| adduser -D {AGENT_USER}"
)
HAND_OVER = f"chown -R {AGENT_USER}: /work {HOME}"
TRANSCRIPT_DIRS = {"claude": ".claude/projects", "codex": ".codex/sessions"}
KILL_AFTER_SECONDS = 30
# A nogging arm's driver enforces the timebox itself, then stops its sessions
# and integrates the implementation branches; the outer timeout leaves it this long.
DRIVER_GRACE_SECONDS = 300

IMPLEMENT = (
    "Leave plan mode now and implement your plan, with tests for the change. "
    "Run the repository's tests before you finish."
)

_APT = r"""have() { command -v "$1" >/dev/null 2>&1; }
apt() {
  have apt-get || { echo "install: $* missing and no apt-get in the image" >&2; exit 2; }
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}
"""

# What the run itself needs in every container, stub agent or not: git for the
# diff and the hidden patch, timeout for the timebox.
TOOLS = "set -eu\n" + _APT + r"""have git || apt git ca-certificates
have timeout || apt coreutils
# docker cp keeps the host's owner; git must still accept the copied repository.
git config --global --add safe.directory '*'
"""

INSTALL = "set -eu\n" + _APT + r"""kind="$1"; cli="$2"; version="$3"
have npm || apt nodejs npm ca-certificates
case "$cli" in
  claude) npm install -g --silent "@anthropic-ai/claude-code@$version" ;;
  codex) npm install -g --silent "@openai/codex@$version" ;;
  *) echo "install: unknown agent CLI $cli" >&2; exit 2 ;;
esac
if [ "$kind" = nogging ]; then
  have tmux || apt tmux
  have python3 || apt python3
  have openspec || npm install -g --silent "@fission-ai/openspec@1.11"
  if ! have bd || ! have dolt; then echo "install: bd and dolt are missing" >&2; exit 2; fi
fi
"""


def agent_script(arm: Arm) -> str:
    """The body of ``agent.sh``: the arm's agent with the brief on stdin and web tools off."""
    model, effort, disabled = arm.model, arm.effort, list(arm.data.get("disabled_tools", []))
    if arm.kind == "claude-code":
        common = [arm.cli, "-p", "--model", model, "--effort", effort, "--output-format", "stream-json", "--verbose"]
        if disabled:
            common.append("--disallowedTools=" + ",".join(disabled))
        plan = shlex.join([*common, "--permission-mode", "plan"]) + " < ../brief.md"
        implement = (
            f"printf '%s\\n' {shlex.quote(IMPLEMENT)} | "
            + shlex.join([*common, "--continue", "--dangerously-skip-permissions"])
        )
        lines = [plan, implement]
    elif arm.kind == "codex":
        argv = [arm.cli, "exec", "--model", model, "-c", f"model_reasoning_effort={effort}"]
        for tool in disabled:
            argv += ["-c", f"tools.{tool}=false"]
        argv += ["--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "-"]
        lines = [shlex.join(argv) + " < ../brief.md"]
    else:  # nogging: the bench-owned driver plays the Product Owner
        argv = [
            "python3", "../bench/driver.py", "--brief", "../brief.md", "--agent", arm.cli,
            "--model", model, "--effort", effort, "--timebox", str(arm.timebox_seconds),
            "--nogging", "../bench/nogging", "--state", "../bench/state.json",
        ]
        lines = [shlex.join(argv)]
    return "set -e\n" + "\n".join(lines) + "\n"


def outer_timeout(arm: Arm) -> int:
    return arm.timebox_seconds + (DRIVER_GRACE_SECONDS if arm.kind == "nogging" else 0)


def launch_command(arm: Arm) -> str:
    """The ``docker exec`` script that runs ``agent.sh`` under the arm's timebox."""
    return (
        f"exec timeout --kill-after={KILL_AFTER_SECONDS} {outer_timeout(arm)} "
        "sh ../bench/agent.sh > ../bench/agent.log 2>&1"
    )


def timed_out(returncode: int | None, elapsed_seconds: float, limit_seconds: float) -> bool:
    """``timeout`` exits 124 when the time ran out and 137 when it had to kill.

    A 137 well before the limit is another kill (out of memory, say), not the timebox.
    """
    if returncode is None or returncode == 124:
        return True
    return returncode == 137 and elapsed_seconds >= limit_seconds


def remove_credentials_script(cli: str, names: list[str]) -> str:
    """Shell, run as the agent user, that deletes the copied credential files before the hidden tests run."""
    targets = " ".join(f'"$HOME"/{shlex.quote(CONFIG_DIRS[cli] + "/" + n)}' for n in names)
    return f"rm -f -- {targets}"
