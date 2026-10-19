#!/usr/bin/env bash
# Runtime guidance stays aligned across public docs and installed prompts (TASK-HPS-006).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

python3 - "$root" <<'PY'
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
bad = []

def text(rel):
    return re.sub(r"\s+", " ", (root / rel).read_text())

def require(rel, *phrases):
    value = text(rel)
    for phrase in phrases:
        if phrase.casefold() not in value.casefold():
            bad.append(f"{rel}: missing {phrase!r}")

require("docs/using-with-codex.md", "host-owned Dolt server", "including loopback",
        "Dolt server unreachable at 127.0.0.1:3308", "socket: operation not permitted",
        "--profile trusted", "operator", "--profile restricted", "--full-access",
        "refused before creating a session or worktree", "profile=", "prompt=",
        "network-off sandbox cannot reach a Dolt-server-backed `bd`",
        "CODEX_REASONING_EFFORTS", "gpt-6-luna", "--model gpt-6.1-sol --effort low")
require("docs/using-with-antigravity.md", "`search_web`", "`query` is a non-empty string",
        "Trusted sessions may run", "restricted sessions must approve it",
        "`invalid search query`", "sanitized tool name", "`<invalid>`",
        "Denials never repeat command, path, URL or query argument values",
        "`--profile <name>` or `--full-access`", "profile=", "prompt=")
for rel in ("docs/running-work-in-sessions.md", "docs/operating-model.md"):
    require(rel, "`--profile`", "`--full-access`", "refused", "profile=", "prompt=",
            "Restricted Codex", "loopback")
require("docs/security-model.md", "`search_web`", "`read_url_content`",
        "restricted requires approval", "sanitized reasons")

require("docs/running-work-in-sessions.md", "worktree rebase", "--allow-live-session",
        "rebase-backup", "exit 3", "--force-with-lease", "already up to date")
require("docs/failure-recovery.md", "half-applied", "worktree repair", "repair-backup",
        "core.hooksPath", "pre-rebase", "read-only mount", "never runs `reset --hard`")
require("docs/operating-model.md", "worktree rebase", "worktree repair")
require("docs/architecture.md", "rebase-broker", "classifier", "pre-rebase")
require("CHANGELOG.md", "worktree rebase", "worktree repair", "pre-rebase")

host_rule = ("shared Dolt server is host-owned", "never start, stop or restart it",
             "stop and report the exact error")
for rel in (".nogging/launch-prompts/planning.md",
            ".nogging/launch-prompts/autonomous.md",
            ".nogging/launch-prompts/no-autonomous-claim.md"):
    require(rel, *host_rule)
require(".nogging/launch-prompts/orchestrator.md", "--role planning",
        "--profile trusted", "--full-access", "Dolt server is host-owned",
        "never start, stop or restart it")

for line in bad:
    print("FAIL -", line)
if bad:
    sys.exit(1)
print("ok   - runtime guidance covers the HPS-006 authority, network and guard contracts")
PY

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP - installed prompts: node not on PATH"
  exit 0
fi
target=$(mktemp -d "${TMPDIR:-/tmp}/nogg-runtime-guidance.XXXXXX")
trap 'chmod -R u+w "$target" 2>/dev/null; find "$target" -mindepth 1 -delete 2>/dev/null; rmdir "$target" 2>/dev/null || true' EXIT
git init -q "$target"
( cd "$target" && node "$root/bin/cli.js" init --no-beads --no-systemd --no-hooks >/dev/null )
python3 - "$root" "$target" <<'PY'
import sys
from pathlib import Path

root, target = map(Path, sys.argv[1:])
bad = []
for rel in (".nogging/launch-prompts/planning.md",
            ".nogging/launch-prompts/autonomous.md",
            ".nogging/launch-prompts/no-autonomous-claim.md",
            ".nogging/launch-prompts/orchestrator.md"):
    if (target / rel).read_bytes() != (root / rel).read_bytes():
        bad.append(f"installed {rel} differs from the source")
for line in bad:
    print("FAIL -", line)
if bad:
    sys.exit(1)
print("ok   - fresh installs carry the updated runtime launch prompts verbatim")
PY
