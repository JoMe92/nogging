#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"
use_agent_stubs
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/codex"
cat >"$scratch/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CODEX_QUEUE_CALLS"
exit 0
STUB
chmod +x "$scratch/bin/codex"
PATH="$scratch/bin:$PATH" CODEX_HOME="$scratch/codex" CODEX_QUEUE_CALLS="$scratch/queue.log" \
  python3 "$root/scripts/session-codex-queue-busy.test.py" "$root" "$scratch"
