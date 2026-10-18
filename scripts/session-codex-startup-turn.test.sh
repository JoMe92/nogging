#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"
use_agent_stubs
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/codex"
CODEX_HOME="$scratch/codex" python3 "$root/scripts/session-codex-startup-turn.test.py" "$root" "$scratch"
